## The binary `COWLDMGD` replay: the codec wrapper, playback keyframes, the
## incremental whole-match precompute scan (momentum series, beat ticks, lull
## spans) and the seek/speed/transport commands.
##
## Forked from `coworld-ctf/src/ctf/replays.nim` — magic and game name only
## (`COWLDCTF` -> `COWLDMGD`) plus the retarget of the per-tick input stream:
## this game's ENTIRE input log is the per-turn accepted plan, carried in the
## chat stream as a `directive` record and re-installed at playback by the
## SAME proc that installed it live.

import std/[json, strutils]
import flatty
import bitworld/replays as replayCodec
import sim, directives, broadcast

export replayCodec

const
  ReplayHalfSpeedIndex* = -1
    ## speedIndex sentinel for 1/2x playback: one sim tick every other frame.
    ## Replay-only — the live loop clamps it back to PlaybackSpeeds[0] (1x).
  ReplayKeyframeTicks* = 60
  ReplayEndHoldSeconds* = 10
  LullLeadTicks* = 2 * ReplayFps
  MinLullTicks* = 30
  LullSpeedBoost* = 8
  MaxLullTicksPerFrame* = 64
  SeekTicksPerFrame* = 240
  MinigridReplayMagic* = "COWLDMGD"
  MinigridReplayFormatVersion = 1'u16
  MinigridReplaySpec* = ReplaySpec(
    magic: MinigridReplayMagic,
    formatVersion: MinigridReplayFormatVersion,
    gameName: GameName,
    gameVersion: GameVersion,
    joinKind: rjkNameSlotToken,
    allowChat: true,
    allowCompressed: true,
    hashOrder: rhoStop
  )

type
  ReplayKeyframe* = object
    tick*: int
    simBytes*: string
    joinIndex*, leaveIndex*, chatIndex*, hashIndex*: int
    hashValidationFailed*: bool
    hashMismatchTick*: int

  ReplayScan* = ref object
    sim: SimServer
    builder: ReplayPlayer
    tracker: BroadcastTracker
    beatTicks: seq[int]
    lastLead: seq[int]
    lastCell: int
    interval: int
    maxTick: int

  ReplayPlayer* = object
    data*: ReplayData
    joinIndex*, leaveIndex*, chatIndex*, hashIndex*: int
    playing*: bool
    looping*: bool
    speedIndex*: int
      ## Index into PlaybackSpeeds, or ReplayHalfSpeedIndex (-1) for the
      ## replay-only 1/2x speed (one sim tick every other frame).
    halfPhase*: bool
      ## Frame parity while at 1/2x speed: ticks advance only on the odd
      ## frames, toggled once per advanceReplayPlayback frame.
    mismatchQuit*: bool
    hashValidationFailed*: bool
    hashMismatchTick*: int
    keyframes*: seq[ReplayKeyframe]
    startTick*: int
    leadSeries*: seq[seq[int]]
    endHoldFrames*: int
    pendingSeekTick*: int
    skipLulls*: bool
    lullSpans*: seq[array[2, int]]
    beatEvents*: JsonNode
    scan: ReplayScan
    scanDone: bool

proc tickTime*(tick: int): uint32 = replayCodec.tickTime(tick, ReplayFps)

proc openReplayWriter*(path: string, configJson: string): ReplayWriter =
  replayCodec.openReplayWriter(path, configJson, MinigridReplaySpec)

proc parseReplayBytes*(bytes: string): ReplayData =
  replayCodec.parseReplayBytes(bytes, MinigridReplaySpec)

proc loadReplay*(path: string): ReplayData =
  replayCodec.loadReplay(path, MinigridReplaySpec)

# ---------------------------------------------------------------------------
#  Applying one recorded control record — the SAME proc live and on playback
# ---------------------------------------------------------------------------

proc pushControlEvents*(sim: var SimServer, record: JsonNode) =
  ## The broadcast events a control record derives: `plan`, `fallback` and
  ## `budget`. Called from BOTH paths — the live server as each record is
  ## written (`server.nim`'s `writeChat`) and `applyControlRecord` on playback
  ## — so the /global feed carries the same event kinds live and in replay,
  ## which is what the design note means by "identical live and in replay".
  if record.isNil or record.kind != JObject:
    return
  case record{"k"}.getStr()
  of "directive":
    var verbs: seq[string]
    for item in record{"actions"}:
      verbs.add(item{"do"}.getStr())
    sim.pending.add(SimEvent(kind: evPlan, tick: sim.tickCount,
      slot: record{"slot"}.getInt(), i: record{"turn"}.getInt(),
      a: verbs.join(" "),
      n: (if record{"truncated"}.getBool(): 1 else: 0),
      m: record{"dropped"}.getInt()))
  of "fallback":
    ## ONLY the second attempt is a broadcast event: attempt 1 "will retry"
    ## is a log line, not news for the feed.
    if record{"attempt"}.getInt() >= 2:
      sim.pending.add(SimEvent(kind: evFallback, tick: sim.tickCount,
        slot: record{"slot"}.getInt(), i: record{"turn"}.getInt(),
        a: record{"cause"}.getStr()))
  of "budget_guard":
    sim.pending.add(SimEvent(kind: evBudget, tick: sim.tickCount, slot: -1,
      i: record{"turn"}.getInt(), n: record{"remaining_s"}.getInt()))
  else:
    discard

proc pushControlEvents*(sim: var SimServer, message: string) =
  ## The same, from the serialized record the live server writes.
  if message.len == 0 or message[0] != '{':
    return
  var record: JsonNode
  try:
    record = parseJson(message)
  except CatchableError:
    return
  sim.pushControlEvents(record)

proc applyControlRecord*(sim: var SimServer, message: string) =
  ## Control records ride the chat stream as JSON objects. `directive`
  ## installs the identical primitive queue (this game's whole input log) and
  ## `stop` applies the load-bearing wall-clock/fault stop through
  ## `sim.applyStop` — everything else lands in NON-HASHED feed state only.
  if message.len == 0 or message[0] != '{':
    return
  var record: JsonNode
  try:
    record = parseJson(message)
  except CatchableError:
    return
  sim.pushFeedDirective(message)
  case record{"k"}.getStr()
  of "directive":
    ## THE TURN BOUNDARY RUNS HERE on playback, exactly where the live loop
    ## runs it (server.nim calls `beginTurn` immediately before installing the
    ## turn's plans). A turn writes ONE record per active seat, all carrying
    ## the same `turn` number, so the boundary is opened by the FIRST of them
    ## and the rest only install their own lane's queue.
    let turn = record{"turn"}.getInt()
    if turn > sim.turnsPlayed:
      sim.beginTurn()
    let slot = record{"slot"}.getInt()
    let primitives = parseRecordedActions(record{"executed"})
    if slot >= 0 and slot < sim.lanes.len:
      sim.lanes[slot].notes = ""
      sim.installLanePlan(slot, primitives, record{"truncated"}.getBool(),
        record{"dropped"}.getInt(), record{"unreachable"}.getInt(),
        record{"partial"}.getInt())
      case record{"source"}.getStr()
      of "llm":
        inc sim.lanes[slot].llmTurns
        if record{"retried"}.getBool():
          inc sim.lanes[slot].retriedTurns
      of "fallback":
        inc sim.lanes[slot].fallbackTurns
        ## EVERY failed attempt of the turn, each under its own cause; the
        ## single `cause` is the pre-v2.1 shape and stays readable.
        var counted = 0
        let causes = record{"causes"}
        if not causes.isNil and causes.kind == JArray:
          for item in causes:
            for cause in FallbackCause:
              if $cause == item.getStr():
                inc sim.lanes[slot].fallbackCauses[cause]
                inc counted
                break
        if counted == 0:
          for cause in FallbackCause:
            if $cause == record{"cause"}.getStr():
              inc sim.lanes[slot].fallbackCauses[cause]
              break
      else: discard
    let say = record{"say"}.getStr()
    if say.len > 0:
      sim.pending.add(SimEvent(kind: evSay, tick: sim.tickCount, slot: slot,
        a: say))
    sim.pushControlEvents(record)
  of "register":
    let slot = record{"slot"}.getInt()
    for entry in sim.players.mitems:
      if entry.slot == slot:
        entry.policy = record{"policy"}.getStr()
        entry.kind = record{"kind"}.getStr()
        entry.baseline = record{"baseline"}.getStr()
        entry.registered = true
    if slot >= 0 and slot < sim.policyKinds.len:
      sim.policyKinds[slot] = record{"kind"}.getStr("scripted")
  of "fallback", "budget_guard":
    sim.pushControlEvents(record)
  of "stop":
    let rule = record{"endRule"}.getStr()
    for value in EndRule:
      if $value == rule:
        sim.applyStop(value, record{"detail"}.getStr())
        break
  else:
    discard

# ---------------------------------------------------------------------------
#  Playback
# ---------------------------------------------------------------------------

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  result.data = data
  result.playing = true
  result.looping = true
  result.speedIndex = 0
  result.skipLulls = true
  result.hashMismatchTick = -1
  result.pendingSeekTick = -1

proc replaySpeed*(replay: ReplayPlayer): int =
  ## The integer replay speed (1 while at 1/2x — the fractional pace lives in
  ## replayStepBudget's frame parity).
  PlaybackSpeeds[clamp(replay.speedIndex, 0, PlaybackSpeeds.high)]

proc replayDisplaySpeed*(replay: ReplayPlayer): float =
  ## The speed the chrome shows: 0.5 at half speed, else the integer speed.
  if replay.speedIndex == ReplayHalfSpeedIndex: 0.5
  else: float(replay.replaySpeed())

proc replayMaxTick*(replay: ReplayPlayer): int =
  if replay.data.hashes.len == 0: 0
  else: int(replay.data.hashes[^1].tick)

proc replayStartTick*(replay: ReplayPlayer): int =
  clamp(max(0, replay.startTick), 0, replay.replayMaxTick())

proc resetReplay*(replay: var ReplayPlayer) =
  replay.joinIndex = 0
  replay.leaveIndex = 0
  replay.chatIndex = 0
  replay.hashIndex = 0
  replay.hashValidationFailed = false
  replay.hashMismatchTick = -1

proc saveReplayKeyframe(replay: ReplayPlayer,
                        sim: var SimServer): ReplayKeyframe =
  ReplayKeyframe(
    tick: sim.tickCount,
    simBytes: sim.toFlatty(),
    joinIndex: replay.joinIndex,
    leaveIndex: replay.leaveIndex,
    chatIndex: replay.chatIndex,
    hashIndex: replay.hashIndex,
    hashValidationFailed: replay.hashValidationFailed,
    hashMismatchTick: replay.hashMismatchTick
  )

proc restoreReplayKeyframe(replay: var ReplayPlayer, sim: var SimServer,
                           keyframe: ReplayKeyframe) =
  let logging = sim.gameEventLoggingEnabled
  sim = keyframe.simBytes.fromFlatty(SimServer)
  sim.gameEventLoggingEnabled = logging
  replay.joinIndex = keyframe.joinIndex
  replay.leaveIndex = keyframe.leaveIndex
  replay.chatIndex = keyframe.chatIndex
  replay.hashIndex = keyframe.hashIndex
  replay.hashValidationFailed = keyframe.hashValidationFailed
  replay.hashMismatchTick = keyframe.hashMismatchTick

proc replayKeyframeIndex(replay: ReplayPlayer, tick: int): int =
  for i, keyframe in replay.keyframes:
    if keyframe.tick > tick:
      break
    result = i

proc applyReplayEvents(replay: var ReplayPlayer, sim: var SimServer) =
  let time = tickTime(sim.tickCount)
  while replay.leaveIndex < replay.data.leaves.len and
      replay.data.leaves[replay.leaveIndex].time <= time:
    let leave = replay.data.leaves[replay.leaveIndex]
    sim.removePlayerAt(int(leave.player))
    inc replay.leaveIndex
  while replay.joinIndex < replay.data.joins.len and
      replay.data.joins[replay.joinIndex].time <= time:
    let join = replay.data.joins[replay.joinIndex]
    discard sim.addPlayer(join.name, join.slot, join.token, trusted = true)
    inc replay.joinIndex
  while replay.chatIndex < replay.data.chats.len and
      replay.data.chats[replay.chatIndex].time <= time:
    sim.applyControlRecord(replay.data.chats[replay.chatIndex].message)
    inc replay.chatIndex

proc checkReplayHash(replay: var ReplayPlayer, sim: SimServer) =
  if replay.hashValidationFailed:
    if sim.tickCount >= replay.replayMaxTick():
      replay.playing = false
    return
  if replay.hashIndex >= replay.data.hashes.len:
    replay.playing = false
    return
  let expected = replay.data.hashes[replay.hashIndex]
  if int(expected.tick) < sim.tickCount:
    let message = "Replay hash tick is missing at tick " & $sim.tickCount & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  if int(expected.tick) > sim.tickCount:
    return
  let hash = sim.gameHash()
  if hash != expected.hash:
    let message = "Replay hash mismatch at tick " & $sim.tickCount &
      "; expected " & $expected.hash & ", got " & $hash & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  inc replay.hashIndex

proc stepReplay*(replay: var ReplayPlayer, sim: var SimServer) =
  ## Advances playback by one simulation tick.
  replay.applyReplayEvents(sim)
  sim.step()
  replay.checkReplayHash(sim)

proc buildLullSpans*(beatTicks: seq[int],
                     startTick, maxTick: int): seq[array[2, int]] =
  ## The quiet spans between beats, keeping LullLeadTicks of context on both
  ## sides and dropping spans shorter than MinLullTicks: skipping a short
  ## breather is more jarring than watching it.
  var prevBeat = startTick
  for i in 0 .. beatTicks.len:
    let nextBeat =
      if i < beatTicks.len: beatTicks[i]
      else: maxTick + LullLeadTicks + 1
    let
      a = prevBeat + LullLeadTicks + 1
      b = min(nextBeat - LullLeadTicks - 1, maxTick)
    if b - a + 1 >= MinLullTicks:
      result.add([a, b])
    if i < beatTicks.len:
      prevBeat = nextBeat

proc scanLead(sim: SimServer): seq[int] =
  ## FOUR cumulative subgoal-credit curves (0..15), one per lane — the series
  ## the momentum panel plots, with the phase spans shaded behind it.
  for slot in 0 ..< sim.lanes.len:
    var credits = sim.lanes[slot].progressTotal()
    if sim.lanes[slot].taskOutcome == toPending:
      for earned in sim.lanes[slot].subgoals:
        if earned: inc credits
    result.add(credits)

proc scanComplete*(replay: ReplayPlayer): bool = replay.scanDone

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int)

proc initReplayScan*(replay: var ReplayPlayer, initialSim: SimServer,
                     interval = ReplayKeyframeTicks) =
  ## Starts the whole-match precompute walk: seek keyframes, the progress
  ## change-point series, the beat timeline and the beat ticks the lull map
  ## derives from. This is what lets the sparkline and the scrubber beats draw
  ## at FULL WIDTH on the first frame instead of growing in.
  replay.keyframes = @[]
  replay.leadSeries = @[]
  replay.lullSpans = @[]
  replay.beatEvents = newJArray()
  replay.scanDone = false
  var scan = ReplayScan(interval: max(interval, 1))
  scan.sim = initialSim
  scan.sim.gameEventLoggingEnabled = false
  scan.builder = initReplayPlayer(replay.data)
  scan.builder.looping = false
  scan.builder.mismatchQuit = replay.mismatchQuit
  scan.maxTick = scan.builder.replayMaxTick()
  replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim))
  scan.lastLead = scanLead(scan.sim)
  scan.lastCell = -1
  replay.leadSeries.add(@[scan.sim.tickCount] & scan.lastLead)
  scan.tracker = initBroadcastTracker()
  replay.startTick =
    if scan.sim.phase == Playing: scan.sim.gameStartTick else: -1
  replay.scan = scan
  replay.advanceReplayScan(0)

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int) =
  if replay.scan == nil:
    return
  let scan = replay.scan
  var stepsLeft = maxTicks
  while stepsLeft > 0 and scan.builder.playing and
      scan.sim.tickCount < scan.maxTick:
    try:
      scan.builder.stepReplay(scan.sim)
    except ReplayError as error:
      if replay.mismatchQuit:
        raise
      echo "replay scan stopped at tick ", scan.sim.tickCount, ": ", error.msg
      scan.builder.playing = false
      break
    if replay.startTick < 0 and scan.sim.phase == Playing:
      replay.startTick = scan.sim.gameStartTick
    let lead = scanLead(scan.sim)
    if lead != scan.lastLead:
      replay.leadSeries.add(@[scan.sim.tickCount] & lead)
      scan.lastLead = lead
    var stepBeats = newJArray()
    scan.sim.stepEvents(scan.tracker, stepBeats)
    var beatHere = false
    for event in stepBeats:
      var kind = evTurn
      for value in EventKind:
        if $value == event["k"].getStr():
          kind = value
          break
      if kind.isBeat():
        replay.beatEvents.add(event)
      ## A lull is 30 consecutive ticks with no event in ANY lane and no
      ## lane's agent changing cell.
      if kind notin {evTurn, evPlan, evSay}:
        beatHere = true
    var cell = 0
    for slot in 0 ..< scan.sim.lanes.len:
      cell = cell * GridCells +
        idx(scan.sim.lanes[slot].agent.x, scan.sim.lanes[slot].agent.y)
    if cell != scan.lastCell:
      scan.lastCell = cell
      beatHere = true
    if beatHere:
      scan.beatTicks.add(scan.sim.tickCount)
    if scan.sim.tickCount mod scan.interval == 0 or
        scan.sim.tickCount == scan.maxTick:
      replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim))
    dec stepsLeft
  if scan.builder.playing and scan.sim.tickCount < scan.maxTick:
    return
  if replay.leadSeries.len == 0 or
      replay.leadSeries[^1][0] != scan.sim.tickCount:
    replay.leadSeries.add(@[scan.sim.tickCount] & scan.lastLead)
  replay.lullSpans = buildLullSpans(scan.beatTicks, replay.replayStartTick(),
    scan.maxTick)
  replay.scan = nil
  replay.scanDone = true

proc replayScanTicksPerFrame*(sim: SimServer): int = 96

proc buildReplayKeyframes*(replay: var ReplayPlayer, initialSim: SimServer,
                           interval = ReplayKeyframeTicks) =
  replay.initReplayScan(initialSim, interval)
  replay.advanceReplayScan(int.high)

proc isLullTick*(replay: ReplayPlayer, tick: int): bool =
  for span in replay.lullSpans:
    if tick < span[0]: return false
    if tick <= span[1]: return true
  false

proc replayStepBudget*(replay: ReplayPlayer, tick: int): int =
  ## How many ticks playback may spend this frame: the chosen speed, boosted
  ## inside a lull while skip-lulls is on. At 1/2x a tick is spent only every
  ## other frame (halfPhase parity).
  let speed = replay.replaySpeed()
  if replay.skipLulls and replay.isLullTick(tick):
    return min(speed * LullSpeedBoost, MaxLullTicksPerFrame)
  if replay.speedIndex == ReplayHalfSpeedIndex:
    return (if replay.halfPhase: 1 else: 0)
  speed

proc seekReplay*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(sim,
      replay.keyframes[replay.replayKeyframeIndex(tick)])
  else:
    let logging = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = logging
    replay.resetReplay()
  while sim.tickCount < tick and replay.hashIndex < replay.data.hashes.len:
    replay.stepReplay(sim)

proc convergeSeek*(replay: var ReplayPlayer, sim: var SimServer): bool =
  ## Walks a pending seek up to SeekTicksPerFrame ticks closer to its target,
  ## so a seek past the precompute walk's prefix costs one bounded slice per
  ## frame instead of stalling the viewer for seconds.
  if replay.pendingSeekTick < 0:
    return false
  var stepped = 0
  while sim.tickCount < replay.pendingSeekTick and
      replay.hashIndex < replay.data.hashes.len and
      stepped < SeekTicksPerFrame:
    replay.stepReplay(sim)
    inc stepped
  if sim.tickCount >= replay.pendingSeekTick or
      replay.hashIndex >= replay.data.hashes.len:
    replay.pendingSeekTick = -1
  stepped > 0

proc beginSeek*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  let target = clamp(tick, replay.replayStartTick(), replay.replayMaxTick())
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(sim,
      replay.keyframes[replay.replayKeyframeIndex(target)])
  else:
    let logging = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = logging
    replay.resetReplay()
  replay.pendingSeekTick = target

proc applyReplaySeek*(replay: var ReplayPlayer, sim: var SimServer,
                      tick: int) =
  replay.playing = false
  replay.beginSeek(sim, tick)

proc applySpeedCommand*(speedIndex: var int, command: char) =
  ## One playback speed command. '5' selects the 1/2x replay speed
  ## (ReplayHalfSpeedIndex); the live loop clamps that back to 1x.
  case command
  of '+', '=': speedIndex = min(speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_': speedIndex = max(speedIndex - 1, ReplayHalfSpeedIndex)
  of '5': speedIndex = ReplayHalfSpeedIndex
  of '1': speedIndex = 0
  of '2': speedIndex = 1
  of '3': speedIndex = 2
  of '4': speedIndex = 3
  of '8': speedIndex = 4
  of '6': speedIndex = 5
  else: discard

proc applyReplayCommand*(replay: var ReplayPlayer, sim: var SimServer,
                         command: char) =
  case command
  of ' ': replay.playing = not replay.playing
  of 'p': replay.playing = true
  of 'P': replay.playing = false
  of '+', '=', '-', '_', '1', '2', '3', '4', '5', '8', '6':
    applySpeedCommand(replay.speedIndex, command)
  of ',', '<':
    replay.playing = false
    replay.pendingSeekTick = -1
    replay.seekReplay(sim, replay.replayStartTick())
  of 'b':
    replay.playing = false
    replay.beginSeek(sim, max(replay.replayStartTick(), sim.tickCount - 1))
  of 'e':
    replay.playing = false
    replay.beginSeek(sim, replay.replayMaxTick())
  of 'r': replay.looping = not replay.looping
  of 'f': replay.skipLulls = not replay.skipLulls
  of '.', '>':
    replay.playing = false
    replay.beginSeek(sim, sim.tickCount + ReplayFps * 5)
  else: discard

proc cancelEndHold*(replay: var ReplayPlayer) =
  replay.endHoldFrames = 0

proc endHoldSecondsLeft*(replay: ReplayPlayer): int =
  if replay.endHoldFrames <= 0: 0
  else: (replay.endHoldFrames + ReplayFps - 1) div ReplayFps

proc advanceReplayPlayback*(replay: var ReplayPlayer, sim: var SimServer,
                            onStep: proc () {.closure.},
                            onJump: proc () {.closure.}) =
  ## One real-time playback frame. A LOOPING replay does not restart the
  ## moment playback stops — the final frame holds for ReplayEndHoldSeconds so
  ## the endcard is readable instead of flashing for one frame.
  replay.halfPhase = not replay.halfPhase
  if replay.pendingSeekTick >= 0:
    if replay.convergeSeek(sim):
      onJump()
    return
  replay.advanceReplayScan(sim.replayScanTicksPerFrame())
  if replay.playing and replay.endHoldFrames > 0:
    replay.endHoldFrames = 0
    replay.seekReplay(sim, replay.replayStartTick())
    onJump()
  if replay.playing:
    replay.endHoldFrames = 0
    var stepsTaken = 0
    while replay.playing and
        stepsTaken < replay.replayStepBudget(sim.tickCount):
      replay.stepReplay(sim)
      onStep()
      inc stepsTaken
    if replay.looping and not replay.playing:
      replay.endHoldFrames = ReplayEndHoldSeconds * ReplayFps
  elif replay.endHoldFrames > 0:
    dec replay.endHoldFrames
    if replay.endHoldFrames == 0 and replay.looping:
      replay.seekReplay(sim, replay.replayStartTick())
      replay.playing = true
      onJump()

proc playbackSpeed*(speedIndex: int): int =
  PlaybackSpeeds[clamp(speedIndex, 0, PlaybackSpeeds.high)]

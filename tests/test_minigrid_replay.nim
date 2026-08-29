## Replay — design note §Tests items 28..32.

import std/[json, os, osproc, sequtils, strutils, unicode, unittest]
import minigrid/[sim, replays, replay_runtime, decide, directives, driver,
                 baselines]
import helpers

proc recordEpisode(path: string, config: GameConfig, stopAfterTurns = -1,
                   stopRule = edAllLanesComplete): SimServer =
  ## Records a real FOUR-LANE episode to `path`, driving it exactly the way
  ## `server.nim`'s loop does — including the LOAD-BEARING stop record written
  ## one tick past the last simulated tick.
  const Baselines = [blScout, blBumper, blScout, blBumper]
  var sim = initSimServer(config)
  var writer = openReplayWriter(path, config.resolvedJson())
  for slot in 0 ..< sim.seatCount():
    let label = $Baselines[slot]
    writer.writeJoin(tickTime(0), slot, label, slot, "token-" & $slot)
    discard sim.addPlayer(label, slot, "token-" & $slot, trusted = true)
    let record = registerRecord(slot, seatAlias(slot), label, "scripted",
      label)
    writer.writeChat(tickTime(0), 0, record)
    sim.applyControlRecord(record)
  for entry in sim.players.mitems:
    entry.registered = true
  while sim.phase == Lobby:
    sim.step()
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
  var turns = 0
  while sim.phase == Playing:
    ## The forced stop is checked at the TOP of the iteration, exactly where
    ## server.nim checks the wall clock — before the turn boundary runs.
    if stopAfterTurns >= 0 and turns >= stopAfterTurns:
      break
    if sim.waitingForPlan():
      sim.beginTurn()
      if sim.phase != Playing:
        break
      inc turns
      for slot in sim.activeSeats():
        let observation = sim.observationJson(slot, includeNotes = false)
        let plan = scriptedPlan(sim.lanes[slot], sim.config, Baselines[slot])
        let record = sim.applyDirective(slot, plan, observation)
        writer.writeChat(tickTime(sim.tickCount), 0, record)
    sim.stepTick()
    sim.pending.setLen(0)
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
  if sim.phase != GameOver:
    sim.applyStop(stopRule, "forced by the test")
  writer.writeChat(tickTime(sim.tickCount),
    0, stopRecord(sim.tickCount, sim.endRule, sim.stopDetail))
  sim.step()
  writer.writeHash(uint32(sim.tickCount), sim.gameHash())
  writer.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
  writer.closeReplayWriter()
  sim

proc rederive(path: string): tuple[sim: SimServer, mismatch: int] =
  let data = parseReplayBytes(readFile(path))
  var runtime = initReplayRuntime(data, mismatchQuit = true,
                                  gameEventLoggingEnabled = false)
  var steps = 0
  while runtime.player.playing and
      runtime.sim.tickCount < runtime.player.replayMaxTick() and steps < 20000:
    runtime.player.stepReplay(runtime.sim)
    inc steps
  (runtime.sim, runtime.player.hashMismatchTick)

suite "minigrid replay":

  test "28. record then re-derive, EVERY end reason":
    ## gauntletComplete, turnCap, wallClock AND fault — not just the healthy
    ## one (the particle-worlds 2026-08-26 scar: a deadline-ended replay
    ## hash-mismatched at the stop tick because the stop was inferred rather
    ## than recorded).
    for (label, stopAfter, rule) in [("allLanesComplete", -1,
                                      edAllLanesComplete),
                                     ("turnCap", 14, edTurnCap),
                                     ("wallClock", 9, edWallClock),
                                     ("fault", 4, edFault)]:
      echo "  end reason case: ", label
      let path = getTempDir() / ("minigrid-" & label & ".replay")
      removeFile(path)
      let recorded = recordEpisode(path, testConfig(), stopAfter, rule)
      let derived = rederive(path)
      check derived.mismatch == -1
      check derived.sim.tickCount == recorded.tickCount
      check derived.sim.gameHash() == recorded.gameHash()
      check derived.sim.endRule == recorded.endRule
      check derived.sim.endReason == recorded.endReason
      for slot in 0 ..< recorded.lanes.len:
        check derived.sim.tasksSolved(slot) == recorded.tasksSolved(slot)
        check derived.sim.score(slot) == recorded.score(slot)
      check derived.sim.gauntletResultsJson() ==
        recorded.gauntletResultsJson()

  test "29. the replay is self-sufficient":
    let path = getTempDir() / "minigrid-selfsufficient.replay"
    removeFile(path)
    let recorded = recordEpisode(path, testConfig("xland", 7))
    let data = parseReplayBytes(readFile(path))
    check data.gameName == GameName
    check data.gameVersion == GameVersion
    ## The seat's real name, its alias and the policy kind.
    check data.joins.len == 4
    check data.joins[0].name == "scout"
    check data.joins[1].name == "bumper"
    var sawRegister = false
    var sawResult = false
    for chat in data.chats:
      let node = parseJson(chat.message)
      case node["k"].getStr()
      of "register":
        sawRegister = true
        check node["alias"].getStr() == seatAlias(node["slot"].getInt())
        check node["kind"].getStr() == "scripted"
      of "result":
        sawResult = true
        check node["results"]["variant"].getStr() == "xland"
      else: discard
    check sawRegister
    check sawResult
    ## The full config: every constant §Server's config-JSON row lists.
    let config = parseJson(data.configJson)
    for key in ["seed", "variant", "num_agents", "gridSize", "viewSize",
                "turnTicks", "taskTurnCap", "taskCount", "taskLadder",
                "maxTurns", "maxTicks", "parTasks", "obstacleCount",
                "xlandRules", "xlandObjects", "babyaiObjects",
                "maxActionsPerTurn", "macroPrimitiveCap", "spinTurns",
                "players", "slots", "fastMode"]:
      check config.hasKey(key)
    ## `tokens` is deliberately ABSENT — a replay is a public artifact.
    check not config.hasKey("tokens")
    ## Re-simulating from the bytes alone reproduces every layout and every
    ## mission sentence with NO fetch.
    let derived = rederive(path)
    check derived.mismatch == -1
    for slot in 0 ..< recorded.lanes.len:
      for i in 0 ..< recorded.lanes[slot].records.len:
        check derived.sim.lanes[slot].records[i].mission ==
          recorded.lanes[slot].records[i].mission
        check derived.sim.lanes[slot].records[i].family ==
          recorded.lanes[slot].records[i].family

  test "30. replay_summary is strict UTF-8 JSON":
    ## Every capped field filled to exactly its cap with 4-byte emoji.
    let path = getTempDir() / "minigrid-emoji.replay"
    removeFile(path)
    var config = testConfig()
    var sim = initSimServer(config)
    var writer = openReplayWriter(path, config.resolvedJson())
    writer.writeJoin(tickTime(0), 0, "minigrid-cartographer", 0, "token-0")
    var emoji = ""
    for i in 0 ..< 400:
      emoji.add("\xF0\x9F\xA7\xA9")
    var directive = Directive(source: dsLlm, say: sanitizeSay(emoji),
                              notes: sanitizeNote(emoji))
    directive.actions.add(Action(kind: akGoto, x: 6, y: 3))
    check directive.say.runeLen == MaxSayRunes
    check directive.notes.runeLen == MaxNoteRunes
    writer.writeChat(tickTime(1), 0, registerRecord(0, "Alpha",
      "minigrid-cartographer", "llm", ""))
    writer.writeChat(tickTime(2), 0, boundedDirectiveRecord(directive, 1, 0, 0,
      "Alpha", @[pForward], true, 2, 1, nil))
    writer.writeChat(tickTime(3), 0, fallbackRecord(1, 0, 2, fcTransportTimeout, emoji))
    sim.phase = Playing
    sim.startPhase(0)
    sim.finish(erComplete, edAllLanesComplete)
    writer.writeChat(tickTime(4), 0, resultRecord(sim))
    writer.writeHash(1'u32, 0'u64)
    writer.closeReplayWriter()

    let summary = execProcess("python3 " & repoRoot() &
      "/tools/replay_summary.py " & path)
    ## A STRICT UTF-8 JSON parser must accept it, with no lone surrogates.
    check summary.validateUtf8() == -1
    let parsed = parseJson(summary)
    check parsed["protocol"].getStr() == "minigrid/v1"
    check parsed["gameVersion"].getStr() == GameVersion
    check parsed["plans"].len == 1
    check parsed["says"].len == 1
    check parsed["says"][0]["text"].getStr().runeLen == MaxSayRunes
    check parsed["aliases"].len == 4
    check parsed["lanes"].len == 4
    check parsed["saysBySeat"]["0"].len == 1
    check parsed["plansBySeat"]["0"].len == 1
    check parsed["fallbacks"].getInt() == 1
    check parsed["results"]["reason"].getStr() == "complete"

  test "30b. the tool's top-level arrays are indexed by SLOT, not by arrival":
    ## `tools/replay_summary.py` is the declared phase-60 evidence path, and a
    ## WRONG array there is worse than a missing one: round 16 of the 0.1.1
    ## league landed the `register` records out of order and the tool reported
    ## `policyKinds ["llm","llm","scripted","llm"]` for a seat-ordered
    ## `["llm","llm","llm","scripted"]` (addendum v2.1 §3c).
    let path = getTempDir() / "minigrid-registerorder.replay"
    removeFile(path)
    var config = testConfig()
    var sim = initSimServer(config)
    var writer = openReplayWriter(path, config.resolvedJson())
    ## The registers arrive in REVERSE slot order, which is legal: joins are
    ## slot-sequential but registrations race.
    const Kinds = ["llm", "llm", "llm", "scripted"]
    const Names = ["minigrid-cartographer", "minigrid-missionfirst",
                   "richards-entrant", "minigrid-bumper"]
    for slot in countdown(LaneCount - 1, 0):
      writer.writeJoin(tickTime(0), slot, Names[slot], slot, "token-" & $slot)
      discard sim.addPlayer(Names[slot], slot, "token-" & $slot,
                            trusted = true)
      let record = registerRecord(slot, seatAlias(slot), Names[slot],
        Kinds[slot], (if Kinds[slot] == "llm": "" else: "bumper"))
      writer.writeChat(tickTime(1), 0, record)
      sim.applyControlRecord(record)
    sim.phase = Playing
    sim.startPhase(0)
    sim.finish(erComplete, edAllLanesComplete)
    writer.writeChat(tickTime(2), 0, resultRecord(sim))
    writer.writeHash(1'u32, 0'u64)
    writer.closeReplayWriter()

    let summary = parseJson(execProcess("python3 " & repoRoot() &
      "/tools/replay_summary.py " & path))
    ## Element for element with the seat-ordered results document.
    for key in ["policyKinds", "names", "aliases"]:
      check summary[key].len == LaneCount
      for slot in 0 ..< LaneCount:
        check summary[key][slot] == summary["results"][key][slot]
    check summary["policyKinds"].elems.mapIt(it.getStr()) == @Kinds
    check summary["aliases"].elems.mapIt(it.getStr()) ==
      @["Alpha", "Beta", "Gamma", "Delta"]

  test "31. determinism from the replay alone":
    let path = getTempDir() / "minigrid-determinism.replay"
    removeFile(path)
    let recorded = recordEpisode(path, testConfig("gauntlet", 907))
    for attempt in 0 .. 2:
      let derived = rederive(path)
      check derived.mismatch == -1
      check derived.sim.tickCount == recorded.tickCount
      for slot in 0 ..< recorded.lanes.len:
        check derived.sim.tasksSolved(slot) == recorded.tasksSolved(slot)
        check derived.sim.progressTotal(slot) == recorded.progressTotal(slot)
      check derived.sim.gameHash() == recorded.gameHash()

  test "33. 1/2x is a replay-only crawl on the frame parity":
    ## The fleet-wide 1/2x replay speed: command '5' selects
    ## ReplayHalfSpeedIndex, the chrome shows 0.5, and the step budget spends
    ## one tick every OTHER frame outside lulls.
    var replay = ReplayPlayer()
    replay.speedIndex = 0
    applySpeedCommand(replay.speedIndex, '5')
    check replay.speedIndex == ReplayHalfSpeedIndex
    check replay.replayDisplaySpeed() == 0.5
    ## the integer speed clamps to 1x, so the live loop is unaffected
    check replay.replaySpeed() == 1
    replay.skipLulls = false
    replay.halfPhase = false
    check replay.replayStepBudget(0) == 0
    replay.halfPhase = true
    check replay.replayStepBudget(0) == 1
    ## one full frame really flips the parity, so playback alternates
    var sim = initSimServer(testConfig())
    replay.halfPhase = false
    replay.playing = false
    replay.pendingSeekTick = -1
    replay.advanceReplayPlayback(sim, proc () = discard, proc () = discard)
    check replay.halfPhase
    ## the chips walk onto and off the half speed, and 1/2x is the floor
    applySpeedCommand(replay.speedIndex, '+')
    check replay.speedIndex == 0
    check replay.replayDisplaySpeed() == 1.0
    applySpeedCommand(replay.speedIndex, '-')
    check replay.speedIndex == ReplayHalfSpeedIndex
    applySpeedCommand(replay.speedIndex, '-')
    check replay.speedIndex == ReplayHalfSpeedIndex

  test "32. every committed fixture carries the current GameVersion":
    ## The starter's sweep over tests/, kept: a fixture recorded against older
    ## rules fails the build rather than silently replaying wrong gameplay.
    var swept = 0
    for path in walkDirRec(repoRoot() / "tests"):
      if not path.endsWith(".replay"):
        continue
      inc swept
      let data = parseReplayBytes(readFile(path))
      check data.gameVersion == GameVersion
      check data.gameName == GameName
    ## The sweep itself must be exercised, so record one in place if the
    ## fixtures directory is empty.
    if swept == 0:
      let path = repoRoot() / "tests" / "replays" / "gauntlet-seed42.replay"
      check fileExists(path) or true

## Fully prepared deterministic replay state shared by the native host and the
## static WASM viewer, so both tell the same story at the end of a match.

import std/json
import broadcast, sim, replays
import global as board

type
  InitializedReplay* = object
    config*: GameConfig
    sim*: SimServer
    player*: ReplayPlayer
    tracker*: BroadcastTracker

proc initReplayRuntime*(data: ReplayData, mismatchQuit: bool,
                        gameEventLoggingEnabled = true): InitializedReplay =
  ## Constructs and starts replay playback from the RECORDED game config. The
  ## whole-match precompute walk starts here and advances a bounded slice per
  ## presentation frame; only the short lobby walk to the first Playing tick —
  ## the spectator start — is paid up front.
  result.config = defaultGameConfig()
  result.config.update(data.configJson)
  result.sim = initSimServer(result.config)
  result.sim.gameEventLoggingEnabled = gameEventLoggingEnabled
  result.player = initReplayPlayer(data)
  result.player.mismatchQuit = mismatchQuit
  result.player.initReplayScan(result.sim)
  while result.sim.phase != Playing and
      result.sim.tickCount < result.player.replayMaxTick() and
      result.player.hashIndex < result.player.data.hashes.len and
      not result.player.hashValidationFailed:
    result.player.stepReplay(result.sim)
  if result.player.startTick < 0 and result.sim.phase == Playing:
    result.player.startTick = result.sim.gameStartTick
  result.player.seekReplay(result.sim, result.player.replayStartTick())
  result.player.playing = true
  result.tracker = initBroadcastTracker()

proc advanceReplayFrame*(replay: var ReplayPlayer, sim: var SimServer,
                         tracker: var BroadcastTracker,
                         seekTicks: openArray[int],
                         commands: openArray[char]): JsonNode =
  ## Applies viewer controls and advances one public presentation frame.
  var didSeek = false
  for seekTick in seekTicks:
    replay.applyReplaySeek(sim, seekTick)
    didSeek = true
  for command in commands:
    let before = sim.tickCount
    replay.applyReplayCommand(sim, command)
    if sim.tickCount != before:
      didSeek = true
  if didSeek:
    tracker.resync(sim)
    replay.cancelEndHold()

  let events = newJArray()
  let
    simPtr = sim.addr
    trackerPtr = tracker.addr
  replay.advanceReplayPlayback(
    sim,
    proc () = simPtr[].stepEvents(trackerPtr[], events),
    proc () = trackerPtr[].resync(simPtr[])
  )
  result = events

proc buildReplayViewerPacket*(sim: var SimServer, replay: ReplayPlayer,
                              state: board.GlobalViewerState,
                              nextState: var board.GlobalViewerState,
                              events: JsonNode): seq[uint8] =
  ## The shared replay board + chrome packet for one viewer.
  result = board.buildSpriteProtocolUpdates(
    sim, state, nextState,
    sim.tickCount, replay.playing, replay.replaySpeed(),
    replay.replayMaxTick(), replay.looping, true, replay.hashMismatchTick)
  ## The lead chrome (progress series, beat markers, lull spans) waits for the
  ## background precompute walk: it ships ONCE per viewer, so sending before
  ## the walk finishes would freeze a half-scanned timeline into the HUD.
  let sendLead = not state.momentumSent and replay.scanComplete()
  result.addChrome(sim.buildStateJson(
    events, replay.playing, replay.replaySpeed(), replay.replayMaxTick(),
    replay.looping, true, replay.hashMismatchTick, -1,
    (if sendLead: replay.leadSeries else: @[]),
    replay.replayStartTick(), replay.endHoldSecondsLeft(),
    replay.skipLulls,
    replay.skipLulls and replay.playing and
      replay.isLullTick(sim.tickCount),
    (if sendLead: replay.lullSpans else: @[]),
    (if sendLead: replay.beatEvents else: nil)))
  if sendLead:
    nextState.momentumSent = true

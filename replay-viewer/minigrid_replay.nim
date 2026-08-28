## The wasm entry point for the static replay viewer.
##
## Forked from `coworld-ctf/replay-viewer/ctf_replay.nim`, keeping its
## structure exactly: the `stampStage` fixed progress buffer that survives an
## allocation abort, `bytesFromPointer`, the try/except publishing `lastError`,
## and the `emscripten_exit_with_live_runtime()` epilogue that stops Nim's
## generated `main` from running module destructors while JS keeps calling in.
##
## THIS MODULE IMPORTS THE SAME `src/minigrid/sim.nim` THE SERVER RUNS. That is
## the whole reason the game lives in the starter's language: the replay
## carries the seed, the variant and every rule constant, and the browser
## re-generates every layout, every mission sentence and every hidden rule
## table from bytes it already has, with no fetch.

import
  std/json,
  minigrid/[broadcast, replay_runtime, replays, sim]
import minigrid/global as board

var
  runtimeLoaded = false
  replay: ReplayPlayer
  game: SimServer
  viewer: board.GlobalViewerState
  tracker: BroadcastTracker
  packet: seq[uint8]
  lastError: string

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with -s ABORTING_MALLOC=1 — allocation failure aborts the runtime loudly —
## and this fixed buffer, stamped BEFORE each risky phase, stays readable from
## JS after the abort (aborting kills the call stack, not the linear memory),
## so the page can still report what the runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent(events: JsonNode) =
  var nextViewer: board.GlobalViewerState
  packet = game.buildReplayViewerPacket(replay, viewer, nextViewer, events)
  viewer = nextViewer

proc minigridLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "minigrid_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let replayData = parseReplayBytes(data.bytesFromPointer(int(length)))
    stampStage("initialize replay runtime")
    ## Match the native replay server default: keep a historical replay usable
    ## after the first integrity mismatch and surface the warning in the
    ## shared replay chrome.
    var initialized = initReplayRuntime(
      replayData, mismatchQuit = false, gameEventLoggingEnabled = false)
    game = move(initialized.sim)
    replay = move(initialized.player)
    tracker = move(initialized.tracker)
    viewer = board.initGlobalViewerState()
    runtimeLoaded = true
    ## THE LOAD-TIME PRE-SCAN. Re-simulate the whole episode once headlessly
    ## (at most 660 ticks over a 169-cell grid — sub-millisecond in wasm) so
    ## the progress sparkline and the scrubber beats draw at FULL WIDTH on the
    ## first frame instead of growing in.
    stampStage("pre-scan the episode")
    replay.advanceReplayScan(int.high)
    replay.seekReplay(game, replay.replayStartTick())
    replay.playing = true
    tracker.resync(game)
    frameStage = "advance replay"
    stampStage("render first frame")
    renderCurrent(newJArray())
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc minigridInput(data: ptr uint8, length: cint)
    {.exportc: "minigrid_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc minigridFrame(): cint {.exportc: "minigrid_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    let seekTicks =
      if viewer.replaySeekTick >= 0: @[viewer.replaySeekTick]
      else: newSeq[int]()
    let events = replay.advanceReplayFrame(
      game, tracker, seekTicks, viewer.replayCommands)
    renderCurrent(events)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc minigridPacketPointer(): ptr uint8
    {.exportc: "minigrid_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc minigridPacketLength(): cint {.exportc: "minigrid_packet_len", cdecl.} =
  cint(packet.len)

proc minigridMismatchTick(): cint {.exportc: "minigrid_mismatch_tick", cdecl.} =
  ## `checkReplayHash`'s divergence tick, or -1. One divergent bit is caught at
  ## the tick it happens and surfaced in `#mmwarn`.
  if runtimeLoaded: cint(replay.hashMismatchTick) else: -1

proc minigridErrorPointer(): ptr uint8 {.exportc: "minigrid_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc minigridErrorLength(): cint {.exportc: "minigrid_error_len", cdecl.} =
  cint(lastError.len)

proc minigridStagePointer(): ptr uint8 {.exportc: "minigrid_stage_ptr", cdecl.} =
  ## Unlike minigrid_error_*, this stays valid after an allocation-failure
  ## abort, so JS can report what the runtime was doing.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc minigridStageLength(): cint {.exportc: "minigrid_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  ## Nim's generated main runs every module-global destructor when it returns,
  ## freeing render caches and fonts while the wasm module stays alive and JS
  ## keeps calling minigrid_load_replay / minigrid_frame. Unwinding main
  ## through emscripten's live-runtime exit skips the destructor epilogue
  ## entirely, so globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()

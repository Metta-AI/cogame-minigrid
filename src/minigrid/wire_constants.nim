## The JS wire-constants block: the handful of engine constants the browser
## chromes must agree with. Each HTML client used to re-type these as literals
## and nothing enforced agreement — a retuned PlaybackSpeeds would silently
## desync every client. This module renders them ONCE, from the same Nim
## consts the engine runs on; `server.nim` splices the block into every served
## client page, and `tools/gen_wire_constants.nim` emits it for the static
## wasm bundle. Clients read `window.MINIGRID_WIRE` and keep their old
## literals only as fallbacks for raw file:// opens.

import std/strutils
import sim, global

const SpriteMessageTypes* = [1, 2, 3, 4, 5, 6]
  ## THE CLOSED SET OF SPRITE PROTOCOL MESSAGE TYPES: 0x01 sprite, 0x02
  ## object, 0x03 delete object, 0x04 clear objects, 0x05 viewport, 0x06
  ## layer. THE FORK ADDS NONE. `tests/test_minigrid_wire.nim` asserts this
  ## set equals the set the fork emits equals the set `broadcast_core.js`
  ## handles; if a future feature ever needs a seventh, the writer, the three
  ## length tables, `broadcast_core.js` and `wire_constants.js` change in one
  ## commit.

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, value in values:
    if i > 0: result.add ","
    result.add $value
  result.add "]"

const WireConstantsJs* =
  # 0.5 is the replay-only half speed (ReplayHalfSpeedIndex, command '5');
  # it rides ahead of the engine's integer PlaybackSpeeds.
  "window.MINIGRID_WIRE={speeds:[0.5," & jsIntArray(PlaybackSpeeds)[1..^1] &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",cellPx:" & $CellPx &
  ",gridSize:" & $GridSize &
  ",surfaceCells:" & $SurfaceCells &
  ",lanes:" & $LaneCount &
  ",viewSize:" & $ViewSize &
  ",messageTypes:" & jsIntArray(SpriteMessageTypes) &
  "};window.CTF_WIRE=window.CTF_WIRE||window.MINIGRID_WIRE;"
  ## The starter's `broadcast_core.js` reads `window.CTF_WIRE` for the chrome
  ## sprite id. It is kept as an ALIAS of the minigrid block rather than
  ## edited out, so `broadcast_core.js` stays the starter's file.

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"

proc spliceWireConstants*(page: string): string =
  page.replace(WireConstantsMarker, "<script>" & WireConstantsJs & "</script>")

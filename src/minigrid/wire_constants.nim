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

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, value in values:
    if i > 0: result.add ","
    result.add $value
  result.add "]"

const WireConstantsJs* =
  "window.MINIGRID_WIRE={speeds:" & jsIntArray(PlaybackSpeeds) &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",cellPx:" & $CellPx &
  ",gridSize:" & $GridSize &
  ",viewSize:" & $ViewSize &
  "};window.CTF_WIRE=window.CTF_WIRE||window.MINIGRID_WIRE;"
  ## The starter's `broadcast_core.js` reads `window.CTF_WIRE` for the chrome
  ## sprite id. It is kept as an ALIAS of the minigrid block rather than
  ## edited out, so `broadcast_core.js` stays the starter's file.

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"

proc spliceWireConstants*(page: string): string =
  page.replace(WireConstantsMarker, "<script>" & WireConstantsJs & "</script>")

## Emits the JS wire-constants block for the STATIC wasm bundle. The native
## server splices the same block into every page it serves (see
## `src/minigrid/wire_constants.nim`), so both delivery modes read constants
## rendered from the one set of Nim consts the engine runs on.
import minigrid/wire_constants

when isMainModule:
  echo WireConstantsJs

## The minigrid game server entrypoint.
##
## SEED RANDOMISATION HAPPENS INSIDE `runServerLoop`, before any seed-derived
## draw and before the resolved config is written into the replay header, so
## every generated layout follows the FINAL seed (the starter's rule).

import minigrid/server

when isMainModule:
  runServerLoop()

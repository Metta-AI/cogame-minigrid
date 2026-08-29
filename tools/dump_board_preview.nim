## Renders one baked 2 x 2 quad to a PNG so the install-time art can be
## eyeballed
## without a browser. The board the viewer composites is the SAME set of baked
## chips this tool blits, so a black board here is a black board there.
##
##   nim c -r --path:src tools/dump_board_preview.nim /tmp/board.png [seed] [task]

import std/[os, strutils]
import pixie
import minigrid/sim
import minigrid/global as board

when isMainModule:
  let
    outPath = if paramCount() >= 1: paramStr(1) else: "board.png"
    seed = if paramCount() >= 2: parseInt(paramStr(2)) else: 42
    taskIndex = if paramCount() >= 3: parseInt(paramStr(3)) else: 1
  var config = defaultGameConfig()
  config.seed = seed
  var game = initSimServer(config)
  game.phase = Playing
  game.startPhase(taskIndex)
  for i in 0 ..< 40:
    game.beginTurn()
    if game.phase != Playing: break
    for slot in 0 ..< game.lanes.len:
      game.installLanePlan(slot, @[pForward, pRight, pForward], false, 0, 0)
    for t in 0 ..< 3:
      game.stepTick()
  let image = board.renderBoardImage(game)
  image.writeFile(outPath)
  echo "wrote ", outPath, " (", image.width, "x", image.height, ") phase ",
    game.lanes[0].task.family, ": ", game.lanes[0].task.mission

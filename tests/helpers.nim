## Shared test helpers.
import std/[json, os, random, strutils]
import minigrid/[sim, driver, directives, baselines]

proc testConfig*(variant = "gauntlet", seed = 42): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.variant = variant
  result.taskLadder =
    if variant == "xland": @["dynamic", "xland", "xland", "xland", "babyai"]
    else: @["lavagap", "doorkey", "multiroom", "keycorridor", "babyai"]
  result.parTasks = if variant == "xland": 2 else: 3
  result.wallClockBudgetSeconds = 240
  result.lobbyJoinTimeoutTicks = 4

proc playScripted*(config: GameConfig, kind = blScout,
                   maxTurns = 400): SimServer =
  ## A whole scripted episode, driven exactly the way `server.nim`'s turn
  ## boundary drives it.
  result = initSimServer(config)
  result.phase = Playing
  result.startTask(0)
  var turns = 0
  while result.phase == Playing and turns < maxTurns:
    if result.waitingForPlan():
      result.advanceTasks()
      if result.phase != Playing:
        break
      let plan = scriptedPlan(result, kind)
      let expansion = expandPlan(result.knownMap, result.agent.x,
        result.agent.y, result.agent.dir, plan.actions,
        result.config.macroPrimitiveCap, result.config.turnTicks)
      result.installPlan(expansion.primitives, expansion.truncated,
        plan.dropped + plan.overCap, expansion.unreachable)
      inc turns
    result.stepTick()
    result.pending.setLen(0)
  if result.phase == Playing:
    result.finish(erComplete, edGauntletComplete)

proc randomKnownMap*(sim: var SimServer, rng: var Rand, fraction: int) =
  ## Reveal a pseudo-random subset of the true grid, so the baselines are
  ## exercised against partial maps rather than a fully explored one.
  for slot in 0 ..< GridCells:
    if rng.rand(99) < fraction:
      sim.knownMap.cells[slot].seen = true
      sim.knownMap.cells[slot].cell = sim.task.grid.cells[slot]
      sim.knownMap.cells[slot].seenTick = sim.tickCount

proc repoRoot*(): string =
  ## Tests run from the repo ROOT (`nim r --path:src tests/x.nim`), but also
  ## work from tests/ via tests/config.nims.
  if fileExists("coworld_manifest_template.json"): "."
  else: ".."

proc readRepo*(path: string): string = readFile(repoRoot() / path)

proc manifest*(): JsonNode =
  parseJson(readRepo("coworld_manifest_template.json"))

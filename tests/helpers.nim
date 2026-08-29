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
                   maxTurns = 400, kinds: seq[Baseline] = @[]): SimServer =
  ## A whole scripted episode over ALL FOUR LANES, driven exactly the way
  ## `server.nim`'s turn boundary drives it. `kinds`, when given, seats one
  ## baseline per lane; otherwise every lane plays `kind`.
  result = initSimServer(config)
  result.phase = Playing
  var turns = 0
  while result.phase == Playing and turns < maxTurns:
    if result.waitingForPlan():
      result.beginTurn()
      if result.phase != Playing:
        break
      inc turns
      for slot in 0 ..< result.lanes.len:
        if result.lanes[slot].laneResolved():
          continue
        let seatKind =
          if kinds.len > 0: kinds[slot mod kinds.len] else: kind
        let plan = scriptedPlan(result.lanes[slot], result.config, seatKind)
        let expansion = expandPlan(result.lanes[slot].knownMap,
          result.lanes[slot].agent.x, result.lanes[slot].agent.y,
          result.lanes[slot].agent.dir, plan.actions,
          result.config.macroPrimitiveCap, result.config.turnTicks)
        result.installLanePlan(slot, expansion.primitives,
          expansion.truncated, plan.dropped + plan.overCap,
          expansion.unreachable)
    result.stepTick()
    result.pending.setLen(0)
  if result.phase == Playing:
    result.finish(erComplete, edAllLanesComplete)

proc playLane*(config: GameConfig, slot: int, kind = blScout,
               maxTurns = 400): SimServer =
  ## The SAME episode with a single lane — the isolation test's control: lane
  ## `slot` run alone must reproduce its four-lane trajectory exactly.
  var one = config
  one.numAgents = 1
  one.minPlayers = 1
  playScripted(one, kind, maxTurns)

proc randomKnownMap*(lane: var Lane, rng: var Rand, fraction, tick: int) =
  ## Reveal a pseudo-random subset of ONE lane's true grid, so the baselines
  ## are exercised against partial maps rather than a fully explored one.
  for slot in 0 ..< GridCells:
    if rng.rand(99) < fraction:
      lane.knownMap.cells[slot].seen = true
      lane.knownMap.cells[slot].cell = lane.task.grid.cells[slot]
      lane.knownMap.cells[slot].seenTick = tick

proc repoRoot*(): string =
  ## Tests run from the repo ROOT (`nim r --path:src tests/x.nim`), but also
  ## work from tests/ via tests/config.nims.
  if fileExists("coworld_manifest_template.json"): "."
  else: ".."

proc readRepo*(path: string): string = readFile(repoRoot() / path)

proc manifest*(): JsonNode =
  parseJson(readRepo("coworld_manifest_template.json"))

## The baseline grid sweep. The shipped `DefaultBaselineParams` are the pick
## of this harness, not a guess: it plays the gauntlet ladder over a bounded
## matrix of the tunables and prints the table.
##
##   nim c -r --path:src tools/tune_baselines.nim            # print the sweep
##   nim c -r --path:src tools/tune_baselines.nim --check    # assert the pick
##
## `tools/ci/baseline_tuning.json` records the winning cell and
## `tests/test_minigrid_driver.nim` asserts the shipped defaults still equal
## it, so a retuned baseline and its recorded sweep land in one commit.

import std/[json, os, strformat, strutils]
import minigrid/[sim, driver, baselines]

const SweepSeeds = 40

proc playOne(config: GameConfig, kind: Baseline,
             params: BaselineParams): int =
  ## ONE lane is what the sweep ranks: the lanes are isolated and identical by
  ## construction, so four of them would rank the same cell four times.
  var one = config
  one.numAgents = 1
  one.minPlayers = 1
  var sim = initSimServer(one)
  sim.phase = Playing
  var turns = 0
  while sim.phase == Playing and turns < 400:
    if sim.waitingForPlan():
      sim.beginTurn()
      if sim.phase != Playing:
        break
      inc turns
      for slot in 0 ..< sim.lanes.len:
        if sim.lanes[slot].laneResolved():
          continue
        let plan = scriptedPlan(sim.lanes[slot], sim.config, kind, params)
        let expansion = expandPlan(sim.lanes[slot].knownMap,
          sim.lanes[slot].agent.x, sim.lanes[slot].agent.y,
          sim.lanes[slot].agent.dir, plan.actions,
          sim.config.macroPrimitiveCap, sim.config.turnTicks)
        sim.installLanePlan(slot, expansion.primitives, expansion.truncated,
          plan.dropped + plan.overCap, expansion.unreachable)
    sim.stepTick()
    sim.pending.setLen(0)
  if sim.phase == Playing:
    sim.finish(erComplete, edAllLanesComplete)
  sim.score(0)

proc sweep(): JsonNode =
  var grid = newJArray()
  var best: JsonNode = nil
  var bestScore = -1
  for weight in [1, 2, 3, 4, 6, 8]:
    ## `spinTurns` is DESIGN-PINNED at the config's 24, not swept: it only
    ## fires when the whole reachable region is mapped and the target is not
    ## in it, which is a terminal state a sweep cannot rank.
    for spin in [24]:
      for byDistance in [true, false]:
        let params = BaselineParams(frontierAdjacencyWeight: weight,
                                    spinTurns: spin,
                                    tieBreakByDistance: byDistance)
        var total = 0
        for seed in 1 .. SweepSeeds:
          var config = defaultGameConfig()
          config.seed = seed
          total += playOne(config, blScout, params)
        let cell = %*{"frontierAdjacencyWeight": weight, "spinTurns": spin,
                      "tieBreakByDistance": byDistance, "score": total}
        grid.add(cell)
        if total > bestScore:
          bestScore = total
          best = cell
  %*{"seeds": SweepSeeds, "grid": grid, "pick": best}

when isMainModule:
  let table = sweep()
  if paramCount() >= 1 and paramStr(1) == "--check":
    let recorded = parseJson(readFile("tools/ci/baseline_tuning.json"))
    for key in ["frontierAdjacencyWeight", "spinTurns", "tieBreakByDistance"]:
      if table["pick"][key] != recorded["pick"][key]:
        quit(&"sweep pick {key} = {table[\"pick\"][key]} but " &
             &"tools/ci/baseline_tuning.json records {recorded[\"pick\"][key]}", 1)
    echo "baseline tuning matches the recorded sweep"
  else:
    echo pretty(table)

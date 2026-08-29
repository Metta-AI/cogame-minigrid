## Bounded orders / legality on the scripted baselines and the driver —
## design note §Tests items 17..23.

import std/[json, random, strutils, unicode, unittest]
import minigrid/[sim, driver, directives, baselines]
import minigrid/decide
import helpers

proc worldStates(count: int): seq[SimServer] =
  ## `count` pseudo-random world states: every family, both variants, varied
  ## known maps, carried and empty-handed, adjacent to lava and to obstacles.
  ## The states are poked into LANE 0; the other three lanes stay at their
  ## generated start, which is what the isolation checks below compare
  ## against.
  var rng = initRand(20260828)
  for i in 0 ..< count:
    let variant = if i mod 2 == 0: "gauntlet" else: "xland"
    var sim = initSimServer(testConfig(variant, 1 + rng.rand(9999)))
    sim.phase = Playing
    sim.startPhase(rng.rand(sim.config.taskCount - 1))
    randomKnownMap(sim.lanes[0], rng, 20 + rng.rand(75), sim.tickCount)
    if i mod 3 == 0:
      sim.lanes[0].agent.carrying =
        ObjectRef(kind: ckKey, colour: Colours[rng.rand(5)])
    sim.lanes[0].agent.dir = Dirs[rng.rand(3)]
    ## Put the agent next to something dangerous now and then.
    if i mod 5 == 0:
      let front = sim.lanes[0].agent.ahead()
      if inBounds(front.x, front.y) and front.x > 0 and front.y > 0 and
          front.x < GridSize - 1 and front.y < GridSize - 1:
        sim.lanes[0].task.grid.setAt(front.x, front.y, Cell(kind: ckLava))
        sim.lanes[0].knownMap.cells[idx(front.x, front.y)].seen = true
        sim.lanes[0].knownMap.cells[idx(front.x, front.y)].cell =
          Cell(kind: ckLava)
    if i mod 7 == 0:
      let front = sim.lanes[0].agent.ahead()
      if inBounds(front.x, front.y) and front.x > 0 and front.y > 0 and
          front.x < GridSize - 1 and front.y < GridSize - 1:
        sim.lanes[0].task.grid.setAt(front.x, front.y,
          Cell(kind: ckBall, colour: coGrey, obstacle: true))
        sim.lanes[0].knownMap.cells[idx(front.x, front.y)].seen = true
        sim.lanes[0].knownMap.cells[idx(front.x, front.y)].cell =
          Cell(kind: ckBall, colour: coGrey, obstacle: true)
    result.add(sim)

suite "minigrid driver and baselines":
  let states = worldStates(300)

  test "17. baselines are bounded":
    for sim in states:
      for kind in [blScout, blBumper]:
        let plan = scriptedPlan(sim.lanes[0], sim.config, kind)
        check plan.actions.len <= sim.config.maxActionsPerTurn
        check plan.actions.len <= 24
        for action in plan.actions:
          check action.kind in ActionKind.low .. ActionKind.high
          if action.kind == akGoto:
            check action.x in 0 ..< GridSize
            check action.y in 0 ..< GridSize
          if action.kind == akFace:
            check action.dir in Dirs
        ## A baseline that narrated would make the feed lie about which seats
        ## are LLMs.
        check plan.say.len == 0
        check plan.notes.len == 0
        let record = boundedDirectiveRecord(plan, 1, sim.taskIndex, 0, "Alpha",
          @[], false, 0, 0, nil)
        check record.len <= 1024

  test "18. baselines never suicide":
    for sim in states:
      for kind in [blScout, blBumper]:
        let plan = scriptedPlan(sim.lanes[0], sim.config, kind)
        let expansion = expandPlan(sim.lanes[0].knownMap,
          sim.lanes[0].agent.x, sim.lanes[0].agent.y, sim.lanes[0].agent.dir,
          plan.actions, sim.config.macroPrimitiveCap, sim.config.turnTicks)
        ## Walk the deterministic expansion against the KNOWN map and check it
        ## never steps onto a known lava cell or forwards into a known
        ## obstacle cell.
        var
          x = sim.lanes[0].agent.x
          y = sim.lanes[0].agent.y
          dir = sim.lanes[0].agent.dir
        for primitive in expansion.primitives:
          case primitive
          of pLeft: dir = Dir((ord(dir) + 3) mod 4)
          of pRight: dir = Dir((ord(dir) + 1) mod 4)
          of pForward:
            let
              nx = x + DirDx[dir]
              ny = y + DirDy[dir]
            let entry = sim.lanes[0].knownMap.known(nx, ny)
            if entry.seen:
              check entry.cell.kind != ckLava
              check not entry.cell.obstacle
              if entry.cell.passable():
                x = nx
                y = ny
          else: discard

  test "19. the driver never produces an illegal primitive":
    for sim in states:
      for kind in [blScout, blBumper]:
        let plan = scriptedPlan(sim.lanes[0], sim.config, kind)
        let expansion = expandPlan(sim.lanes[0].knownMap,
          sim.lanes[0].agent.x, sim.lanes[0].agent.y, sim.lanes[0].agent.dir,
          plan.actions, sim.config.macroPrimitiveCap, sim.config.turnTicks)
        check expansion.primitives.len <= sim.config.turnTicks
        for primitive in expansion.primitives:
          check primitive in Primitive.low .. Primitive.high
        ## A macro expands to at most macroPrimitiveCap primitives.
        for action in plan.actions:
          if action.kind != akGoto: continue
          let walk = gotoPrimitives(sim.lanes[0].knownMap,
            sim.lanes[0].agent.x, sim.lanes[0].agent.y,
            sim.lanes[0].agent.dir, action.x, action.y,
            sim.config.macroPrimitiveCap)
          check walk.primitives.len <= sim.config.macroPrimitiveCap
    ## An empty queue yields `wait`, never nothing — in every lane.
    var sim = initSimServer(testConfig())
    sim.phase = Playing
    sim.startPhase(0)
    sim.beginTurn()
    sim.stepTick()
    for slot in 0 ..< sim.lanes.len:
      check sim.lanes[slot].executed == @[pWait]

  test "20. the fallback IS the scout proc":
    ## The decision engine's fallback path and the `scout` baseline resolve to
    ## the same proc, so they cannot drift.
    for sim in states[0 ..< 40]:
      let viaBaseline = scriptedPlan(sim.lanes[0], sim.config, blScout)
      let viaFallback = scoutPlan(sim.lanes[0], sim.config)
      check viaBaseline.actions == viaFallback.actions
    check scoutFallback(states[0], 0, fcTransportTimeout).actions ==
      scoutPlan(states[0].lanes[0], states[0].config).actions
    check scoutFallback(states[0], 0, fcTransportTimeout).source == dsFallback
    check scoutFallback(states[0], 0, fcTransportTimeout).cause ==
      fcTransportTimeout
    ## The fallback is computed FOR THAT LANE: seat 2's fallback plans seat
    ## 2's board, never seat 0's.
    for slot in 0 ..< states[0].lanes.len:
      check scoutFallback(states[0], slot, fcRateGuard).actions ==
        scoutPlan(states[0].lanes[slot], states[0].config).actions

  test "21. reply validation":
    let cap = 24
    ## The schema is accepted.
    let good = parseDirective(parseJson("""
      {"actions":[{"do":"goto","x":6,"y":3},{"do":"toggle"},{"do":"forward"}],
       "say":"opening the door","notes":"the key was at (2,9)"}"""), cap)
    check good.actions.len == 3
    check good.actions[0].kind == akGoto
    check good.dropped == 0
    ## An invalid action is DROPPED, never rewritten.
    let dropped = parseDirective(parseJson("""
      {"actions":[{"do":"teleport"},{"do":"goto","x":"nope","y":3},
                  {"do":"face","dir":"up"},{"do":"forward"}]}"""), cap)
    check dropped.actions.len == 1
    check dropped.actions[0].kind == akForward
    check dropped.dropped == 3
    ## goto coordinates are CLAMPED into 0..12.
    let clamped = parseDirective(parseJson("""
      {"actions":[{"do":"goto","x":-9,"y":99}]}"""), cap)
    check clamped.actions[0].x == 0
    check clamped.actions[0].y == GridSize - 1
    ## `do` is lower-cased and `dir` case-folded.
    let folded = parseDirective(parseJson("""
      {"actions":[{"do":"FORWARD"},{"do":"Face","dir":"N"},
                  {"do":"face","dir":"South"}]}"""), cap)
    check folded.actions.len == 3
    check folded.actions[1].dir == dirNorth
    check folded.actions[2].dir == dirSouth
    ## A say-only reply is USABLE.
    let sayOnly = parseDirective(parseJson("""{"say":"thinking"}"""), cap)
    check sayOnly.actions.len == 0
    check sayOnly.say == "thinking"
    ## A non-object is a parse failure.
    expect DirectiveError:
      discard parseDirective(parseJson("""[1,2,3]"""), cap)
    ## actions are capped at maxActionsPerTurn (24) and the surplus counted.
    var many = "{\"actions\":["
    for i in 0 ..< 30:
      if i > 0: many.add(",")
      many.add("{\"do\":\"wait\"}")
    many.add("]}")
    let capped = parseDirective(parseJson(many), cap)
    check capped.actions.len == 24
    check capped.overCap == 6
    ## say/notes truncate on RUNE boundaries at 140/300, with 4-byte emoji
    ## sitting exactly on the boundary.
    var emoji = ""
    for i in 0 ..< 400:
      emoji.add("\xF0\x9F\xA7\xA9")           ## U+1F9E9, four bytes
    let runes = parseDirective(%*{"actions": [], "say": emoji,
                                  "notes": emoji}, cap)
    check runes.say.runeLen == MaxSayRunes
    check runes.notes.runeLen == MaxNoteRunes
    check runes.say.validateUtf8() == -1
    check runes.notes.validateUtf8() == -1
    check runes.say.len == MaxSayRunes * 4       ## whole codepoints only
    ## The tolerant extractor: fences and trailing prose.
    check extractJsonObject("```json\n{\"actions\":[]}\n```\nthat's my plan"
      ){"actions"}.len == 0
    ## truncated / dropped / unreachable are reported back accurately.
    var sim = initSimServer(testConfig())
    sim.phase = Playing
    sim.startPhase(0)
    var long: seq[Action]
    for i in 0 ..< 40:
      long.add(Action(kind: akForward))
    let expansion = expandPlan(sim.lanes[0].knownMap, sim.lanes[0].agent.x,
      sim.lanes[0].agent.y, sim.lanes[0].agent.dir, long, 40, 24)
    check expansion.primitives.len == 24
    check expansion.truncated
    let unreachable = expandPlan(sim.lanes[0].knownMap, sim.lanes[0].agent.x,
      sim.lanes[0].agent.y, sim.lanes[0].agent.dir,
      @[Action(kind: akGoto, x: 11, y: 11)], 40, 24)
    check unreachable.unreachable == 1
    check unreachable.primitives.len == 0

  test "22. the shipped baseline tuning is the swept pick":
    let swept = parseJson(readRepo("tools/ci/baseline_tuning.json"))
    let pick = swept["pick"]
    check DefaultBaselineParams.frontierAdjacencyWeight ==
      pick["frontierAdjacencyWeight"].getInt()
    check DefaultBaselineParams.spinTurns == pick["spinTurns"].getInt()
    check DefaultBaselineParams.tieBreakByDistance ==
      pick["tieBreakByDistance"].getBool()
    check swept["grid"].len >= 4

  test "23. scout beats bumper":
    ## The two controls are genuinely different controllers and neither is a
    ## zero.
    var scoutTotal = 0
    var bumperTotal = 0
    for seed in 1 .. 60:
      let scout = playScripted(testConfig("gauntlet", seed), blScout)
      let bumper = playScripted(testConfig("gauntlet", seed), blBumper)
      for slot in 0 ..< scout.lanes.len:
        scoutTotal += scout.tasksSolved(slot)
        bumperTotal += bumper.tasksSolved(slot)
        ## THE FAIRNESS PROOF: four lanes given the identical plan stream end
        ## with identical results, because the lane index is not a generator
        ## input.
        check scout.tasksSolved(slot) == scout.tasksSolved(0)
        check bumper.tasksSolved(slot) == bumper.tasksSolved(0)
    check scoutTotal > bumperTotal
    check bumperTotal >= 1

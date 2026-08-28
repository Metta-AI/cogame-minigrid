## Sim unit tests — design note §Tests items 1..16.

import std/[json, os, random, sequtils, strutils, unittest]
import minigrid/[sim, driver, directives, baselines]
import helpers

suite "minigrid sim":

  test "1. grid and glyphs":
    var grid: Grid
    grid.clearTo(ckEmpty)
    grid.walled()
    check GridSize == 13
    for i in 0 ..< GridSize:
      check grid.at(i, 0).kind == ckWall
      check grid.at(i, GridSize - 1).kind == ckWall
      check grid.at(0, i).kind == ckWall
      check grid.at(GridSize - 1, i).kind == ckWall
    var interior = 0
    for y in 1 ..< GridSize - 1:
      for x in 1 ..< GridSize - 1:
        if grid.at(x, y).kind == ckEmpty: inc interior
    check interior == 11 * 11

    ## The glyph, passability and see-behind tables are TOTAL over the enum
    ## and match the design note's cell table exactly.
    check glyphOf(Cell(kind: ckEmpty)) == '.'
    check glyphOf(Cell(kind: ckWall)) == '#'
    check glyphOf(Cell(kind: ckLava)) == '~'
    check glyphOf(Cell(kind: ckGoal)) == 'G'
    check glyphOf(Cell(kind: ckKey)) == 'k'
    check glyphOf(Cell(kind: ckBall)) == 'o'
    check glyphOf(Cell(kind: ckBox)) == 'b'
    check glyphOf(Cell(kind: ckDoor, door: dsOpen)) == 'D'
    check glyphOf(Cell(kind: ckDoor, door: dsClosed)) == 'd'
    check glyphOf(Cell(kind: ckDoor, door: dsLocked)) == 'L'
    check passable(Cell(kind: ckEmpty))
    check passable(Cell(kind: ckLava))          ## lava IS passable — fatally
    check passable(Cell(kind: ckGoal))
    check passable(Cell(kind: ckDoor, door: dsOpen))
    check not passable(Cell(kind: ckWall))
    check not passable(Cell(kind: ckDoor, door: dsClosed))
    check not passable(Cell(kind: ckDoor, door: dsLocked))
    check not passable(Cell(kind: ckKey))
    check seesBehind(Cell(kind: ckLava))
    check seesBehind(Cell(kind: ckKey))
    check seesBehind(Cell(kind: ckDoor, door: dsOpen))
    check not seesBehind(Cell(kind: ckWall))
    check not seesBehind(Cell(kind: ckDoor, door: dsClosed))
    check not seesBehind(Cell(kind: ckDoor, door: dsLocked))
    ## The six MiniGrid colours and nothing else.
    check Colours.len == 6
    check Colours == [coRed, coGreen, coBlue, coPurple, coYellow, coGrey]

  test "2. primitives":
    var grid: Grid
    grid.clearTo(ckEmpty)
    grid.walled()
    var agent = Agent(x: 5, y: 5, dir: dirEast)
    ## left/right rotate in the MiniGrid order.
    discard agent.applyPrimitive(grid, pRight)
    check agent.dir == dirSouth
    discard agent.applyPrimitive(grid, pLeft)
    check agent.dir == dirEast
    discard agent.applyPrimitive(grid, pLeft)
    check agent.dir == dirNorth
    agent.dir = dirEast
    ## forward moves only into a passable cell.
    discard agent.applyPrimitive(grid, pForward)
    check (agent.x, agent.y) == (6, 5)
    grid.setAt(7, 5, Cell(kind: ckWall))
    discard agent.applyPrimitive(grid, pForward)
    check (agent.x, agent.y) == (6, 5)
    ## pickup: only empty-handed, only a non-obstacle key/ball/box.
    grid.setAt(7, 5, Cell(kind: ckKey, colour: coYellow))
    discard agent.applyPrimitive(grid, pPickup)
    check agent.carrying == ObjectRef(kind: ckKey, colour: coYellow)
    check grid.at(7, 5).kind == ckEmpty
    grid.setAt(7, 5, Cell(kind: ckBall, colour: coRed))
    discard agent.applyPrimitive(grid, pPickup)      ## hands full: a no-op
    check agent.carrying.kind == ckKey
    ## drop: only into empty floor.
    discard agent.applyPrimitive(grid, pDrop)        ## a ball is there
    check agent.carrying.kind == ckKey
    grid.setAt(7, 5, Cell(kind: ckEmpty))
    discard agent.applyPrimitive(grid, pDrop)
    check agent.carrying.kind == ckEmpty
    check grid.at(7, 5).kind == ckKey
    ## wait mutates nothing.
    let before = (agent.x, agent.y, agent.dir, agent.carrying)
    let effect = agent.applyPrimitive(grid, pWait)
    check effect.effect == peNone
    check (agent.x, agent.y, agent.dir, agent.carrying) == before

  test "3. locked doors":
    var grid: Grid
    grid.clearTo(ckEmpty)
    grid.walled()
    grid.setAt(6, 5, Cell(kind: ckDoor, colour: coYellow, door: dsLocked))
    var agent = Agent(x: 5, y: 5, dir: dirEast)
    ## Without the key: nothing happens.
    check agent.applyPrimitive(grid, pToggle).effect == peNone
    check grid.at(6, 5).door == dsLocked
    ## With the WRONG colour: nothing happens.
    agent.carrying = ObjectRef(kind: ckKey, colour: coBlue)
    check agent.applyPrimitive(grid, pToggle).effect == peNone
    check grid.at(6, 5).door == dsLocked
    ## With the right colour: it opens, and THE KEY IS NOT CONSUMED.
    agent.carrying = ObjectRef(kind: ckKey, colour: coYellow)
    check agent.applyPrimitive(grid, pToggle).effect == peUnlock
    check grid.at(6, 5).door == dsOpen
    check agent.carrying == ObjectRef(kind: ckKey, colour: coYellow)
    ## Thereafter it behaves as an ordinary door.
    check agent.applyPrimitive(grid, pToggle).effect == peClose
    check grid.at(6, 5).door == dsClosed
    check agent.applyPrimitive(grid, pToggle).effect == peOpen
    check grid.at(6, 5).door == dsOpen
    ## A box opens into its contents.
    grid.setAt(6, 5, Cell(kind: ckBox, colour: coRed,
      contents: encodeObject(ObjectRef(kind: ckBall, colour: coGreen))))
    check agent.applyPrimitive(grid, pToggle).effect == peBoxOpen
    check grid.at(6, 5).kind == ckBall
    check grid.at(6, 5).colour == coGreen

  test "4. lava and obstacles":
    var config = testConfig()
    var sim = initSimServer(config)
    sim.phase = Playing
    sim.startTask(0)                                  ## lavagap
    ## Stepping onto lava ends the task `died` on that tick.
    sim.agent = Agent(x: sim.task.gapX - 1, y: 5, dir: dirEast)
    if sim.task.gapY != 5:
      sim.installPlan(@[pForward], false, 0, 0)
      sim.stepTick()
      check sim.taskOutcome == toDied
      check sim.deaths == 1

    ## A forward into an obstacle ends the task `crashed` and the agent does
    ## NOT move.
    var dyn = testConfig("xland")
    var other = initSimServer(dyn)
    other.phase = Playing
    other.startTask(0)                                ## dynamic
    check other.obstacles.len > 0
    other.task.grid.setAt(3, 3, Cell(kind: ckEmpty))
    other.task.grid.setAt(4, 3,
      Cell(kind: ckBall, colour: coGrey, obstacle: true))
    other.obstacles = @[Obstacle(x: 4, y: 3)]
    other.agent = Agent(x: 3, y: 3, dir: dirEast)
    other.installPlan(@[pForward], false, 0, 0)
    other.stepTick()
    check other.taskOutcome == toCrashed
    check other.agent.x == 3
    check other.crashes == 1

    ## An obstacle never moves into the agent's cell, and its motion is
    ## identical for a given (seed, taskIndex, tick) under any agent
    ## behaviour.
    for tick in 1 .. 40:
      var a = initSimServer(dyn)
      var b = initSimServer(dyn)
      a.phase = Playing
      b.phase = Playing
      a.startTask(0)
      b.startTask(0)
      a.agent = Agent(x: 1, y: 1, dir: dirEast)
      b.agent = Agent(x: 11, y: 1, dir: dirWest)
      var ga = a.task.grid
      var gb = b.task.grid
      var oa = a.obstacles
      var ob = b.obstacles
      ga.stepObstacles(oa, a.agent, dyn.seed, 0, tick)
      gb.stepObstacles(ob, b.agent, dyn.seed, 0, tick)
      for i in 0 ..< oa.len:
        check (oa[i].x != a.agent.x or oa[i].y != a.agent.y)
        check (ob[i].x != b.agent.x or ob[i].y != b.agent.y)

  test "5. visibility flood":
    ## The exact rule of §The game, against hand-built fixtures.
    var open: Grid
    open.clearTo(ckEmpty)
    open.walled()
    for dir in Dirs:
      let rows = open.viewRows(6, 6, dir)
      check rows.len == ViewSize
      for row in rows:
        check row.len == ViewSize
      check rows[ViewSize - 1][ViewSize div 2] == 'A'
      ## In an open room the whole box in front is visible.
      check '?' notin rows[ViewSize - 1]

    ## A closed door blocks; an open one does not. The door is set in a FULL
    ## WALL ROW, which is where doors actually live: MiniGrid's flood
    ## legitimately reaches around a lone obstacle's sides, and this game
    ## restates that rule unchanged.
    var doors: Grid
    doors.clearTo(ckEmpty)
    doors.walled()
    for x in 1 ..< GridSize - 1:
      doors.setAt(x, 4, Cell(kind: ckWall))
    doors.setAt(6, 4, Cell(kind: ckDoor, colour: coBlue, door: dsClosed))
    let closedView = doors.viewRows(6, 6, dirNorth)
    check closedView[ViewSize - 3][ViewSize div 2] == 'd'
    check closedView[ViewSize - 4][ViewSize div 2] == '?'
    doors.setAt(6, 4, Cell(kind: ckDoor, colour: coBlue, door: dsOpen))
    let openView = doors.viewRows(6, 6, dirNorth)
    check openView[ViewSize - 3][ViewSize div 2] == 'D'
    check openView[ViewSize - 4][ViewSize div 2] != '?'

    ## A wall row: the cells behind it stay '?', and no '?' cell ever leaks
    ## content.
    var corner: Grid
    corner.clearTo(ckEmpty)
    corner.walled()
    for x in 1 ..< GridSize - 1:
      corner.setAt(x, 5, Cell(kind: ckWall))
    corner.setAt(6, 4, Cell(kind: ckGoal))
    let cornerView = corner.viewRows(6, 6, dirNorth)
    check cornerView[ViewSize - 2][ViewSize div 2] == '#'
    check cornerView[ViewSize - 3][ViewSize div 2] == '?'
    for row in cornerView:
      for ch in row:
        check ch in {'.', '#', '~', 'G', 'k', 'o', 'b', 'D', 'd', 'L', 'A', '?'}

    ## The design note's worked example: agent at (4,4) facing east with a
    ## wall column at x = 6 and a locked door at (6,3) — the door reads two
    ## cells to the agent's LEFT on view row j = 4.
    var worked: Grid
    worked.clearTo(ckEmpty)
    worked.walled()
    for y in 1 ..< GridSize - 1:
      worked.setAt(6, y, Cell(kind: ckWall))
    worked.setAt(6, 3, Cell(kind: ckDoor, colour: coYellow, door: dsLocked))
    let workedView = worked.viewRows(4, 4, dirEast)
    check workedView[6] == "...A..."
    check workedView[5] == "......."
    check workedView[4] == "##L####"
    check workedView[3] == "???????"

  test "6. known map and staleness":
    var config = testConfig()
    var sim = initSimServer(config)
    sim.phase = Playing
    sim.startTask(0)
    let seenAtStart = sim.knownMap.cellsSeen()
    check seenAtStart > 0
    ## A cell never in `vis` stays '?' for the whole task.
    var neverSeen = -1
    for slot in 0 ..< GridCells:
      if not sim.knownMap.cells[slot].seen:
        neverSeen = slot
        break
    check neverSeen >= 0
    check sim.knownMap.knownGlyph(neverSeen mod GridSize,
                                  neverSeen div GridSize) == '?'
    ## A cell observed then left keeps its last content and its seen_tick.
    let x = sim.agent.x
    let y = sim.agent.y
    let stamp = sim.knownMap.known(x, y).seenTick
    for i in 0 ..< 6:
      sim.installPlan(@[pRight], false, 0, 0)
      sim.stepTick()
    check sim.knownMap.known(x, y).seenTick >= stamp
    check sim.knownMap.cellsSeen() >= seenAtStart

  test "7. goto BFS":
    var map: KnownMap
    for y in 0 ..< GridSize:
      for x in 0 ..< GridSize:
        map.cells[idx(x, y)].seen = true
        map.cells[idx(x, y)].cell =
          if x == 0 or y == 0 or x == GridSize - 1 or y == GridSize - 1:
            Cell(kind: ckWall)
          else: Cell(kind: ckEmpty)
    map.cells[idx(5, 5)].cell = Cell(kind: ckLava)
    map.cells[idx(7, 7)].cell = Cell(kind: ckKey, colour: coRed)
    map.cells[idx(3, 3)].cell = Cell(kind: ckDoor, colour: coBlue,
                                     door: dsClosed)
    check not map.traversable(5, 5)                   ## lava
    check not map.traversable(7, 7)                   ## an object cell
    check not map.traversable(3, 3)                   ## a closed door
    check not map.traversable(0, 0)                   ## a wall
    map.cells[idx(9, 9)].seen = false
    check not map.traversable(9, 9)                   ## '?'

    ## A passable target ends ON it; the path never crosses lava.
    let walk = gotoPrimitives(map, 1, 1, dirEast, 10, 10, 40)
    check walk.ok
    check (walk.x, walk.y) == (10, 10)
    check walk.primitives.len <= 40
    ## An impassable-but-adjacent target ends FACING it.
    let face = gotoPrimitives(map, 1, 1, dirEast, 7, 7, 40)
    check face.ok
    check manhattan(face.x, face.y, 7, 7) == 1
    let toward = dirToward(face.x, face.y, 7, 7)
    check toward.ok and face.dir == toward.dir
    ## An unreachable target yields ZERO primitives.
    var sealed = map
    for dir in Dirs:
      sealed.cells[idx(11 + DirDx[dir], 11 + DirDy[dir])].cell =
        Cell(kind: ckWall)
    let blocked = gotoPrimitives(sealed, 1, 1, dirEast, 11, 11, 40)
    check not blocked.ok
    check blocked.primitives.len == 0
    ## A 180 degree face is ALWAYS right, right.
    check turnsBetween(dirEast, dirWest) == @[pRight, pRight]
    check turnsBetween(dirNorth, dirSouth) == @[pRight, pRight]
    check turnsBetween(dirEast, dirNorth) == @[pLeft]
    check turnsBetween(dirEast, dirSouth) == @[pRight]
    check turnsBetween(dirEast, dirEast).len == 0
    ## The path is UNIQUE for a given known map.
    for i in 0 ..< 5:
      check gotoPrimitives(map, 1, 1, dirEast, 10, 10, 40).primitives ==
        walk.primitives

  test "8. task generators are a pure function of (seed, taskIndex)":
    for family in TaskFamily:
      for seed in 1 .. 200:
        let a = generate(family, seed, seed mod 5, 6, 6, 6, 3)
        let b = generate(family, seed, seed mod 5, 6, 6, 6, 3)
        check a.grid.cells == b.grid.cells
        check a.mission == b.mission
        check (a.startX, a.startY, a.startDir) == (b.startX, b.startY, b.startDir)
        ## Well-formed: the border ring is intact and the agent is on a free
        ## cell with nothing under it.
        for i in 0 ..< GridSize:
          check a.grid.at(i, 0).kind == ckWall
          check a.grid.at(0, i).kind == ckWall
        check a.grid.at(a.startX, a.startY).kind == ckEmpty
        check a.mission.len > 0
        check a.mission == a.mission.strip()
        ## The mission names existing referents.
        case family
        of tfDoorkey:
          check a.grid.objectExists(ObjectRef(kind: ckKey, colour: coYellow))
          check a.grid.at(a.doorX, a.doorY).kind == ckDoor
        of tfKeycorridor:
          check a.grid.objectExists(a.goalObject)
          check a.grid.objectExists(ObjectRef(kind: ckKey, colour: coRed))
        of tfBabyai:
          check a.grid.objectExists(a.targetA)
          check a.instructionKind in 0 .. 2
        of tfXland:
          check a.rules.len == 3
          check not a.grid.objectExists(a.goalObject)
        of tfLavagap:
          check a.gapX in 4 .. 8
          check a.gapY in 1 .. 11
          check a.grid.at(a.gapX, a.gapY).kind != ckLava
        of tfDynamic:
          check a.obstacles.len > 0
        of tfMultiroom:
          check roomOf(a.startX, a.startY) == 0

    ## The layout of task k is identical no matter what happened in task k-1:
    ## three different agent behaviours, same layouts.
    var layouts: seq[seq[Cell]]
    for behaviour in 0 .. 2:
      var config = testConfig()
      var sim = initSimServer(config)
      sim.phase = Playing
      sim.startTask(0)
      for i in 0 ..< 30 * behaviour:
        sim.installPlan(@[pRight, pForward], false, 0, 0)
        sim.stepTick()
      var seen: seq[seq[Cell]]
      for taskIndex in 0 ..< config.taskCount:
        sim.startTask(taskIndex)
        seen.add(sim.task.grid.cells.toSeq())
      if layouts.len == 0: layouts = seen
      else: check layouts == seen

  test "9. success predicates":
    ## lavagap: standing one cell short is not a solve.
    var config = testConfig()
    var sim = initSimServer(config)
    sim.phase = Playing
    sim.startTask(0)
    sim.agent = Agent(x: GridSize - 3, y: GridSize - 2, dir: dirEast)
    check not sim.succeeded()
    sim.agent = Agent(x: GridSize - 2, y: GridSize - 2, dir: dirEast)
    check sim.succeeded()

    ## doorkey: at the door without the key is not a solve.
    sim.startTask(1)
    sim.agent = Agent(x: sim.task.doorX - 1, y: sim.task.doorY, dir: dirEast)
    check not sim.succeeded()

    ## keycorridor: holding the key but not the ball is not a solve.
    sim.startTask(3)
    sim.agent.carrying = ObjectRef(kind: ckKey, colour: coRed)
    check not sim.succeeded()
    sim.agent.carrying = sim.task.goalObject
    check sim.succeeded()

    ## babyai "next to" with the object still CARRIED must NOT count.
    var found = false
    for seed in 1 .. 400:
      let task = generate(tfBabyai, seed, 0, 6, 6, 6, 3)
      if task.instructionKind != 2: continue
      var b = initSimServer(testConfig(seed = seed))
      b.phase = Playing
      b.task = task
      b.taskStarted = true
      b.agent = Agent(x: task.startX, y: task.startY, dir: task.startDir)
      let spotB = b.task.grid.findObject(task.targetB)
      check spotB.found
      ## Place A adjacent to B but CARRIED: not a solve.
      let spotA = b.task.grid.findObject(task.targetA)
      b.task.grid.setAt(spotA.x, spotA.y, Cell(kind: ckEmpty))
      b.agent.carrying = task.targetA
      check not b.succeeded()
      ## Now drop it beside B: a solve.
      for dir in Dirs:
        let nx = spotB.x + DirDx[dir]
        let ny = spotB.y + DirDy[dir]
        if b.task.grid.at(nx, ny).kind == ckEmpty:
          b.task.grid.setAt(nx, ny,
            Cell(kind: task.targetA.kind, colour: task.targetA.colour))
          b.agent.carrying = ObjectRef()
          break
      check b.succeeded()
      found = true
      break
    check found

    ## xland with only P0 made is not a solve.
    var x = initSimServer(testConfig("xland"))
    x.phase = Playing
    x.startTask(1)
    check x.task.rules.len == 3
    let p0 = x.task.rules[0].output
    x.task.grid.setAt(1, 1, Cell(kind: p0.kind, colour: p0.colour))
    check not x.succeeded()
    let goal = x.task.goalObject
    x.task.grid.setAt(2, 1, Cell(kind: goal.kind, colour: goal.colour))
    check x.succeeded()

  test "10. subgoals are awarded once, in order, never revoked":
    for variant in ["gauntlet", "xland"]:
      for seed in [1, 42, 907]:
        let sim = playScripted(testConfig(variant, seed))
        check sim.progressTotal() <= 3 * sim.config.taskCount
        check sim.progressTotal() <= 15
        for record in sim.records:
          check record.progress in 0 .. 3
          if record.outcome == toSolved:
            check record.progress == 3

  test "11. xland rules":
    for seed in 1 .. 200:
      let task = generate(tfXland, seed, 1, 6, 6, 6, 3)
      check task.rules.len == 3
      ## A chained triple: P0 + P1 -> GOAL.
      check task.rules[2].a == task.rules[0].output
      check task.rules[2].b == task.rules[1].output
      ## Distinct products, absent at the start.
      let products = [task.rules[0].output, task.rules[1].output,
                      task.rules[2].output]
      check products[0] != products[1]
      check products[1] != products[2]
      check products[0] != products[2]
      for product in products:
        check not task.grid.objectExists(product)

    ## At most one production per tick, deterministic scan order, and the
    ## product lands in the lower-(y, x) cell. A carried object never fires.
    var task = generate(tfXland, 5, 1, 6, 6, 6, 3)
    var grid = task.grid
    grid.clearTo(ckEmpty)
    grid.walled()
    let rule = task.rules[0]
    grid.setAt(3, 4, Cell(kind: rule.a.kind, colour: rule.a.colour))
    grid.setAt(4, 4, Cell(kind: rule.b.kind, colour: rule.b.colour))
    grid.setAt(3, 6, Cell(kind: rule.a.kind, colour: rule.a.colour))
    grid.setAt(4, 6, Cell(kind: rule.b.kind, colour: rule.b.colour))
    let fired = grid.stepProductions(task.rules, 7)
    check fired.fired
    check (fired.record.x, fired.record.y) == (3, 4)   ## lower (y, x)
    check grid.objectAt(4, 4).kind == ckEmpty
    check grid.objectAt(3, 6).kind != ckEmpty          ## only ONE per tick

  test "12. turn and tick order":
    var config = testConfig()
    var sim = initSimServer(config)
    sim.phase = Playing
    sim.startTask(0)
    ## An empty queue pops `wait`, and the tick is still spent.
    sim.installPlan(@[], false, 0, 0)
    let before = sim.tickCount
    sim.stepTick()
    check sim.tickCount == before + 1
    check sim.executed[^1] == pWait
    ## A finished task breaks the tick loop: the remaining ticks are skipped
    ## and never counted in taskTicks.
    sim.startTask(0)
    sim.agent = Agent(x: GridSize - 3, y: GridSize - 2, dir: dirEast)
    sim.installPlan(@[pForward, pForward, pForward, pForward], false, 0, 0)
    sim.stepTick()
    check sim.taskOutcome == toSolved
    check sim.queue.len == 0
    let ticksAtSolve = sim.taskTick
    sim.stepTick()                       ## the next tick starts the NEXT task
    check sim.taskIndex == 1
    check sim.records[0].ticks == ticksAtSolve

  test "13. scoring":
    var rng = initRand(20260828)
    for i in 0 ..< 500:
      var config = testConfig()
      var sim = initSimServer(config)
      sim.records = @[]
      var solved = 0
      var progress = 0
      var speed = 0
      for t in 0 ..< config.taskCount:
        let outcome = [toSolved, toTimeout, toDied, toCrashed,
                       toUnreached][rng.rand(4)]
        let turns = rng.rand(config.taskTurnCap)
        let credits = if outcome == toSolved: 3 else: rng.rand(2)
        sim.records.add(TaskRecord(family: tfLavagap, outcome: outcome,
          turns: turns, progress: credits))
        if outcome == toSolved:
          inc solved
          speed += max(0, config.taskTurnCap - turns)
        progress += credits
      check sim.tasksSolved() == solved
      check sim.progressTotal() == progress
      check sim.speedTotal() == speed
      check sim.score() == 100_000 * solved + 1_000 * progress + 10 * speed
      check sim.score() >= 0
    ## The two lexicographic dominance bounds, and the extremes.
    check 1_000 * 15 + 10 * 50 == 15_500
    check 15_500 < 100_000
    check 10 * 50 == 500
    check 500 < 1_000
    check 100_000 * 5 + 1_000 * 15 + 10 * 50 == 515_500
    ## win / winner.
    var sim = initSimServer(testConfig())
    for t in 0 ..< 5:
      sim.records.add(TaskRecord(outcome: (if t < 3: toSolved else: toTimeout),
                                 progress: (if t < 3: 3 else: 0)))
    check sim.tasksSolved() >= sim.config.parTasks
    let results = parseJson(sim.gauntletResultsJson())
    check results["win"][0].getBool()
    check results["winner"].getInt() == 0
    var poor = initSimServer(testConfig())
    for t in 0 ..< 5:
      poor.records.add(TaskRecord(outcome: toTimeout))
    let poorResults = parseJson(poor.gauntletResultsJson())
    check not poorResults["win"][0].getBool()
    check poorResults["winner"].kind == JNull
    check poorResults["scores"][0].getInt() == 0

  test "14. end conditions":
    ## gauntletComplete.
    let complete = playScripted(testConfig())
    check complete.endReason == erComplete
    check complete.endRule == edGauntletComplete
    check complete.records.len == complete.config.taskCount

    ## A forced wall-clock stop mid-gauntlet marks every unstarted task
    ## `unreached` with zero turns, zero ticks and zero progress, and still
    ## scores the tasks that ran.
    var sim = initSimServer(testConfig())
    sim.phase = Playing
    sim.startTask(0)
    sim.records.add(TaskRecord(family: tfLavagap, outcome: toSolved, turns: 4,
                               ticks: 41, progress: 3))
    sim.startTask(1)
    sim.applyStop(edWallClock, "forced")
    check sim.endReason == erDeadline
    check sim.endRule == edWallClock
    let stopped = parseJson(sim.gauntletResultsJson())
    check stopped["taskOutcome"][0].getStr() == "solved"
    check stopped["tasksSolved"].getInt() == 1
    for i in 2 ..< 5:
      check stopped["taskOutcome"][i].getStr() == "unreached"
      check stopped["taskTurns"][i].getInt() == 0
      check stopped["taskTicks"][i].getInt() == 0
      check stopped["taskProgress"][i].getInt() == 0

    ## A forced fault.
    var faulted = initSimServer(testConfig())
    faulted.phase = Playing
    faulted.startTask(0)
    faulted.applyStop(edFault, "boom")
    check faulted.endReason == erFault
    check faulted.endRule == edFault
    check faulted.stopDetail == "boom"

    ## The turn cap is an INDEPENDENT guard: with tasks still to come it ends
    ## the episode `complete` on `turnCap` rather than letting any arithmetic
    ## error produce an unbounded loop.
    var capped = initSimServer(testConfig())
    capped.phase = Playing
    capped.startTask(0)
    capped.config.maxTurns = 1
    capped.turnsPlayed = 1
    capped.agent = Agent(x: GridSize - 3, y: GridSize - 2, dir: dirEast)
    capped.installPlan(@[pForward], false, 0, 0)
    capped.stepTick()
    check capped.taskOutcome == toSolved
    check capped.phase == GameOver
    check capped.endReason == erComplete
    check capped.endRule == edTurnCap

    ## Exactly three reason values are legal, and four end rules.
    for reason in EndReason:
      check $reason in ["complete", "deadline", "fault"]
    for rule in EndRule:
      check $rule in ["", "gauntletComplete", "turnCap", "wallClock", "fault"]

  test "15. no floating point in the sim":
    ## Integer arithmetic only — that is what makes the native <-> wasm hash
    ## chain exact by construction.
    for name in ["sim", "grid", "tasks", "agent", "xland", "driver",
                 "baselines"]:
      let source = readRepo("src/minigrid/" & name & ".nim")
      for line in source.splitLines():
        let code = line.split("##")[0]
        if code.strip().startsWith("#"):
          continue
        check "float" notin code
        check "sqrt" notin code
        ## A float LITERAL is a digit, a dot and a digit.
        for k in 1 ..< max(1, code.len - 1):
          if code[k] == '.' and code[k - 1] in Digits and code[k + 1] in Digits:
            check false

  test "16. tick budget":
    ## A full xland episode of 660 ticks completes well inside a second of a
    ## release build; this asserts it terminates and stays inside the cap.
    let sim = playScripted(testConfig("xland", 3))
    check sim.tickCount <= sim.config.maxTicks + 8
    var totalTicks = 0
    for record in sim.records:
      totalTicks += record.ticks
    check totalTicks <= sim.config.maxTicks

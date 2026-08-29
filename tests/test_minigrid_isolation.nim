## Lane isolation, synchronised phases and the observation bound — addendum v2
## §Tests items 46, 47, 48 and 58.
##
## THE INVARIANT, TESTED: lane `s` is a complete PRIVATE instance of the SAME
## seeded five-phase gauntlet. Every generator draw is `mix64(seed, taskIndex,
## salt)` and the lane index is deliberately NOT an input, so all four lanes
## get byte-identical layouts, missions and rule tables — same challenge, so
## `scores[i]` compare directly and a head-to-head episode is a fair race.

import std/[json, strutils, unittest]
import minigrid/[sim, driver, baselines]
import helpers

proc laneSnapshot(lane: Lane): string =
  ## Every bit of one lane's per-tick state that could possibly differ.
  result = $lane.agent.x & "," & $lane.agent.y & "," & $ord(lane.agent.dir) &
    "," & $ord(lane.agent.carrying.kind) & "," &
    $ord(lane.agent.carrying.colour) & "|" & $lane.taskTick & "," &
    $lane.taskTurns & "," & $ord(lane.taskOutcome) & "|"
  for cell in lane.task.grid.cells:
    result.add($ord(cell.kind) & $ord(cell.colour) & $ord(cell.door) &
      (if cell.obstacle: "o" else: "."))
  result.add("|")
  for entry in lane.knownMap.cells:
    result.add(if entry.seen: "1" else: "0")
  result.add("|")
  for obstacle in lane.obstacles:
    result.add($obstacle.x & "." & $obstacle.y & ";")
  for earned in lane.subgoals:
    result.add(if earned: "1" else: "0")
  result.add("|" & $lane.laneTicks & "," & $lane.primitivesExecuted)

proc plansFor(seed, slot: int): seq[seq[Primitive]] =
  ## A deterministic, lane-specific plan stream: seat `slot` gets a stream
  ## nothing else in the episode shares.
  for turn in 0 ..< 30:
    var plan: seq[Primitive]
    for i in 0 ..< 24:
      plan.add([pForward, pRight, pLeft, pToggle, pPickup, pWait][
        (seed + slot * 7 + turn * 3 + i) mod 6])
    result.add(plan)

proc runWithPlans(config: GameConfig,
                  streams: seq[seq[seq[Primitive]]]): SimServer =
  ## Drives every lane from its OWN recorded plan stream, the way the server's
  ## turn boundary does.
  result = initSimServer(config)
  result.phase = Playing
  var turn = 0
  while result.phase == Playing and turn < config.maxTurns:
    result.beginTurn()
    if result.phase != Playing:
      break
    for slot in 0 ..< result.lanes.len:
      if result.lanes[slot].laneResolved():
        continue
      let stream = streams[slot mod streams.len]
      result.installLanePlan(slot, stream[turn mod stream.len], false, 0, 0)
    for tick in 0 ..< config.turnTicks:
      result.stepTick()
      result.pending.setLen(0)
      if result.phase != Playing or result.waitingForPlan():
        break
    inc turn
  if result.phase == Playing:
    result.finish(erComplete, edAllLanesComplete)

suite "minigrid lane isolation":

  test "46. replacing one lane's whole plan stream leaves the others bit-identical":
    ## `stepLane` takes no `SimServer`, reads no other lane and writes no other
    ## lane, so lane i's state evolves as a pure function of ITS OWN plans.
    ##
    ## DOCUMENTED SCOPE. Phase boundaries are SHARED (§Synchronised phases): a
    ## phase ends when EVERY lane has resolved it, so when a rival resolves
    ## does move the shared boundary, and therefore the turn on which the next
    ## phase starts. The per-tick comparison below is over the phase both runs
    ## are still playing — inside it, nothing a rival does moves a single bit
    ## of lane i.
    for seed in [1, 42, 907]:
      var config = testConfig("gauntlet", seed)
      var base: seq[seq[seq[Primitive]]]
      for slot in 0 ..< LaneCount:
        base.add(plansFor(seed, slot))

      proc walk(streams: seq[seq[seq[Primitive]]]): seq[seq[string]] =
        ## Per-lane snapshots, one per tick, for phase 1 only.
        result = @[@[], @[], @[], @[]]
        var sim = initSimServer(config)
        sim.phase = Playing
        var turn = 0
        while sim.phase == Playing and turn < config.maxTurns:
          sim.beginTurn()
          if sim.phase != Playing or sim.taskIndex != 0:
            break
          for slot in 0 ..< sim.lanes.len:
            if sim.lanes[slot].laneResolved(): continue
            sim.installLanePlan(slot, streams[slot][turn], false, 0, 0)
          for tick in 0 ..< config.turnTicks:
            sim.stepTick()
            sim.pending.setLen(0)
            for slot in 0 ..< sim.lanes.len:
              result[slot].add(laneSnapshot(sim.lanes[slot]))
            if sim.phase != Playing or sim.waitingForPlan(): break
          inc turn

      let reference = walk(base)
      for replacement in 0 .. 1:
        var altered = base
        altered[1] = @[]
        for t in 0 ..< 30:
          var plan: seq[Primitive]
          for i in 0 ..< 24:
            plan.add(if replacement == 0: pWait
                     else: [pRight, pForward][(t + i) mod 2])
          altered[1].add(plan)
        let other = walk(altered)
        for slot in [0, 2, 3]:
          let shared = min(reference[slot].len, other[slot].len)
          check shared > 0
          for i in 0 ..< shared:
            check reference[slot][i] == other[slot][i]

  test "46b. a lane run ALONE reproduces its four-lane trajectory exactly":
    ## `stepLane` is a pure function of one lane's own state and that lane's
    ## own primitive, so ONE lane driven by a plan stream walks the identical
    ## path whether or not three other lanes are running beside it. The
    ## control gives all four lanes the SAME stream, which is what makes the
    ## shared phase schedule identical to the one-lane schedule and the
    ## comparison exact for the WHOLE episode.
    let seed = 77
    var config = testConfig("gauntlet", seed)
    let stream = plansFor(seed, 0)
    let four = runWithPlans(config, @[stream])
    var one = config
    one.numAgents = 1
    one.minPlayers = 1
    let alone = runWithPlans(one, @[stream])
    check alone.lanes.len == 1
    check laneSnapshot(alone.lanes[0]) == laneSnapshot(four.lanes[0])
    check alone.lanes[0].laneTicks == four.lanes[0].laneTicks
    check alone.tasksSolved(0) == four.tasksSolved(0)
    check alone.score(0) == four.score(0)
    check alone.turnsPlayed == four.turnsPlayed
    for i in 0 ..< config.taskCount:
      check alone.lanes[0].records[i].ticks == four.lanes[0].records[i].ticks
      check alone.lanes[0].records[i].turns == four.lanes[0].records[i].turns
      check alone.lanes[0].records[i].outcome ==
        four.lanes[0].records[i].outcome

  test "46c. the observation for seat i reads ONLY lane i":
    var sim = initSimServer(testConfig())
    sim.phase = Playing
    sim.startPhase(0)
    ## Wreck every other lane; seat 0's observation may not move a byte.
    let before = $sim.observationJson(0, includeNotes = true)
    for slot in 1 ..< sim.lanes.len:
      sim.lanes[slot].agent = Agent(x: 1, y: 1, dir: dirWest)
      sim.lanes[slot].task.grid.clearTo(ckLava)
      sim.lanes[slot].knownMap = KnownMap()
      sim.lanes[slot].taskOutcome = toDied
      sim.lanes[slot].records.add(TaskRecord(outcome: toSolved, progress: 3))
    check $sim.observationJson(0, includeNotes = true) == before
    ## And the schema carries NO rival field: no alias, score or progress of
    ## any other lane appears anywhere in it.
    let text = $sim.observationJson(2, includeNotes = true)
    for rival in ["Alpha", "Beta", "Delta", "rivals", "opponent", "scores",
                  "leader", "standings"]:
      check rival notin text
    check "\"you\":\"Gamma\"" in text.replace(" ", "")
    check "\"lane\":2" in text.replace(" ", "")

  test "47. same seed, same layout, in every lane":
    for variant in ["gauntlet", "xland"]:
      for seed in 1 .. 200:
        var sim = initSimServer(testConfig(variant, seed))
        sim.phase = Playing
        for phase in 0 ..< sim.config.taskCount:
          sim.startPhase(phase)
          for slot in 1 ..< sim.lanes.len:
            check sim.lanes[slot].task.grid.cells == sim.lanes[0].task.grid.cells
            check sim.lanes[slot].task.mission == sim.lanes[0].task.mission
            check sim.lanes[slot].task.rules == sim.lanes[0].task.rules
            check sim.lanes[slot].task.startX == sim.lanes[0].task.startX
            check sim.lanes[slot].task.startY == sim.lanes[0].task.startY
            check sim.lanes[slot].task.startDir == sim.lanes[0].task.startDir
            check sim.lanes[slot].task.subgoalNames ==
              sim.lanes[0].task.subgoalNames

  test "47b. four lanes given the IDENTICAL plan stream end identically":
    for seed in [3, 42, 1234]:
      var streams: seq[seq[seq[Primitive]]]
      streams.add(plansFor(seed, 0))
      let sim = runWithPlans(testConfig("gauntlet", seed), streams)
      for slot in 1 ..< sim.lanes.len:
        check sim.tasksSolved(slot) == sim.tasksSolved(0)
        check sim.progressTotal(slot) == sim.progressTotal(0)
        check sim.lanes[slot].laneTicks == sim.lanes[0].laneTicks
        for i in 0 ..< sim.config.taskCount:
          check sim.lanes[slot].records[i].progress ==
            sim.lanes[0].records[i].progress
          check sim.lanes[slot].records[i].ticks == sim.lanes[0].records[i].ticks

  test "48. phases are SYNCHRONISED across all four lanes":
    let sim = playScripted(testConfig("gauntlet", 42),
      kinds = @[blScout, blBumper, blScout, blBumper])
    ## Sum of the phase turns is the turns played, and no phase ran past the
    ## cap in any lane.
    var total = 0
    for i in 0 ..< sim.config.taskCount:
      var phaseTurns = 0
      for slot in 0 ..< sim.lanes.len:
        phaseTurns = max(phaseTurns, sim.lanes[slot].records[i].turns)
      total += phaseTurns
      check phaseTurns <= sim.config.taskTurnCap
      for slot in 0 ..< sim.lanes.len:
        check sim.lanes[slot].records[i].turns <= phaseTurns
    check total == sim.turnsPlayed

    ## Every lane starts every phase on the SAME turn, and a lane that
    ## resolves early is excluded from the batch (it consumes no LLM call) and
    ## takes no further tick until the boundary.
    var live = initSimServer(testConfig("gauntlet", 42))
    live.phase = Playing
    var seenPhases: seq[int]
    var turn = 0
    while live.phase == Playing and turn < live.config.maxTurns:
      live.beginTurn()
      if live.phase != Playing: break
      inc turn
      if live.taskIndex notin seenPhases:
        seenPhases.add(live.taskIndex)
        ## a phase starts in EVERY lane at once, with every lane on turn 1
        for slot in 0 ..< live.lanes.len:
          check live.lanes[slot].taskIndex == live.taskIndex
          check live.lanes[slot].taskTurns == 1
      let active = live.activeSeats()
      for slot in 0 ..< live.lanes.len:
        check (slot in active) == (not live.lanes[slot].laneResolved())
      ## resolve lane 0 immediately, and check it stops stepping
      if live.taskIndex == 0 and turn == 1:
        live.lanes[0].taskOutcome = toSolved
        let frozen = live.lanes[0].taskTick
        for i in 0 ..< 5:
          live.stepTick()
          live.pending.setLen(0)
        check live.lanes[0].taskTick == frozen
        check 0 notin live.activeSeats()
      for slot in live.activeSeats():
        let plan = scoutPlan(live.lanes[slot], live.config)
        let expansion = expandPlan(live.lanes[slot].knownMap,
          live.lanes[slot].agent.x, live.lanes[slot].agent.y,
          live.lanes[slot].agent.dir, plan.actions,
          live.config.macroPrimitiveCap, live.config.turnTicks)
        live.installLanePlan(slot, expansion.primitives, expansion.truncated,
          0, expansion.unreachable)
      for tick in 0 ..< live.config.turnTicks:
        live.stepTick()
        live.pending.setLen(0)
        if live.phase != Playing or live.waitingForPlan(): break
    check seenPhases.len >= 2

  test "58. the observation is bounded on a worst-case board":
    ## A fully explored board with twelve objects and twelve productions: the
    ## whole observation JSON stays inside the 4000-character cap, `objects`
    ## inside 24 entries and `productions` inside 12 — and `view` and `known`
    ## are NEVER truncated, because they are the game.
    var sim = initSimServer(testConfig("xland", 5))
    sim.phase = Playing
    sim.startPhase(1)
    for slot in 0 ..< sim.lanes.len:
      ## reveal everything, then bury the board in objects
      var colour = 0
      for cell in 0 ..< GridCells:
        let x = cell mod GridSize
        let y = cell div GridSize
        if x > 0 and y > 0 and x < GridSize - 1 and y < GridSize - 1:
          sim.lanes[slot].task.grid.setAt(x, y, Cell(
            kind: [ckKey, ckBall, ckBox, ckDoor][(x + y) mod 4],
            colour: Colours[colour mod Colours.len],
            door: dsClosed))
          inc colour
        sim.lanes[slot].knownMap.cells[cell].seen = true
        sim.lanes[slot].knownMap.cells[cell].cell =
          sim.lanes[slot].task.grid.cells[cell]
        sim.lanes[slot].knownMap.cells[cell].seenTick = cell
      for i in 0 ..< 40:
        sim.lanes[slot].productions.add(Production(
          a: ObjectRef(kind: ckKey, colour: coRed),
          b: ObjectRef(kind: ckBall, colour: coBlue),
          output: ObjectRef(kind: ckBox, colour: coPurple),
          x: i mod 13, y: i mod 13, tick: i))
      sim.lanes[slot].notes = repeat("n", 300)
      for i in 0 ..< 24:
        sim.lanes[slot].executed.add(pForward)
    for slot in 0 ..< sim.lanes.len:
      let observation = sim.observationJson(slot, includeNotes = true)
      let text = $observation
      check text.len <= MaxObservationChars
      check observation["objects"].len <= MaxObservationObjects
      check observation["productions"].len <= MaxObservationProductions
      ## view and known survive whole.
      check observation["view"].len == ViewSize
      check observation["known"].len == GridSize
      for row in observation["known"]:
        check row.getStr().len == GridSize
      for row in observation["view"]:
        check row.getStr().len == ViewSize
      ## the entries kept are the MOST RECENTLY SEEN ones, in (y, x) order
      var previous = -1
      for item in observation["objects"]:
        let slotIndex = item["y"].getInt() * GridSize + item["x"].getInt()
        check slotIndex > previous
        previous = slotIndex

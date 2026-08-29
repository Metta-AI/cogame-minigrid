## The simulation: FOUR ISOLATED LANES of the step loop of the design note,
## `gameHash`, phase and episode end evaluation, per-lane scoring, and each
## seat's lane-local observation builder.
##
## THE WHOLE PHYSICS OF THE GAME IS `stepLane` AND NOTHING ELSE MUTATES A
## LANE. `stepLane` is a PURE FUNCTION OF ONE LANE'S OWN STATE AND THAT LANE'S
## OWN PRIMITIVE: it takes no `SimServer`, reads no other lane and writes no
## other lane, which is the whole of the isolation guarantee
## (`tests/test_minigrid_isolation.nim`). Every generator draw is
## `mix64(seed, taskIndex, salt)` and THE LANE INDEX IS DELIBERATELY NOT AN
## INPUT, so all four lanes get byte-identical layouts, missions and rule
## tables — same challenge, so `scores[i]` compare directly.
##
## All arithmetic is integer only — cell coordinates, directions, tick
## counters, BFS distances, subgoal counters, scores. There is no floating
## point anywhere in this module, which is what makes the native <-> wasm hash
## chain exact by construction (and `tests/test_minigrid_sim.nim` greps for
## it).

import std/[json, strutils, algorithm]
import sim_types, sim_config, grid, tasks, agent, xland

type
  EventKind* = enum
    ## The closed enum of derived broadcast events. `tests/test_minigrid_events.nim`
    ## asserts the emitted set equals exactly this list. Every LANE-SPECIFIC
    ## kind carries a `slot`; `taskstart`, `turn`, `budget` and `end` are
    ## episode-wide and carry none.
    evTaskStart = "taskstart"
    evTurn = "turn"
    evPlan = "plan"
    evSay = "say"
    evFallback = "fallback"
    evPickup = "pickup"
    evDrop = "drop"
    evOpen = "open"
    evClose = "close"
    evUnlock = "unlock"
    evProduce = "produce"
    evSubgoal = "subgoal"
    evLava = "lava"
    evCrash = "crash"
    evSolved = "solved"
    evFailed = "failed"
    evBudget = "budget"
    evEnd = "end"

  SimEvent* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    kind*: EventKind
    tick*: int
    slot*: int
      ## the lane this event happened in, or -1 for an episode-wide kind.
    i*, x*, y*, n*, m*: int
    a*, b*, c*: string

  RosterEntry* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    name*: string
    slot*: int
    token*: string
    joinOrder*: int
    address*: string
    connected*: bool
    alias*: string
    policy*: string
    kind*: string
    baseline*: string
    registered*: bool

  TaskRecord* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    family*: TaskFamily
    mission*: string
    outcome*: TaskOutcome
    turns*: int
    ticks*: int
    progress*: int
    cellsSeen*: int

  Lane* = object
    ## FLATTY WIRE TYPE — field order is sacred. ONE SEAT'S WHOLE PRIVATE
    ## WORLD. Nothing outside this object is readable by `stepLane`, and
    ## nothing in it is readable by another lane.
    taskIndex*: int
      ## the phase this lane is playing. Phases are synchronised, so it always
      ## equals `sim.taskIndex` — kept HERE so `stepLane` needs no server.
    task*: Task
    knownMap*: KnownMap
    agent*: Agent
    obstacles*: seq[Obstacle]
    productions*: seq[Production]
    subgoals*: array[3, bool]
    taskTick*: int
    taskTurns*: int
    taskStarted*: bool
    taskOutcome*: TaskOutcome
    records*: seq[TaskRecord]

    queue*: seq[Primitive]
    executed*: seq[Primitive]
    planTruncated*: bool
    lastDropped*: int
    lastUnreachable*: int
    lastPartial*: int
    notes*: string

    laneTicks*: int
    deaths*: int
    crashes*: int
    doorsOpened*: int
    objectsPickedUp*: int
    productionsFired*: int
    primitivesExecuted*: int
    actionsDropped*: int
    macrosUnreachable*: int
    macrosPartial*: int
      ## macros that walked as close as the known map allowed instead of
      ## yielding nothing (addendum v2.1 Case C).
    repliesRepaired*: int
    llmTurns*: int
    fallbackTurns*: int
    retriedTurns*: int
      ## turns where attempt 1 failed and attempt 2 SUCCEEDED. These are NOT
      ## in `fallbackCauses`, which is scoped to turns that fell back.
    fallbackCauses*: array[FallbackCause, int]
      ## every FAILED ATTEMPT on a turn that fell back, each under its own
      ## cause — both attempts, not just the last (addendum v2.1 §2). The
      ## identity is `fallbackTurns <= sum <= 2 * fallbackTurns`.
    endRule*: LaneEndRule

  SimServer* = object
    ## FLATTY WIRE TYPE — field order is sacred. Keyframes flatty this whole
    ## object, so a reordered field silently re-interprets every recorded
    ## keyframe of every existing replay.
    config*: GameConfig
    phase*: Phase
    tickCount*: int
    gameStartTick*: int
    lobbyTicks*: int
    gameOverTick*: int
    hash*: uint64
    players*: seq[RosterEntry]

    ladder*: seq[TaskFamily]
    taskIndex*: int
      ## THE SHARED PHASE INDEX. Phase boundaries are synchronised: every
      ## lane starts phase k on the same turn, and a lane that resolves early
      ## idles until the boundary.
    phaseStarted*: bool
    turnsPlayed*: int
    turnTicksLeft*: int
    lanes*: seq[Lane]

    deadSeats*: seq[bool]
    policyKinds*: seq[string]

    endReason*: EndReason
    endRule*: EndRule
    stopDetail*: string
    pending*: seq[SimEvent]
    feedDirectives*: seq[string]
    gameEventLoggingEnabled*: bool

  SimError* = object of CatchableError

proc seatCount*(sim: SimServer): int = max(1, sim.config.numAgents)

proc laneCount*(sim: SimServer): int = sim.lanes.len

proc emit(sim: var SimServer, event: SimEvent) =
  var copy = event
  copy.tick = sim.tickCount
  sim.pending.add(copy)

proc emitLane(sim: var SimServer, slot: int, event: SimEvent) =
  var copy = event
  copy.tick = sim.tickCount
  copy.slot = slot
  sim.pending.add(copy)

# ---------------------------------------------------------------------------
#  Lane predicates — every one of them reads ONE lane and nothing else
# ---------------------------------------------------------------------------

proc facingObject(lane: Lane, obj: ObjectRef): bool =
  let front = lane.agent.ahead()
  lane.task.grid.objectAt(front.x, front.y) == obj

proc adjacentTo(lane: Lane, obj: ObjectRef): bool =
  for dir in Dirs:
    let
      nx = lane.agent.x + DirDx[dir]
      ny = lane.agent.y + DirDy[dir]
    if lane.task.grid.objectAt(nx, ny) == obj:
      return true
  false

proc findObject*(g: Grid, obj: ObjectRef): tuple[found: bool, x, y: int] =
  for y in 0 ..< GridSize:
    for x in 0 ..< GridSize:
      if g.objectAt(x, y) == obj:
        return (true, x, y)
  (false, 0, 0)

proc onGoal*(lane: Lane): bool =
  lane.task.grid.at(lane.agent.x, lane.agent.y).kind == ckGoal

proc goalDistance(lane: Lane): int =
  for y in 0 ..< GridSize:
    for x in 0 ..< GridSize:
      if lane.task.grid.at(x, y).kind == ckGoal:
        return manhattan(lane.agent.x, lane.agent.y, x, y)
  99

proc succeeded*(lane: Lane): bool =
  ## The family's success predicate, against ONE lane.
  case lane.task.family
  of tfLavagap, tfDoorkey, tfMultiroom, tfDynamic:
    lane.onGoal()
  of tfKeycorridor:
    lane.agent.carrying == lane.task.goalObject
  of tfBabyai:
    case lane.task.instructionKind
    of 0:
      lane.facingObject(lane.task.targetA)
    of 1:
      lane.agent.carrying == lane.task.targetA
    else:
      ## "put X next to Y": the two objects sit on 4-adjacent cells and
      ## NEITHER is carried.
      if lane.agent.carrying == lane.task.targetA or
          lane.agent.carrying == lane.task.targetB:
        false
      else:
        let a = lane.task.grid.findObject(lane.task.targetA)
        let b = lane.task.grid.findObject(lane.task.targetB)
        a.found and b.found and manhattan(a.x, a.y, b.x, b.y) == 1
  of tfXland:
    lane.task.grid.objectExists(lane.task.goalObject) or
      lane.agent.carrying == lane.task.goalObject

proc subgoalHolds(lane: Lane, which: int): bool =
  case lane.task.family
  of tfLavagap:
    case which
    of 0: lane.knownMap.known(lane.task.gapX, lane.task.gapY).seen
    of 1: lane.agent.x > lane.task.gapX
    else: lane.succeeded()
  of tfDoorkey:
    case which
    of 0: lane.agent.carrying.kind == ckKey and
          lane.agent.carrying.colour == lane.task.keyColour
    of 1: lane.task.grid.at(lane.task.doorX, lane.task.doorY).door == dsOpen
    else: lane.succeeded()
  of tfMultiroom:
    case which
    of 0: roomOf(lane.agent.x, lane.agent.y) == 1
    of 1: roomOf(lane.agent.x, lane.agent.y) == 2
    else: lane.succeeded()
  of tfKeycorridor:
    case which
    of 0: lane.agent.carrying.kind == ckKey and
          lane.agent.carrying.colour == lane.task.keyColour
    of 1: lane.task.grid.at(lane.task.doorX, lane.task.doorY).door == dsOpen
    else: lane.succeeded()
  of tfDynamic:
    case which
    of 0: lane.goalDistance() <= 12
    of 1: lane.goalDistance() <= 6
    else: lane.succeeded()
  of tfBabyai:
    case lane.task.instructionKind
    of 0:
      case which
      of 0: lane.task.grid.findObject(lane.task.targetA).found and
            (let spot = lane.task.grid.findObject(lane.task.targetA);
             lane.knownMap.known(spot.x, spot.y).seen)
      of 1:
        let spot = lane.task.grid.findObject(lane.task.targetA)
        spot.found and
          manhattan(lane.agent.x, lane.agent.y, spot.x, spot.y) <= 3
      else: lane.succeeded()
    of 1:
      case which
      of 0:
        let spot = lane.task.grid.findObject(lane.task.targetA)
        (not spot.found) or lane.knownMap.known(spot.x, spot.y).seen
      of 1: lane.adjacentTo(lane.task.targetA) and
            lane.facingObject(lane.task.targetA)
      else: lane.succeeded()
    else:
      case which
      of 0: lane.agent.carrying == lane.task.targetA
      of 1:
        let a = lane.task.grid.findObject(lane.task.targetA)
        let b = lane.task.grid.findObject(lane.task.targetB)
        a.found and b.found and manhattan(a.x, a.y, b.x, b.y) <= 3
      else: lane.succeeded()
  of tfXland:
    case which
    of 0: lane.productions.len > 0
    of 1:
      if lane.task.rules.len < 3:
        false
      else:
        var made = 0
        for i in 0 .. 1:
          let product = lane.task.rules[i].output
          if lane.task.grid.objectExists(product) or
              lane.agent.carrying == product:
            inc made
          else:
            for record in lane.productions:
              if record.output == product:
                inc made
                break
        made >= 2
    else: lane.succeeded()

proc laneResolved*(lane: Lane): bool =
  ## The lane has finished the CURRENT phase and is idling at the boundary.
  lane.taskStarted and lane.taskOutcome != toPending

# ---------------------------------------------------------------------------
#  Phase lifecycle — synchronised across all four lanes
# ---------------------------------------------------------------------------

proc familyAt*(sim: SimServer, index: int): TaskFamily =
  if index >= 0 and index < sim.ladder.len: sim.ladder[index] else: tfLavagap

proc startLanePhase(lane: var Lane, config: GameConfig, family: TaskFamily,
                    index, tick: int) =
  ## Generates phase `index`'s layout from `mix64(seed, taskIndex, ...)`. The
  ## LANE INDEX IS NOT AN INPUT, so every lane gets the identical layout,
  ## mission sentence and rule table.
  lane.taskIndex = index
  lane.task = generate(family, config.seed, index, config.obstacleCount,
    config.babyaiObjects, config.xlandObjects, config.xlandRules)
  lane.agent = Agent(x: lane.task.startX, y: lane.task.startY,
                     dir: lane.task.startDir)
  lane.obstacles = lane.task.obstacles
  lane.knownMap = KnownMap()
  lane.productions = @[]
  lane.subgoals = [false, false, false]
  lane.taskTick = 0
  lane.taskTurns = 0
  lane.taskStarted = true
  lane.taskOutcome = toPending
  lane.queue = @[]
  lane.executed = @[]
  discard lane.knownMap.mergeVisible(lane.task.grid, lane.agent.x,
    lane.agent.y, lane.agent.dir, tick)

proc startPhase*(sim: var SimServer, index: int) =
  ## Advances EVERY lane to phase `index` together and emits ONE `taskstart`.
  sim.taskIndex = index
  sim.phaseStarted = true
  let family = sim.familyAt(index)
  for slot in 0 ..< sim.lanes.len:
    startLanePhase(sim.lanes[slot], sim.config, family, index, sim.tickCount)
  let mission =
    if sim.lanes.len > 0: sim.lanes[0].task.mission else: ""
  sim.emit(SimEvent(kind: evTaskStart, slot: -1, i: index,
    n: sim.config.taskCount, m: sim.config.taskTurnCap, a: $family,
    b: mission))

proc recordLanePhase(lane: var Lane, index: int) =
  var record = TaskRecord(
    family: lane.task.family,
    mission: lane.task.mission,
    outcome: lane.taskOutcome,
    turns: lane.taskTurns,
    ticks: lane.taskTick,
    progress: 0,
    cellsSeen: lane.knownMap.cellsSeen()
  )
  for earned in lane.subgoals:
    if earned: inc record.progress
  if record.outcome == toSolved:
    record.progress = 3
  while lane.records.len <= index:
    lane.records.add(TaskRecord(outcome: toUnreached))
  lane.records[index] = record

# ---------------------------------------------------------------------------
#  Scoring — the v1 formula, computed PER LANE
# ---------------------------------------------------------------------------

proc tasksSolved*(lane: Lane): int =
  for record in lane.records:
    if record.outcome == toSolved: inc result

proc progressTotal*(lane: Lane): int =
  for record in lane.records: result += record.progress

proc speedTotal*(lane: Lane, taskTurnCap: int): int =
  for record in lane.records:
    if record.outcome == toSolved:
      result += max(0, taskTurnCap - record.turns)

proc laneScore*(lane: Lane, taskTurnCap: int): int =
  ## scores[i] = 100_000 * tasksSolved + 1_000 * progressTotal + 10 * speedTotal.
  ## Higher is better and every term only ever ADDS: the minimum (0) is the
  ## honest score of a cog that solved nothing and reached no subgoal.
  100_000 * lane.tasksSolved() + 1_000 * lane.progressTotal() +
    10 * lane.speedTotal(taskTurnCap)

proc tasksSolved*(sim: SimServer, slot: int): int =
  if slot >= 0 and slot < sim.lanes.len: sim.lanes[slot].tasksSolved() else: 0

proc progressTotal*(sim: SimServer, slot: int): int =
  if slot >= 0 and slot < sim.lanes.len: sim.lanes[slot].progressTotal() else: 0

proc speedTotal*(sim: SimServer, slot: int): int =
  if slot >= 0 and slot < sim.lanes.len:
    sim.lanes[slot].speedTotal(sim.config.taskTurnCap)
  else: 0

proc score*(sim: SimServer, slot: int): int =
  if slot >= 0 and slot < sim.lanes.len:
    sim.lanes[slot].laneScore(sim.config.taskTurnCap)
  else: 0

proc winner*(sim: SimServer): tuple[slot: int, tied: bool] =
  ## The seat with the STRICTLY highest score. `scores` is already
  ## lexicographic in (tasksSolved, progressTotal, speedTotal), so an exact
  ## tie in `scores` is a genuine draw: no index tie-break, `winner` is null
  ## and `tied` is true.
  var best = -1
  var bestSlot = -1
  var ties = 0
  for slot in 0 ..< sim.lanes.len:
    let value = sim.score(slot)
    if value > best:
      best = value
      bestSlot = slot
      ties = 1
    elif value == best:
      inc ties
  if ties != 1:
    return (-1, true)
  (bestSlot, false)

# ---------------------------------------------------------------------------
#  End conditions
# ---------------------------------------------------------------------------

proc laneEndRuleFor(rule: EndRule): LaneEndRule =
  case rule
  of edWallClock, edFault: lrWallClock
  of edTurnCap: lrTurnCap
  else: lrGauntletComplete

proc finish*(sim: var SimServer, reason: EndReason, rule: EndRule) =
  if sim.phase == GameOver:
    return
  ## Every phase a lane never reached is `unreached` with zero turns, zero
  ## ticks and zero progress — never zeroed out of the ones that ran. The
  ## phase in flight is banked with its REAL outcome, so a gauntlet whose
  ## fifth phase was solved on the very last tick still scores that solve.
  for slot in 0 ..< sim.lanes.len:
    if sim.lanes[slot].taskStarted and
        sim.lanes[slot].records.len <= sim.taskIndex:
      if sim.lanes[slot].taskOutcome == toPending:
        sim.lanes[slot].taskOutcome = toTimeout
      recordLanePhase(sim.lanes[slot], sim.taskIndex)
    while sim.lanes[slot].records.len < sim.config.taskCount:
      sim.lanes[slot].records.add(TaskRecord(
        family: sim.familyAt(sim.lanes[slot].records.len),
        outcome: toUnreached))
    if sim.lanes[slot].endRule == lrNone:
      sim.lanes[slot].endRule =
        if sim.lanes[slot].records.len >= sim.config.taskCount and
            rule == edAllLanesComplete:
          lrGauntletComplete
        else:
          laneEndRuleFor(rule)
  sim.phase = GameOver
  sim.endReason = reason
  sim.endRule = rule
  sim.gameOverTick = sim.tickCount
  var bestSolved = 0
  var bestScore = 0
  for slot in 0 ..< sim.lanes.len:
    bestSolved = max(bestSolved, sim.tasksSolved(slot))
    bestScore = max(bestScore, sim.score(slot))
  sim.emit(SimEvent(kind: evEnd, slot: -1, i: bestSolved,
    n: sim.config.taskCount, m: bestScore, a: $reason, b: $rule))

proc applyStop*(sim: var SimServer, rule: EndRule, detail: string) =
  ## THE LOAD-BEARING STOP. A wall-clock (or fault) fact cannot be re-derived
  ## from sim state, so it is written as ONE record applied by THIS proc on
  ## record and on playback — which is what keeps a deadline-ended replay's
  ## hash chain clean at the stop tick (the particle-worlds scar).
  sim.stopDetail = detail.truncateRunes(MaxStopDetailRunes)
  case rule
  of edWallClock: sim.finish(erDeadline, edWallClock)
  of edFault: sim.finish(erFault, edFault)
  else: sim.finish(erComplete, rule)

proc endLaneTask(sim: var SimServer, slot: int, outcome: TaskOutcome) =
  sim.lanes[slot].taskOutcome = outcome
  case outcome
  of toSolved:
    sim.lanes[slot].subgoals = [true, true, true]
    sim.emitLane(slot, SimEvent(kind: evSolved, i: sim.taskIndex,
      n: sim.lanes[slot].taskTurns, m: sim.lanes[slot].taskTick))
  of toDied:
    inc sim.lanes[slot].deaths
    sim.emitLane(slot, SimEvent(kind: evFailed, i: sim.taskIndex, a: "died"))
  of toCrashed:
    inc sim.lanes[slot].crashes
    sim.emitLane(slot, SimEvent(kind: evFailed, i: sim.taskIndex,
      a: "crashed"))
  else:
    sim.emitLane(slot, SimEvent(kind: evFailed, i: sim.taskIndex,
      a: "timeout"))

proc allLanesResolved*(sim: SimServer): bool =
  for lane in sim.lanes:
    if not lane.laneResolved():
      return false
  true

proc advanceTasks*(sim: var SimServer) =
  ## Turn step 1: time out every lane that has spent its phase window, and if
  ## EVERY lane has resolved the phase, record it and start the next one in
  ## all four lanes together. If there is no next phase, the episode ends.
  if sim.phase != Playing:
    return
  if not sim.phaseStarted:
    sim.startPhase(0)
    return
  for slot in 0 ..< sim.lanes.len:
    ## The phase's own SIX-TURN WINDOW, per lane. A turn whose plan expanded
    ## to no primitives still costs a turn, so without this a phase could take
    ## far more than `taskTurnCap` turns and `speed[i]` would stop meaning
    ## anything.
    if sim.lanes[slot].taskOutcome == toPending and
        sim.lanes[slot].taskTurns >= sim.config.taskTurnCap:
      sim.endLaneTask(slot, toTimeout)
  if not sim.allLanesResolved():
    return
  for slot in 0 ..< sim.lanes.len:
    recordLanePhase(sim.lanes[slot], sim.taskIndex)
  if sim.taskIndex + 1 >= sim.config.taskCount:
    sim.finish(erComplete, edAllLanesComplete)
    return
  sim.startPhase(sim.taskIndex + 1)

proc activeSeats*(sim: SimServer): seq[int] =
  ## An ACTIVE seat is one whose lane has NOT resolved the current phase. An
  ## idling lane is removed from the decision batch and costs NO LLM call,
  ## which is what keeps the wall clock from paying for a lane that finished
  ## early.
  for slot in 0 ..< sim.lanes.len:
    if not sim.lanes[slot].laneResolved():
      result.add(slot)

proc waitingForPlan*(sim: SimServer): bool =
  sim.phase == Playing and sim.turnTicksLeft <= 0

proc beginTurn*(sim: var SimServer) =
  ## THE TURN BOUNDARY, run identically live and on playback: advance the
  ## shared phase if it has resolved, then open a turn of `turnTicks`
  ## sub-steps and charge it to every lane that is still active.
  sim.advanceTasks()
  if sim.phase != Playing:
    return
  inc sim.turnsPlayed
  sim.turnTicksLeft = max(1, sim.config.turnTicks)
  for slot in 0 ..< sim.lanes.len:
    sim.lanes[slot].queue = @[]
    sim.lanes[slot].executed = @[]
    if not sim.lanes[slot].laneResolved():
      inc sim.lanes[slot].taskTurns
  sim.emit(SimEvent(kind: evTurn, slot: -1, i: sim.turnsPlayed,
    n: sim.taskIndex, m: (if sim.lanes.len > 0: sim.lanes[0].taskTurns else: 0)))

proc installLanePlan*(sim: var SimServer, slot: int,
                      primitives: seq[Primitive], truncated: bool,
                      dropped, unreachable: int, partial = 0) =
  ## One seat's expanded queue for this turn, already truncated to
  ## `turnTicks`. Nothing carries over to the next turn.
  if slot < 0 or slot >= sim.lanes.len:
    return
  sim.lanes[slot].queue = primitives
  sim.lanes[slot].executed = @[]
  sim.lanes[slot].planTruncated = truncated
  sim.lanes[slot].lastDropped = dropped
  sim.lanes[slot].lastUnreachable = unreachable
  sim.lanes[slot].lastPartial = partial
  sim.lanes[slot].actionsDropped += dropped
  sim.lanes[slot].macrosUnreachable += unreachable
  sim.lanes[slot].macrosPartial += partial

# ---------------------------------------------------------------------------
#  gameHash
# ---------------------------------------------------------------------------

proc mixHash(hash: var uint64, value: int) =
  hash = hash xor cast[uint64](int64(value))
  hash = hash * 0x100000001B3'u64
  hash = hash xor (hash shr 29)

proc recomputeHash(sim: var SimServer) =
  ## The fixed mixing order of the addendum: every lane in ascending seat
  ## index, then the four outcome and progress vectors, then the turn and the
  ## global tick. One divergent bit is caught at the tick it happens by
  ## `checkReplayHash`.
  var hash = 0xCBF29CE484222325'u64
  for slot in 0 ..< sim.lanes.len:
    let lane = sim.lanes[slot]
    hash.mixHash(sim.taskIndex)
    hash.mixHash(lane.taskTick)
    hash.mixHash(if lane.laneResolved(): 1 else: 0)
    hash.mixHash(lane.agent.x)
    hash.mixHash(lane.agent.y)
    hash.mixHash(ord(lane.agent.dir))
    hash.mixHash(ord(lane.agent.carrying.kind))
    hash.mixHash(ord(lane.agent.carrying.colour))
    for y in 0 ..< GridSize:
      for x in 0 ..< GridSize:
        let cell = lane.task.grid.cells[idx(x, y)]
        hash.mixHash(ord(cell.kind) * 4 + (if cell.obstacle: 2 else: 0))
        hash.mixHash(ord(cell.colour))
        hash.mixHash(ord(cell.door))
    for obstacle in lane.obstacles:
      hash.mixHash(obstacle.x)
      hash.mixHash(obstacle.y)
    var firedMask = 0
    for record in lane.productions:
      for i, rule in lane.task.rules:
        if rule.output == record.output:
          firedMask = firedMask or (1 shl i)
    hash.mixHash(firedMask)
    hash.mixHash(lane.productionsFired)
    for i, earned in lane.subgoals:
      hash.mixHash(if earned: i + 1 else: 0)
  for slot in 0 ..< sim.lanes.len:
    for i in 0 ..< sim.config.taskCount:
      if i < sim.lanes[slot].records.len:
        hash.mixHash(ord(sim.lanes[slot].records[i].outcome))
      else:
        hash.mixHash(ord(toPending))
  for slot in 0 ..< sim.lanes.len:
    for i in 0 ..< sim.config.taskCount:
      if i < sim.lanes[slot].records.len:
        hash.mixHash(sim.lanes[slot].records[i].progress)
      else:
        hash.mixHash(0)
  hash.mixHash(sim.turnsPlayed)
  hash.mixHash(sim.tickCount)
  sim.hash = hash

proc gameHash*(sim: SimServer): uint64 = sim.hash

# ---------------------------------------------------------------------------
#  The tick
# ---------------------------------------------------------------------------

proc stepLane*(lane: var Lane, config: GameConfig, slot, tick: int,
               primitive: Primitive, events: var seq[SimEvent]) =
  ## ONE lane, ONE sub-step. A PURE FUNCTION OF THIS LANE'S OWN STATE AND
  ## THIS LANE'S OWN PRIMITIVE: it takes no `SimServer`, reads no other lane
  ## and writes no other lane. `events` is append-only and never read back, so
  ## it cannot carry state between lanes either.
  if lane.taskOutcome != toPending or not lane.taskStarted:
    return
  inc lane.taskTick
  inc lane.laneTicks
  lane.executed.add(primitive)
  if primitive != pWait:
    inc lane.primitivesExecuted

  # 3. Apply the primitive.
  let outcome = lane.agent.applyPrimitive(lane.task.grid, primitive)
  var finished = toPending
  case outcome.effect
  of pePickup:
    inc lane.objectsPickedUp
    events.add(SimEvent(kind: evPickup, tick: tick, slot: slot,
      x: outcome.x, y: outcome.y,
      a: $outcome.obj.kind, b: $outcome.obj.colour))
  of peDrop:
    events.add(SimEvent(kind: evDrop, tick: tick, slot: slot,
      x: outcome.x, y: outcome.y,
      a: $outcome.obj.kind, b: $outcome.obj.colour))
  of peOpen:
    inc lane.doorsOpened
    events.add(SimEvent(kind: evOpen, tick: tick, slot: slot,
      x: outcome.x, y: outcome.y, a: $outcome.colour))
  of peClose:
    events.add(SimEvent(kind: evClose, tick: tick, slot: slot,
      x: outcome.x, y: outcome.y, a: $outcome.colour))
  of peUnlock:
    inc lane.doorsOpened
    events.add(SimEvent(kind: evUnlock, tick: tick, slot: slot,
      x: outcome.x, y: outcome.y, a: $outcome.colour, b: $outcome.colour))
  of peCrash:
    events.add(SimEvent(kind: evCrash, tick: tick, slot: slot,
      x: outcome.x, y: outcome.y))
    finished = toCrashed
  else: discard

  # 4. Obstacles move (dynamic tasks only).
  if lane.obstacles.len > 0:
    lane.task.grid.stepObstacles(lane.obstacles, lane.agent, config.seed,
      lane.taskIndex, tick)

  # 5. Production rules fire (xland tasks only). At most one per tick.
  if lane.task.rules.len > 0:
    let fired = lane.task.grid.stepProductions(lane.task.rules, tick)
    if fired.fired:
      inc lane.productionsFired
      lane.productions.add(fired.record)
      events.add(SimEvent(kind: evProduce, tick: tick, slot: slot,
        x: fired.record.x, y: fired.record.y,
        a: fired.record.a.describe(), b: fired.record.b.describe(),
        c: fired.record.output.describe()))

  # 6. Phase termination, in this order.
  if finished == toPending:
    if lane.task.grid.at(lane.agent.x, lane.agent.y).kind == ckLava:
      events.add(SimEvent(kind: evLava, tick: tick, slot: slot,
        x: lane.agent.x, y: lane.agent.y))
      finished = toDied
    elif lane.succeeded():
      finished = toSolved
    elif lane.taskTick >= config.taskTurnCap * config.turnTicks:
      finished = toTimeout

  # 7. Visibility and subgoals.
  discard lane.knownMap.mergeVisible(lane.task.grid, lane.agent.x,
    lane.agent.y, lane.agent.dir, tick)
  if finished == toSolved:
    lane.taskOutcome = toSolved
  ## A predicate that FIRST becomes true awards its credit permanently and
  ## emits `subgoal`. Credits are never revoked.
  for which in 0 .. 2:
    if lane.subgoals[which]:
      continue
    if lane.subgoalHolds(which):
      lane.subgoals[which] = true
      events.add(SimEvent(kind: evSubgoal, tick: tick, slot: slot,
        i: lane.taskIndex, n: which, a: lane.task.subgoalNames[which]))

  if finished != toPending:
    ## The lane's phase resolved: it banks the outcome, emits its own
    ## resolution event, stops stepping for the rest of the turn and idles
    ## until the shared phase boundary.
    lane.taskOutcome = finished
    lane.queue = @[]
    case finished
    of toSolved:
      lane.subgoals = [true, true, true]
      events.add(SimEvent(kind: evSolved, tick: tick, slot: slot,
        i: lane.taskIndex, n: lane.taskTurns, m: lane.taskTick))
    of toDied:
      inc lane.deaths
      events.add(SimEvent(kind: evFailed, tick: tick, slot: slot,
        i: lane.taskIndex, a: "died"))
    of toCrashed:
      inc lane.crashes
      events.add(SimEvent(kind: evFailed, tick: tick, slot: slot,
        i: lane.taskIndex, a: "crashed"))
    else:
      events.add(SimEvent(kind: evFailed, tick: tick, slot: slot,
        i: lane.taskIndex, a: "timeout"))

proc stepTick*(sim: var SimServer) =
  ## ONE global sub-step: every ACTIVE lane in ascending seat index takes one
  ## primitive (or a `wait`), then the sub-step is mixed into `gameHash`.
  if sim.phase != Playing:
    return
  if sim.turnTicksLeft <= 0:
    ## The server (and, on playback, the `directive` record) opens the next
    ## turn. Nothing steps without a turn.
    return

  inc sim.tickCount
  dec sim.turnTicksLeft

  for slot in 0 ..< sim.lanes.len:
    if sim.lanes[slot].laneResolved():
      continue
    var primitive = pWait
    if sim.lanes[slot].queue.len > 0:
      primitive = sim.lanes[slot].queue[0]
      sim.lanes[slot].queue.delete(0)
    var events: seq[SimEvent]
    stepLane(sim.lanes[slot], sim.config, slot, sim.tickCount, primitive,
      events)
    for event in events:
      sim.pending.add(event)

  # 8. Mix the sub-step into gameHash.
  sim.recomputeHash()

  ## If every lane has resolved the shared phase, break the turn's tick loop:
  ## the phase ends early and phase k+1 begins on the next turn.
  if sim.allLanesResolved():
    sim.turnTicksLeft = 0

  ## The turn cap, kept as an INDEPENDENT guard so no arithmetic error can
  ## produce an unbounded loop. When the gauntlet has also run out of phases
  ## the honest rule is `allLanesComplete`; `turnCap` is the safety net.
  if sim.turnsPlayed >= sim.config.maxTurns and sim.turnTicksLeft <= 0 and
      sim.allLanesResolved():
    sim.finish(erComplete,
      if sim.taskIndex + 1 >= sim.config.taskCount: edAllLanesComplete
      else: edTurnCap)

proc step*(sim: var SimServer) =
  ## The lobby countdown, then the tick. Kept as one entry point so live play
  ## and replay playback cannot diverge on the phase transition.
  case sim.phase
  of Lobby:
    inc sim.tickCount
    inc sim.lobbyTicks
    ## A seat counts for the lobby only once it has REGISTERED. A joined but
    ## silent seat would otherwise start the game against the default script
    ## and report a champion as scripted (the grf-football scar).
    var ready = 0
    for entry in sim.players:
      if entry.connected and entry.registered: inc ready
    if ready >= sim.config.minPlayers or
        sim.lobbyTicks >= sim.config.lobbyJoinTimeoutTicks:
      sim.phase = Playing
      sim.gameStartTick = sim.tickCount
    sim.recomputeHash()
  of Playing:
    sim.stepTick()
  of GameOver:
    inc sim.tickCount
    sim.recomputeHash()

proc lobbyStartSecondsRemaining*(sim: SimServer): int =
  if sim.phase != Lobby: 0
  else: max(0, (sim.config.lobbyJoinTimeoutTicks - sim.lobbyTicks) div TargetFps)

proc effectiveMaxTicks*(sim: SimServer): int =
  max(1, sim.config.maxTicks + sim.gameStartTick)

proc initSimServer*(config: GameConfig): SimServer =
  result.config = config
  result.phase = Lobby
  result.gameEventLoggingEnabled = true
  result.endRule = edNone
  result.endReason = erComplete
  result.lanes = newSeq[Lane](max(1, config.numAgents))
  for slot in 0 ..< result.lanes.len:
    result.lanes[slot].taskOutcome = toPending
    result.lanes[slot].endRule = lrNone
  result.deadSeats = newSeq[bool](max(1, config.numAgents))
  result.policyKinds = newSeq[string](max(1, config.numAgents))
  for i in 0 ..< result.policyKinds.len:
    result.policyKinds[i] = "scripted"
  for family in config.taskLadder:
    let parsed = parseFamily(family)
    result.ladder.add(if parsed.ok: parsed.family else: tfLavagap)
  while result.ladder.len < config.taskCount:
    result.ladder.add(tfLavagap)
  result.recomputeHash()

# ---------------------------------------------------------------------------
#  Roster
# ---------------------------------------------------------------------------

proc addPlayer*(sim: var SimServer, name: string, slot: int, token: string,
                trusted = false): int =
  ## Seats one player. Returns the roster index, or -1 when the slot is taken
  ## or the token does not match.
  if slot < 0 or slot >= sim.seatCount():
    return -1
  for entry in sim.players:
    if entry.slot == slot:
      return -1
  if not trusted and sim.config.tokens.len > slot and
      sim.config.tokens[slot].len > 0 and sim.config.tokens[slot] != token:
    return -1
  sim.players.add(RosterEntry(
    name: name, slot: slot, token: token, joinOrder: slot,
    connected: true, alias: seatAlias(slot)))
  sim.players.len - 1

proc removePlayerAt*(sim: var SimServer, index: int) =
  if index >= 0 and index < sim.players.len:
    sim.players[index].connected = false
    if sim.players[index].slot < sim.deadSeats.len:
      sim.deadSeats[sim.players[index].slot] = true

proc seatName*(sim: SimServer, slot: int): string =
  for entry in sim.players:
    if entry.slot == slot and entry.name.len > 0:
      return entry.name
  "Baseline (" & $(slot + 1) & ")"

proc pushFeedDirective*(sim: var SimServer, record: string) =
  ## Control records ride the replay chat stream as JSON objects and drive the
  ## broadcast feed. They are re-applied at playback into NON-HASHED fields
  ## only and can never affect the simulation.
  sim.feedDirectives.add(record)
  if sim.feedDirectives.len > 320:
    sim.feedDirectives.delete(0)

# ---------------------------------------------------------------------------
#  The seat's observation — STRICTLY LANE-LOCAL
# ---------------------------------------------------------------------------

proc objectsJson*(lane: Lane): JsonNode =
  ## The MaxObservationObjects most recently observed objects, sorted
  ## ascending by (y, x) within that set, listing only UNCARRIED objects. A
  ## carried object is out of the world.
  result = newJArray()
  var slots: seq[int]
  for slot in 0 ..< GridCells:
    let entry = lane.knownMap.cells[slot]
    if not entry.seen:
      continue
    if entry.cell.kind notin {ckKey, ckBall, ckBox, ckDoor}:
      continue
    slots.add(slot)
  if slots.len > MaxObservationObjects:
    ## Keep the most RECENTLY SEEN entries: sort by seenTick descending, cut,
    ## then restore the documented (y, x) order.
    slots.sort(proc (a, b: int): int =
      let ta = lane.knownMap.cells[a].seenTick
      let tb = lane.knownMap.cells[b].seenTick
      if ta != tb: cmp(tb, ta) else: cmp(a, b))
    slots.setLen(MaxObservationObjects)
  slots.sort()
  for slot in slots:
    let entry = lane.knownMap.cells[slot]
    var item = %*{
      "type": $entry.cell.kind,
      "color": $entry.cell.colour,
      "x": slot mod GridSize,
      "y": slot div GridSize,
      "state": (if entry.cell.kind == ckDoor: $entry.cell.door else: ""),
      "seen_tick": entry.seenTick
    }
    if entry.cell.obstacle:
      item["moves"] = %true
    result.add(item)

proc observationJson*(sim: SimServer, slot: int, includeNotes: bool): JsonNode =
  ## Everything seat `slot` may legitimately know, and nothing else. The
  ## episode seed, every unobserved cell, every layout parameter, the contents
  ## of an unopened box, the xland rule table, future obstacle motion, the
  ## missions and layouts of phases not yet started, the agent's own score,
  ## its real policy name — AND EVERY FACT ABOUT EVERY OTHER LANE — are ALL
  ## hidden. This proc reads `sim.lanes[slot]` and nothing else.
  let lane = sim.lanes[clamp(slot, 0, sim.lanes.high)]
  var view = newJArray()
  for row in lane.task.grid.viewRows(lane.agent.x, lane.agent.y,
      lane.agent.dir):
    view.add(%row)
  var known = newJArray()
  for row in lane.knownMap.knownRows():
    known.add(%row)
  var subgoals = newJArray()
  for i in 0 .. 2:
    subgoals.add(%*{"name": lane.task.subgoalNames[i],
                    "earned": lane.subgoals[i]})
  var productions = newJArray()
  var firstProduction = max(0, lane.productions.len - MaxObservationProductions)
  for i in firstProduction ..< lane.productions.len:
    let record = lane.productions[i]
    productions.add(%*{
      "a": record.a.describe(), "b": record.b.describe(),
      "out": record.output.describe(),
      "x": record.x, "y": record.y, "tick": record.tick})
  var executed = newJArray()
  for primitive in lane.executed:
    executed.add(%($primitive))
  let front = lane.agent.ahead()
  let frontCell = lane.task.grid.at(front.x, front.y)
  var carrying: JsonNode = newJNull()
  if lane.agent.carries():
    carrying = %*{"type": $lane.agent.carrying.kind,
                  "color": $lane.agent.carrying.colour}
  var aheadObject: JsonNode = newJNull()
  if frontCell.kind in {ckKey, ckBall, ckBox, ckDoor}:
    aheadObject = %*{"type": $frontCell.kind, "color": $frontCell.colour,
                     "state": (if frontCell.kind == ckDoor: $frontCell.door
                               else: "")}
  var objects = lane.objectsJson()
  result = %*{
    "you": seatAlias(slot),
    "lane": slot,
    "task": {
      "index": sim.taskIndex + 1,
      "of": sim.config.taskCount,
      "family": $lane.task.family,
      "mission": lane.task.mission,
      "turns_left": max(0, sim.config.taskTurnCap - lane.taskTurns),
      "ticks_left": max(0,
        sim.config.taskTurnCap * sim.config.turnTicks - lane.taskTick)
    },
    "turn": sim.turnsPlayed,
    "tick": sim.tickCount,
    "world": {
      "size": GridSize, "view": ViewSize,
      "legend": {
        ".": "floor", "#": "wall", "~": "lava (fatal)", "G": "goal",
        "k": "key", "o": "ball", "b": "box",
        "D": "open door", "d": "closed door", "L": "locked door",
        "A": "you", "?": "not seen yet"
      }
    },
    "agent": {
      "x": lane.agent.x, "y": lane.agent.y, "dir": $lane.agent.dir,
      "carrying": carrying,
      "ahead": {"glyph": $frontCell.glyphOf(), "object": aheadObject}
    },
    "view": view,
    "known": known,
    "objects": objects,
    "productions": productions,
    "last_plan": {
      "executed": executed,
      "truncated": lane.planTruncated,
      "dropped": lane.lastDropped,
      "unreachable": lane.lastUnreachable,
      "partial": lane.lastPartial
    },
    "subgoals": subgoals,
    "tasks_solved": lane.tasksSolved()
  }
  if includeNotes:
    result["notes"] = %lane.notes
  ## THE SIZE BOUND. The whole observation JSON is capped at
  ## MaxObservationChars, reduced by dropping WHOLE `objects` entries from the
  ## least-recently-seen end — never by cutting a string mid-value, and never
  ## by touching `known` or `view`, which are the game.
  var guard = 0
  while ($result).len > MaxObservationChars and objects.len > 0 and
      guard < MaxObservationObjects + 2:
    inc guard
    var oldest = 0
    for i in 1 ..< objects.len:
      if objects[i]{"seen_tick"}.getInt() <
          objects[oldest]{"seen_tick"}.getInt():
        oldest = i
    var kept = newJArray()
    for i in 0 ..< objects.len:
      if i != oldest:
        kept.add(objects[i])
    objects = kept
    result["objects"] = objects

# ---------------------------------------------------------------------------
#  Results
# ---------------------------------------------------------------------------

proc laneEndRuleName(sim: SimServer, slot: int): string =
  let rule = sim.lanes[slot].endRule
  if rule == lrNone: $lrGauntletComplete else: $rule

proc gauntletResultsJson*(sim: SimServer): string =
  ## The closed results schema. Every per-seat scalar is a 4-element array and
  ## every per-phase array is a 4 x 5 array of arrays; `taskFamilies` and
  ## `taskMissions` stay FLAT 5-element arrays, because all four lanes run the
  ## same seeded ladder — the isolation guarantee, made visible in the
  ## results. Adding a key means updating this proc, the manifest's
  ## `results_schema` and `tools/ci/docker_smoke.sh`'s expected-key set in the
  ## SAME commit — Coworld schemas are closed and undeclared keys are dropped.
  var
    names = newJArray()
    aliases = newJArray()
    lanes = newJArray()
    scores = newJArray()
    win = newJArray()
    laneRules = newJArray()
    families = newJArray()
    missions = newJArray()
    phaseTurns = newJArray()
    solvedCounts = newJArray()
    progressTotals = newJArray()
    speedTotals = newJArray()
    solved = newJArray()
    outcomes = newJArray()
    turns = newJArray()
    ticks = newJArray()
    progress = newJArray()
    cellsSeen = newJArray()
    laneTicks = newJArray()
    deaths = newJArray()
    crashes = newJArray()
    doors = newJArray()
    picked = newJArray()
    produced = newJArray()
    primitives = newJArray()
    droppedActions = newJArray()
    unreachable = newJArray()
    partialMacros = newJArray()
    repaired = newJArray()
    llmTurns = newJArray()
    fallbackTurns = newJArray()
    retriedTurns = newJArray()
    fallbackCauses = newJArray()
    dead = newJArray()
    kinds = newJArray()
  for slot in 0 ..< sim.lanes.len:
    let lane = sim.lanes[slot]
    names.add(%sim.seatName(slot))
    aliases.add(%seatAlias(slot))
    lanes.add(%slot)
    scores.add(%sim.score(slot))
    win.add(%(lane.tasksSolved() >= sim.config.parTasks))
    laneRules.add(%sim.laneEndRuleName(slot))
    solvedCounts.add(%lane.tasksSolved())
    progressTotals.add(%lane.progressTotal())
    speedTotals.add(%lane.speedTotal(sim.config.taskTurnCap))
    laneTicks.add(%lane.laneTicks)
    deaths.add(%lane.deaths)
    crashes.add(%lane.crashes)
    doors.add(%lane.doorsOpened)
    picked.add(%lane.objectsPickedUp)
    produced.add(%lane.productionsFired)
    primitives.add(%lane.primitivesExecuted)
    droppedActions.add(%lane.actionsDropped)
    unreachable.add(%lane.macrosUnreachable)
    partialMacros.add(%lane.macrosPartial)
    repaired.add(%lane.repliesRepaired)
    llmTurns.add(%lane.llmTurns)
    fallbackTurns.add(%lane.fallbackTurns)
    retriedTurns.add(%lane.retriedTurns)
    var causes = newJObject()
    for cause in FallbackCause:
      if lane.fallbackCauses[cause] > 0:
        causes[$cause] = %lane.fallbackCauses[cause]
    fallbackCauses.add(causes)
    dead.add(%(if slot < sim.deadSeats.len: sim.deadSeats[slot] else: true))
    kinds.add(%(if slot < sim.policyKinds.len: sim.policyKinds[slot]
                else: "scripted"))
    var
      laneSolved = newJArray()
      laneOutcomes = newJArray()
      laneTurns = newJArray()
      laneTaskTicks = newJArray()
      laneProgress = newJArray()
      laneCellsSeen = newJArray()
    for i in 0 ..< sim.config.taskCount:
      let record =
        if i < lane.records.len: lane.records[i]
        else: TaskRecord(family: sim.familyAt(i), outcome: toUnreached)
      laneSolved.add(%(record.outcome == toSolved))
      laneOutcomes.add(%($record.outcome))
      laneTurns.add(%record.turns)
      laneTaskTicks.add(%record.ticks)
      laneProgress.add(%record.progress)
      laneCellsSeen.add(%record.cellsSeen)
    solved.add(laneSolved)
    outcomes.add(laneOutcomes)
    turns.add(laneTurns)
    ticks.add(laneTaskTicks)
    progress.add(laneProgress)
    cellsSeen.add(laneCellsSeen)
  for i in 0 ..< sim.config.taskCount:
    var family = $sim.familyAt(i)
    var mission = ""
    if sim.lanes.len > 0 and i < sim.lanes[0].records.len and
        sim.lanes[0].records[i].mission.len > 0:
      family = $sim.lanes[0].records[i].family
      mission = sim.lanes[0].records[i].mission
    elif sim.lanes.len > 0 and sim.lanes[0].taskStarted and i == sim.taskIndex:
      mission = sim.lanes[0].task.mission
    families.add(%family)
    missions.add(%mission)
    var consumed = 0
    for slot in 0 ..< sim.lanes.len:
      if i < sim.lanes[slot].records.len:
        consumed = max(consumed, sim.lanes[slot].records[i].turns)
    phaseTurns.add(%consumed)
  let verdict = sim.winner()
  var winnerNode: JsonNode = newJNull()
  if not verdict.tied and verdict.slot >= 0:
    winnerNode = %verdict.slot
  let finalTick =
    if sim.gameOverTick > 0: max(0, sim.gameOverTick - sim.gameStartTick)
    else: max(0, sim.tickCount - sim.gameStartTick)
  $(%*{
    "names": names,
    "aliases": aliases,
    "lanes": lanes,
    "scores": scores,
    "win": win,
    "winner": winnerNode,
    "tied": verdict.tied,
    "reason": $sim.endReason,
    "endRule": $sim.endRule,
    "laneEndRule": laneRules,
    "variant": sim.config.variant,
    "seed": sim.config.seed,
    "taskCount": sim.config.taskCount,
    "parTasks": sim.config.parTasks,
    "cellsTotal": GridCells,
    "taskFamilies": families,
    "taskMissions": missions,
    "phaseTurns": phaseTurns,
    "tasksSolved": solvedCounts,
    "progressTotal": progressTotals,
    "speedTotal": speedTotals,
    "taskSolved": solved,
    "taskOutcome": outcomes,
    "taskTurns": turns,
    "taskTicks": ticks,
    "taskProgress": progress,
    "taskCellsSeen": cellsSeen,
    "laneTicks": laneTicks,
    "deaths": deaths,
    "crashes": crashes,
    "doorsOpened": doors,
    "objectsPickedUp": picked,
    "productionsFired": produced,
    "primitivesExecuted": primitives,
    "actionsDropped": droppedActions,
    "macrosUnreachable": unreachable,
    "macrosPartial": partialMacros,
    "repliesRepaired": repaired,
    "finalTick": finalTick,
    "turnsPlayed": sim.turnsPlayed,
    "policyKinds": kinds,
    "llmTurns": llmTurns,
    "fallbackTurns": fallbackTurns,
    "retriedTurns": retriedTurns,
    "fallbackCauses": fallbackCauses,
    "deadSeats": dead,
    "stopDetail": sim.stopDetail
  })

proc playerResultsJson*(sim: SimServer): string = sim.gauntletResultsJson()

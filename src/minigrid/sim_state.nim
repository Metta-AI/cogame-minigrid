## The simulation: the step loop of the design note exactly as numbered,
## `gameHash`, task and episode end evaluation, scoring, and the seat's
## observation builder.
##
## THE WHOLE PHYSICS OF THE GAME IS `stepTick` AND NOTHING ELSE MUTATES THE
## WORLD. All arithmetic is integer only — cell coordinates, directions, tick
## counters, BFS distances, subgoal counters, scores. There is no floating
## point anywhere in this module, which is what makes the native <-> wasm hash
## chain exact by construction (and `tests/test_minigrid_sim.nim` greps for
## it).

import std/[json, strutils, algorithm]
import sim_types, sim_config, grid, tasks, agent, xland

type
  EventKind* = enum
    ## The closed enum of derived broadcast events. `tests/test_minigrid_events.nim`
    ## asserts the emitted set equals exactly this list.
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
    turnsPlayed*: int
    planTruncated*: bool
    lastDropped*: int
    lastUnreachable*: int
    notes*: string

    deaths*: int
    crashes*: int
    doorsOpened*: int
    objectsPickedUp*: int
    productionsFired*: int
    primitivesExecuted*: int
    actionsDropped*: int
    macrosUnreachable*: int
    repliesRepaired*: int
    llmTurns*: int
    fallbackTurns*: int
    deadSeats*: seq[bool]
    policyKinds*: seq[string]

    endReason*: EndReason
    endRule*: EndRule
    stopDetail*: string
    pending*: seq[SimEvent]
    feedDirectives*: seq[string]
    gameEventLoggingEnabled*: bool

  SimError* = object of CatchableError

const
  IdentityNames* = ["alpha", "bravo", "charlie", "delta"]
    ## Inherited from the starter's roster: the in-game aliases. With one seat
    ## only `Alpha` is ever used, and it is the ONLY name that appears in an
    ## observation, in a prompt, in a `say`, or on the board.

proc seatAlias*(slot: int): string =
  ## The anonymous cog alias, title-cased. The seat's REAL policy name lives
  ## only in `results.names`, in the replay's join record, and spectator-side
  ## in the viewer.
  let base = IdentityNames[clamp(slot, 0, IdentityNames.high)]
  base[0].toUpperAscii() & base[1 .. ^1]

proc seatCount*(sim: SimServer): int = max(1, sim.config.numAgents)

proc emit(sim: var SimServer, event: SimEvent) =
  var copy = event
  copy.tick = sim.tickCount
  sim.pending.add(copy)

# ---------------------------------------------------------------------------
#  Task lifecycle
# ---------------------------------------------------------------------------

proc familyAt*(sim: SimServer, index: int): TaskFamily =
  if index >= 0 and index < sim.ladder.len: sim.ladder[index] else: tfLavagap

proc startTask*(sim: var SimServer, index: int) =
  ## Generates task `index`'s layout from `mix64(seed, taskIndex, ...)`,
  ## places the agent and emits `taskstart`. Nothing about the layout depends
  ## on what happened in an earlier task.
  sim.taskIndex = index
  sim.task = generate(sim.familyAt(index), sim.config.seed, index,
    sim.config.obstacleCount, sim.config.babyaiObjects,
    sim.config.xlandObjects, sim.config.xlandRules)
  sim.agent = Agent(x: sim.task.startX, y: sim.task.startY,
                    dir: sim.task.startDir)
  sim.obstacles = sim.task.obstacles
  sim.knownMap = KnownMap()
  sim.productions = @[]
  sim.subgoals = [false, false, false]
  sim.taskTick = 0
  sim.taskTurns = 0
  sim.taskStarted = true
  sim.taskOutcome = toPending
  sim.queue = @[]
  discard sim.knownMap.mergeVisible(sim.task.grid, sim.agent.x, sim.agent.y,
    sim.agent.dir, sim.tickCount)
  sim.emit(SimEvent(kind: evTaskStart, i: index, n: sim.config.taskCount,
    m: sim.config.taskTurnCap, a: $sim.task.family, b: sim.task.mission))

proc recordTask(sim: var SimServer) =
  var record = TaskRecord(
    family: sim.task.family,
    mission: sim.task.mission,
    outcome: sim.taskOutcome,
    turns: sim.taskTurns,
    ticks: sim.taskTick,
    progress: 0,
    cellsSeen: sim.knownMap.cellsSeen()
  )
  for earned in sim.subgoals:
    if earned: inc record.progress
  if record.outcome == toSolved:
    record.progress = 3
  while sim.records.len <= sim.taskIndex:
    sim.records.add(TaskRecord(outcome: toUnreached))
  sim.records[sim.taskIndex] = record

proc tasksSolved*(sim: SimServer): int =
  for record in sim.records:
    if record.outcome == toSolved: inc result

proc progressTotal*(sim: SimServer): int =
  for record in sim.records: result += record.progress

proc speedTotal*(sim: SimServer): int =
  for record in sim.records:
    if record.outcome == toSolved:
      result += max(0, sim.config.taskTurnCap - record.turns)

proc score*(sim: SimServer): int =
  ## scores[0] = 100_000 * tasksSolved + 1_000 * progressTotal + 10 * speedTotal.
  ## Higher is better and every term only ever ADDS: the minimum (0) is the
  ## honest score of a cog that solved nothing and reached no subgoal.
  100_000 * sim.tasksSolved() + 1_000 * sim.progressTotal() +
    10 * sim.speedTotal()

proc finish*(sim: var SimServer, reason: EndReason, rule: EndRule) =
  if sim.phase == GameOver:
    return
  ## Every task the episode never reached is `unreached` with zero turns,
  ## zero ticks and zero progress — never zeroed out of the ones that ran.
  ## The task in flight is banked with its REAL outcome, so a gauntlet whose
  ## fifth task was solved on the very last tick still scores that solve.
  if sim.taskStarted and sim.records.len <= sim.taskIndex:
    if sim.taskOutcome == toPending:
      sim.taskOutcome = toTimeout
    sim.recordTask()
  while sim.records.len < sim.config.taskCount:
    sim.records.add(TaskRecord(
      family: sim.familyAt(sim.records.len),
      outcome: toUnreached))
  sim.phase = GameOver
  sim.endReason = reason
  sim.endRule = rule
  sim.gameOverTick = sim.tickCount
  sim.emit(SimEvent(kind: evEnd, i: sim.tasksSolved(),
    n: sim.config.taskCount, m: sim.score(), a: $reason, b: $rule))

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

proc endTask(sim: var SimServer, outcome: TaskOutcome)

proc advanceTasks*(sim: var SimServer) =
  ## Turn step 1: if the current task has finished, record its result and
  ## start the next; if there is no next task, end the episode.
  if sim.phase != Playing:
    return
  if sim.taskStarted and sim.taskOutcome == toPending:
    ## The task's own ELEVEN-TURN WINDOW. A turn whose plan expanded to no
    ## primitives still costs a turn, so without this a task could take far
    ## more than `taskTurnCap` turns and `speed[i]` would stop meaning
    ## anything.
    if sim.taskTurns >= sim.config.taskTurnCap:
      sim.endTask(toTimeout)
    else:
      return
  if sim.taskStarted:
    sim.recordTask()
    if sim.taskIndex + 1 >= sim.config.taskCount:
      sim.finish(erComplete, edGauntletComplete)
      return
    sim.startTask(sim.taskIndex + 1)
  else:
    sim.startTask(0)

proc waitingForPlan*(sim: SimServer): bool =
  sim.phase == Playing and sim.queue.len == 0

proc installPlan*(sim: var SimServer, primitives: seq[Primitive],
                  truncated: bool, dropped, unreachable: int) =
  ## The turn's expanded queue, already truncated to `turnTicks`. Nothing
  ## carries over to the next turn.
  sim.queue = primitives
  sim.executed = @[]
  sim.planTruncated = truncated
  sim.lastDropped = dropped
  sim.lastUnreachable = unreachable
  sim.actionsDropped += dropped
  sim.macrosUnreachable += unreachable
  inc sim.turnsPlayed
  inc sim.taskTurns
  sim.emit(SimEvent(kind: evTurn, i: sim.turnsPlayed, n: sim.taskIndex,
    m: sim.taskTurns))

# ---------------------------------------------------------------------------
#  Success predicates and subgoals
# ---------------------------------------------------------------------------

proc facingObject(sim: SimServer, obj: ObjectRef): bool =
  let front = sim.agent.ahead()
  sim.task.grid.objectAt(front.x, front.y) == obj

proc adjacentTo(sim: SimServer, obj: ObjectRef): bool =
  for dir in Dirs:
    let
      nx = sim.agent.x + DirDx[dir]
      ny = sim.agent.y + DirDy[dir]
    if sim.task.grid.objectAt(nx, ny) == obj:
      return true
  false

proc findObject*(g: Grid, obj: ObjectRef): tuple[found: bool, x, y: int] =
  for y in 0 ..< GridSize:
    for x in 0 ..< GridSize:
      if g.objectAt(x, y) == obj:
        return (true, x, y)
  (false, 0, 0)

proc onGoal*(sim: SimServer): bool =
  sim.task.grid.at(sim.agent.x, sim.agent.y).kind == ckGoal

proc goalDistance(sim: SimServer): int =
  for y in 0 ..< GridSize:
    for x in 0 ..< GridSize:
      if sim.task.grid.at(x, y).kind == ckGoal:
        return manhattan(sim.agent.x, sim.agent.y, x, y)
  99

proc succeeded*(sim: SimServer): bool =
  ## The family's success predicate.
  case sim.task.family
  of tfLavagap, tfDoorkey, tfMultiroom, tfDynamic:
    sim.onGoal()
  of tfKeycorridor:
    sim.agent.carrying == sim.task.goalObject
  of tfBabyai:
    case sim.task.instructionKind
    of 0:
      sim.facingObject(sim.task.targetA)
    of 1:
      sim.agent.carrying == sim.task.targetA
    else:
      ## "put X next to Y": the two objects sit on 4-adjacent cells and
      ## NEITHER is carried.
      if sim.agent.carrying == sim.task.targetA or
          sim.agent.carrying == sim.task.targetB:
        false
      else:
        let a = sim.task.grid.findObject(sim.task.targetA)
        let b = sim.task.grid.findObject(sim.task.targetB)
        a.found and b.found and manhattan(a.x, a.y, b.x, b.y) == 1
  of tfXland:
    sim.task.grid.objectExists(sim.task.goalObject) or
      sim.agent.carrying == sim.task.goalObject

proc subgoalHolds(sim: SimServer, which: int): bool =
  case sim.task.family
  of tfLavagap:
    case which
    of 0: sim.knownMap.known(sim.task.gapX, sim.task.gapY).seen
    of 1: sim.agent.x > sim.task.gapX
    else: sim.succeeded()
  of tfDoorkey:
    case which
    of 0: sim.agent.carrying.kind == ckKey and
          sim.agent.carrying.colour == sim.task.keyColour
    of 1: sim.task.grid.at(sim.task.doorX, sim.task.doorY).door == dsOpen
    else: sim.succeeded()
  of tfMultiroom:
    case which
    of 0: roomOf(sim.agent.x, sim.agent.y) == 1
    of 1: roomOf(sim.agent.x, sim.agent.y) == 2
    else: sim.succeeded()
  of tfKeycorridor:
    case which
    of 0: sim.agent.carrying.kind == ckKey and
          sim.agent.carrying.colour == sim.task.keyColour
    of 1: sim.task.grid.at(sim.task.doorX, sim.task.doorY).door == dsOpen
    else: sim.succeeded()
  of tfDynamic:
    case which
    of 0: sim.goalDistance() <= 12
    of 1: sim.goalDistance() <= 6
    else: sim.succeeded()
  of tfBabyai:
    case sim.task.instructionKind
    of 0:
      case which
      of 0: sim.task.grid.findObject(sim.task.targetA).found and
            (let spot = sim.task.grid.findObject(sim.task.targetA);
             sim.knownMap.known(spot.x, spot.y).seen)
      of 1:
        let spot = sim.task.grid.findObject(sim.task.targetA)
        spot.found and manhattan(sim.agent.x, sim.agent.y, spot.x, spot.y) <= 3
      else: sim.succeeded()
    of 1:
      case which
      of 0:
        let spot = sim.task.grid.findObject(sim.task.targetA)
        (not spot.found) or sim.knownMap.known(spot.x, spot.y).seen
      of 1: sim.adjacentTo(sim.task.targetA) and
            sim.facingObject(sim.task.targetA)
      else: sim.succeeded()
    else:
      case which
      of 0: sim.agent.carrying == sim.task.targetA
      of 1:
        let a = sim.task.grid.findObject(sim.task.targetA)
        let b = sim.task.grid.findObject(sim.task.targetB)
        a.found and b.found and manhattan(a.x, a.y, b.x, b.y) <= 3
      else: sim.succeeded()
  of tfXland:
    case which
    of 0: sim.productions.len > 0
    of 1:
      if sim.task.rules.len < 3:
        false
      else:
        var made = 0
        for i in 0 .. 1:
          let product = sim.task.rules[i].output
          if sim.task.grid.objectExists(product) or
              sim.agent.carrying == product:
            inc made
          else:
            for record in sim.productions:
              if record.output == product:
                inc made
                break
        made >= 2
    else: sim.succeeded()

proc evaluateSubgoals(sim: var SimServer) =
  ## Tick step 7's second half: a predicate that FIRST becomes true awards its
  ## credit permanently and emits `subgoal`. Credits are never revoked.
  for which in 0 .. 2:
    if sim.subgoals[which]:
      continue
    if sim.subgoalHolds(which):
      sim.subgoals[which] = true
      sim.emit(SimEvent(kind: evSubgoal, i: sim.taskIndex, n: which,
        a: sim.task.subgoalNames[which]))

# ---------------------------------------------------------------------------
#  gameHash
# ---------------------------------------------------------------------------

proc mixHash(hash: var uint64, value: int) =
  hash = hash xor cast[uint64](int64(value))
  hash = hash * 0x100000001B3'u64
  hash = hash xor (hash shr 29)

proc recomputeHash(sim: var SimServer) =
  ## The fixed mixing order of the design note. One divergent bit is caught at
  ## the tick it happens by `checkReplayHash`.
  var hash = 0xCBF29CE484222325'u64
  hash.mixHash(sim.taskIndex)
  hash.mixHash(sim.taskTick)
  hash.mixHash(sim.agent.x)
  hash.mixHash(sim.agent.y)
  hash.mixHash(ord(sim.agent.dir))
  hash.mixHash(ord(sim.agent.carrying.kind))
  hash.mixHash(ord(sim.agent.carrying.colour))
  for y in 0 ..< GridSize:
    for x in 0 ..< GridSize:
      let cell = sim.task.grid.cells[idx(x, y)]
      hash.mixHash(ord(cell.kind) * 4 + (if cell.obstacle: 2 else: 0))
      hash.mixHash(ord(cell.colour))
      hash.mixHash(ord(cell.door))
  for obstacle in sim.obstacles:
    hash.mixHash(obstacle.x)
    hash.mixHash(obstacle.y)
  var firedMask = 0
  for record in sim.productions:
    for i, rule in sim.task.rules:
      if rule.output == record.output:
        firedMask = firedMask or (1 shl i)
  hash.mixHash(firedMask)
  hash.mixHash(sim.productionsFired)
  for i, earned in sim.subgoals:
    hash.mixHash(if earned: i + 1 else: 0)
  for i in 0 ..< sim.config.taskCount:
    if i < sim.records.len:
      hash.mixHash(ord(sim.records[i].outcome))
      hash.mixHash(sim.records[i].progress)
    else:
      hash.mixHash(ord(toPending))
      hash.mixHash(0)
  hash.mixHash(sim.tickCount)
  sim.hash = hash

proc gameHash*(sim: SimServer): uint64 = sim.hash

# ---------------------------------------------------------------------------
#  The tick
# ---------------------------------------------------------------------------

proc endTask(sim: var SimServer, outcome: TaskOutcome) =
  sim.taskOutcome = outcome
  case outcome
  of toSolved:
    sim.subgoals = [true, true, true]
    sim.emit(SimEvent(kind: evSolved, i: sim.taskIndex, n: sim.taskTurns,
      m: sim.taskTick))
  of toDied:
    inc sim.deaths
    sim.emit(SimEvent(kind: evFailed, i: sim.taskIndex, a: "died"))
  of toCrashed:
    inc sim.crashes
    sim.emit(SimEvent(kind: evFailed, i: sim.taskIndex, a: "crashed"))
  else:
    sim.emit(SimEvent(kind: evFailed, i: sim.taskIndex, a: "timeout"))

proc stepTick*(sim: var SimServer) =
  ## ONE tick. This is the whole physics of the game and nothing else mutates
  ## the world.
  if sim.phase != Playing:
    return
  if sim.queue.len == 0:
    sim.advanceTasks()
    if sim.phase != Playing:
      return

  inc sim.tickCount
  inc sim.taskTick

  # 2. Pop the next primitive. An empty queue is a real `wait`: the tick is
  #    spent, which is the cost of a plan that ran out.
  var primitive = pWait
  if sim.queue.len > 0:
    primitive = sim.queue[0]
    sim.queue.delete(0)
  sim.executed.add(primitive)
  if primitive != pWait:
    inc sim.primitivesExecuted

  # 3. Apply the primitive.
  let outcome = sim.agent.applyPrimitive(sim.task.grid, primitive)
  var finished = toPending
  case outcome.effect
  of pePickup:
    inc sim.objectsPickedUp
    sim.emit(SimEvent(kind: evPickup, x: outcome.x, y: outcome.y,
      a: $outcome.obj.kind, b: $outcome.obj.colour))
  of peDrop:
    sim.emit(SimEvent(kind: evDrop, x: outcome.x, y: outcome.y,
      a: $outcome.obj.kind, b: $outcome.obj.colour))
  of peOpen:
    inc sim.doorsOpened
    sim.emit(SimEvent(kind: evOpen, x: outcome.x, y: outcome.y,
      a: $outcome.colour))
  of peClose:
    sim.emit(SimEvent(kind: evClose, x: outcome.x, y: outcome.y,
      a: $outcome.colour))
  of peUnlock:
    inc sim.doorsOpened
    sim.emit(SimEvent(kind: evUnlock, x: outcome.x, y: outcome.y,
      a: $outcome.colour, b: $outcome.colour))
  of peCrash:
    sim.emit(SimEvent(kind: evCrash, x: outcome.x, y: outcome.y))
    finished = toCrashed
  else: discard

  # 4. Obstacles move (dynamic tasks only).
  if sim.obstacles.len > 0:
    sim.task.grid.stepObstacles(sim.obstacles, sim.agent, sim.config.seed,
      sim.taskIndex, sim.tickCount)

  # 5. Production rules fire (xland tasks only). At most one per tick.
  if sim.task.rules.len > 0:
    let fired = sim.task.grid.stepProductions(sim.task.rules, sim.tickCount)
    if fired.fired:
      inc sim.productionsFired
      sim.productions.add(fired.record)
      sim.emit(SimEvent(kind: evProduce, x: fired.record.x, y: fired.record.y,
        a: fired.record.a.describe(), b: fired.record.b.describe(),
        c: fired.record.output.describe()))

  # 6. Task termination, in this order.
  if finished == toPending:
    if sim.task.grid.at(sim.agent.x, sim.agent.y).kind == ckLava:
      sim.emit(SimEvent(kind: evLava, x: sim.agent.x, y: sim.agent.y))
      finished = toDied
    elif sim.succeeded():
      finished = toSolved
    elif sim.taskTick >= sim.config.taskTurnCap * sim.config.turnTicks:
      finished = toTimeout

  # 7. Visibility and subgoals.
  discard sim.knownMap.mergeVisible(sim.task.grid, sim.agent.x, sim.agent.y,
    sim.agent.dir, sim.tickCount)
  if finished == toSolved:
    sim.taskOutcome = toSolved
  sim.evaluateSubgoals()

  if finished != toPending:
    sim.endTask(finished)
    ## 9. The task finished: break out of the tick loop — the turn ends early
    ## and the remaining ticks are skipped. They are NOT transferable.
    sim.queue = @[]

  # 8. Mix the tick into gameHash.
  sim.recomputeHash()

  ## The turn cap, kept as an INDEPENDENT guard so no arithmetic error can
  ## produce an unbounded loop. When the gauntlet has also run out of tasks
  ## the honest rule is `gauntletComplete`; `turnCap` is the safety net.
  if sim.turnsPlayed >= sim.config.maxTurns and sim.queue.len == 0 and
      sim.taskOutcome != toPending:
    sim.recordTask()
    sim.finish(erComplete,
      if sim.taskIndex + 1 >= sim.config.taskCount: edGauntletComplete
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
      sim.startTask(0)
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
  result.taskOutcome = toPending
  result.endRule = edNone
  result.endReason = erComplete
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
  if sim.feedDirectives.len > 240:
    sim.feedDirectives.delete(0)

# ---------------------------------------------------------------------------
#  The seat's observation
# ---------------------------------------------------------------------------

proc objectsJson*(sim: SimServer): JsonNode =
  ## Every object ever in view, sorted ascending by (y, x), listing only
  ## UNCARRIED objects. A carried object is out of the world.
  result = newJArray()
  var slots: seq[int]
  for slot in 0 ..< GridCells:
    let entry = sim.knownMap.cells[slot]
    if not entry.seen:
      continue
    if entry.cell.kind notin {ckKey, ckBall, ckBox, ckDoor}:
      continue
    slots.add(slot)
  slots.sort()
  for slot in slots:
    let entry = sim.knownMap.cells[slot]
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

proc observationJson*(sim: SimServer, includeNotes: bool): JsonNode =
  ## Everything the seat may legitimately know, and nothing else. The episode
  ## seed, every unobserved cell, every layout parameter, the contents of an
  ## unopened box, the xland rule table, future obstacle motion, the missions
  ## and layouts of tasks not yet started, the agent's own score and its real
  ## policy name are ALL hidden.
  var view = newJArray()
  for row in sim.task.grid.viewRows(sim.agent.x, sim.agent.y, sim.agent.dir):
    view.add(%row)
  var known = newJArray()
  for row in sim.knownMap.knownRows():
    known.add(%row)
  var subgoals = newJArray()
  for i in 0 .. 2:
    subgoals.add(%*{"name": sim.task.subgoalNames[i],
                    "earned": sim.subgoals[i]})
  var productions = newJArray()
  for record in sim.productions:
    productions.add(%*{
      "a": record.a.describe(), "b": record.b.describe(),
      "out": record.output.describe(),
      "x": record.x, "y": record.y, "tick": record.tick})
  var executed = newJArray()
  for primitive in sim.executed:
    executed.add(%($primitive))
  let front = sim.agent.ahead()
  let frontCell = sim.task.grid.at(front.x, front.y)
  var carrying: JsonNode = newJNull()
  if sim.agent.carries():
    carrying = %*{"type": $sim.agent.carrying.kind,
                  "color": $sim.agent.carrying.colour}
  var aheadObject: JsonNode = newJNull()
  if frontCell.kind in {ckKey, ckBall, ckBox, ckDoor}:
    aheadObject = %*{"type": $frontCell.kind, "color": $frontCell.colour,
                     "state": (if frontCell.kind == ckDoor: $frontCell.door
                               else: "")}
  result = %*{
    "you": seatAlias(0),
    "task": {
      "index": sim.taskIndex + 1,
      "of": sim.config.taskCount,
      "family": $sim.task.family,
      "mission": sim.task.mission,
      "turns_left": max(0, sim.config.taskTurnCap - sim.taskTurns),
      "ticks_left": max(0,
        sim.config.taskTurnCap * sim.config.turnTicks - sim.taskTick)
    },
    "turn": sim.turnsPlayed + 1,
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
      "x": sim.agent.x, "y": sim.agent.y, "dir": $sim.agent.dir,
      "carrying": carrying,
      "ahead": {"glyph": $frontCell.glyphOf(), "object": aheadObject}
    },
    "view": view,
    "known": known,
    "objects": sim.objectsJson(),
    "productions": productions,
    "last_plan": {
      "executed": executed,
      "truncated": sim.planTruncated,
      "dropped": sim.lastDropped,
      "unreachable": sim.lastUnreachable
    },
    "subgoals": subgoals,
    "tasks_solved": sim.tasksSolved()
  }
  if includeNotes:
    result["notes"] = %sim.notes

# ---------------------------------------------------------------------------
#  Results
# ---------------------------------------------------------------------------

proc gauntletResultsJson*(sim: SimServer): string =
  ## The closed results schema. Adding a key means updating this proc, the
  ## manifest's `results_schema` and `tools/ci/docker_smoke.sh`'s expected-key
  ## set in the SAME commit — Coworld schemas are closed and undeclared keys
  ## are dropped.
  var
    names = newJArray()
    aliases = newJArray()
    scores = newJArray()
    win = newJArray()
    families = newJArray()
    missions = newJArray()
    solved = newJArray()
    outcomes = newJArray()
    turns = newJArray()
    ticks = newJArray()
    progress = newJArray()
    cellsSeen = newJArray()
    dead = newJArray()
    kinds = newJArray()
  for slot in 0 ..< sim.seatCount():
    names.add(%sim.seatName(slot))
    aliases.add(%seatAlias(slot))
    scores.add(%sim.score())
    win.add(%(sim.tasksSolved() >= sim.config.parTasks))
    dead.add(%(if slot < sim.deadSeats.len: sim.deadSeats[slot] else: true))
    kinds.add(%(if slot < sim.policyKinds.len: sim.policyKinds[slot]
                else: "scripted"))
  for i in 0 ..< sim.config.taskCount:
    let record =
      if i < sim.records.len: sim.records[i]
      else: TaskRecord(family: sim.familyAt(i), outcome: toUnreached)
    families.add(%($record.family))
    missions.add(%record.mission)
    solved.add(%(record.outcome == toSolved))
    outcomes.add(%($record.outcome))
    turns.add(%record.turns)
    ticks.add(%record.ticks)
    progress.add(%record.progress)
    cellsSeen.add(%record.cellsSeen)
  var winner: JsonNode = newJNull()
  if sim.tasksSolved() >= sim.config.parTasks:
    winner = %0
  var totalTicks = 0
  for i in 0 ..< sim.config.taskCount:
    if i < sim.records.len: totalTicks += sim.records[i].ticks
  $(%*{
    "names": names,
    "aliases": aliases,
    "scores": scores,
    "win": win,
    "winner": winner,
    "reason": $sim.endReason,
    "endRule": $sim.endRule,
    "variant": sim.config.variant,
    "seed": sim.config.seed,
    "taskCount": sim.config.taskCount,
    "parTasks": sim.config.parTasks,
    "tasksSolved": sim.tasksSolved(),
    "progressTotal": sim.progressTotal(),
    "speedTotal": sim.speedTotal(),
    "taskFamilies": families,
    "taskMissions": missions,
    "taskSolved": solved,
    "taskOutcome": outcomes,
    "taskTurns": turns,
    "taskTicks": ticks,
    "taskProgress": progress,
    "deaths": sim.deaths,
    "crashes": sim.crashes,
    "taskCellsSeen": cellsSeen,
    "cellsTotal": GridCells,
    "doorsOpened": sim.doorsOpened,
    "objectsPickedUp": sim.objectsPickedUp,
    "productionsFired": sim.productionsFired,
    "primitivesExecuted": sim.primitivesExecuted,
    "actionsDropped": sim.actionsDropped,
    "macrosUnreachable": sim.macrosUnreachable,
    "repliesRepaired": sim.repliesRepaired,
    "finalTick": totalTicks,
    "turnsPlayed": sim.turnsPlayed,
    "policyKinds": kinds,
    "llmTurns": sim.llmTurns,
    "fallbackTurns": sim.fallbackTurns,
    "deadSeats": dead,
    "stopDetail": sim.stopDetail
  })

proc playerResultsJson*(sim: SimServer): string = sim.gauntletResultsJson()

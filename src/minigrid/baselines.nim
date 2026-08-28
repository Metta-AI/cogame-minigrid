## The two published scripted baselines.
##
## Both emit the SAME reply object an LLM does, through the SAME validator,
## which is what makes the bounded-orders test meaningful. NEITHER EVER EMITS
## `say` OR `notes` — a baseline that narrated would make the feed lie about
## which seats are LLMs.
##
## `scout` is load-bearing in three places: it is the certification player,
## the per-turn fallback when a seat's LLM call fails twice, and the default
## for a seat that registers with neither PLAYER_PROMPT nor PLAYER_SCRIPTED.

import std/[strutils]
import sim_types, sim_config, grid, tasks, agent, xland, sim_state, driver,
  directives

type
  Baseline* = enum
    blScout = "scout"
    blBumper = "bumper"

  BaselineParams* = object
    ## The tunables of the two baselines. They are a parameter object rather
    ## than literals because they were CHOSEN by a grid sweep, not guessed:
    ## `tools/tune_baselines.nim` plays the ladder over a bounded matrix of
    ## them and prints the table, `tools/ci/baseline_tuning.json` records the
    ## sweep's pick, and `tests/test_minigrid_tuning.nim` asserts the shipped
    ## defaults below still equal it.
    frontierAdjacencyWeight*: int
      ## how much one adjacent `?` cell is worth against one step of BFS
      ## distance when picking the frontier cell to walk to.
    spinTurns*: int
      ## how many `right` primitives the spin rule emits when the whole
      ## reachable region is mapped and the target is not in it.
    tieBreakByDistance*: bool
      ## true: ties on frontier score break by lowest BFS distance, then by
      ## lowest (y, x). false: straight to (y, x).

const DefaultBaselineParams* = BaselineParams(
  ## THE GRID HARNESS'S PICK, NOT A GUESS. `tools/tune_baselines.nim` plays
  ## the gauntlet ladder over 40 seeds for every cell of the matrix and this
  ## one wins; `tools/ci/baseline_tuning.json` records the whole grid and
  ## `ci.yml` re-runs the sweep with `--check`.
  frontierAdjacencyWeight: 1,
  spinTurns: 12,
  tieBreakByDistance: false
)

proc parseBaseline*(text: string): Baseline =
  ## PLAYER_SCRIPTED values. Anything unrecognised is `scout`: a seat that
  ## says nothing useful still plays the published default rather than sitting
  ## out.
  case text.strip().toLowerAscii()
  of "bumper", "bump": blBumper
  else: blScout

proc goalCell(sim: SimServer): tuple[found: bool, x, y: int] =
  ## The goal square, as the agent REMEMBERS it — never the true grid.
  for slot in 0 ..< GridCells:
    let entry = sim.knownMap.cells[slot]
    if entry.seen and entry.cell.kind == ckGoal:
      return (true, slot mod GridSize, slot div GridSize)
  (false, 0, 0)

proc knownObject(sim: SimServer, obj: ObjectRef): tuple[found: bool, x, y: int] =
  for slot in 0 ..< GridCells:
    let entry = sim.knownMap.cells[slot]
    if not entry.seen or entry.cell.obstacle:
      continue
    if entry.cell.kind == obj.kind and entry.cell.colour == obj.colour:
      return (true, slot mod GridSize, slot div GridSize)
  (false, 0, 0)

proc knownDoor(sim: SimServer, colour: Colour,
               states: set[DoorState]): tuple[found: bool, x, y: int] =
  for slot in 0 ..< GridCells:
    let entry = sim.knownMap.cells[slot]
    if not entry.seen or entry.cell.kind != ckDoor:
      continue
    if entry.cell.door notin states:
      continue
    if colour != coNone and entry.cell.colour != colour:
      continue
    return (true, slot mod GridSize, slot div GridSize)
  (false, 0, 0)

proc missionTarget(sim: SimServer): tuple[found: bool, obj: ObjectRef] =
  ## What the current subgoal names, as an object the baseline can walk to.
  case sim.task.family
  of tfDoorkey:
    if sim.agent.carrying.kind == ckKey and
        sim.agent.carrying.colour == sim.task.keyColour:
      (false, ObjectRef())
    else:
      (true, ObjectRef(kind: ckKey, colour: sim.task.keyColour))
  of tfKeycorridor:
    if sim.agent.carrying == sim.task.goalObject:
      (false, ObjectRef())
    elif sim.task.grid.at(sim.task.doorX, sim.task.doorY).door == dsOpen:
      (true, sim.task.goalObject)
    elif sim.agent.carrying.kind == ckKey and
        sim.agent.carrying.colour == sim.task.keyColour:
      (false, ObjectRef())
    else:
      (true, ObjectRef(kind: ckKey, colour: sim.task.keyColour))
  of tfBabyai:
    (true, sim.task.targetA)
  else:
    (false, ObjectRef())

proc frontierCell(sim: SimServer,
                  params: BaselineParams): tuple[found: bool, x, y: int] =
  ## The traversable known cell 4-adjacent to the most `?` cells; ties broken
  ## by lowest BFS distance, then by lowest (y, x).
  let search = sim.knownMap.bfs(sim.agent.x, sim.agent.y)
  var
    best = -1
    bestDist = 0
  for slot in 0 ..< GridCells:
    let
      x = slot mod GridSize
      y = slot div GridSize
    if not search.reached[slot] or not sim.knownMap.traversable(x, y):
      continue
    let unknown = sim.knownMap.frontierScore(x, y)
    if unknown == 0:
      continue
    let distance = search.dist[slot]
    let value = unknown * params.frontierAdjacencyWeight -
      (if params.tieBreakByDistance: distance else: 0)
    if value > best or (value == best and params.tieBreakByDistance and
        distance < bestDist):
      best = value
      bestDist = distance
      result = (true, x, y)

proc safeForwards(sim: SimServer, fromX, fromY: int, dir: Dir,
                  count: int): seq[Action] =
  ## `count` forwards from a pose, stopping at the first cell the agent KNOWS
  ## is lava or holds an obstacle. Walking into the UNKNOWN is the point of
  ## the frontier rule; walking into known lava is suicide, and a baseline
  ## that ever does it fails `tests/test_minigrid_driver.nim` item 18.
  var
    x = fromX
    y = fromY
  for i in 0 ..< count:
    let
      nx = x + DirDx[dir]
      ny = y + DirDy[dir]
    let entry = sim.knownMap.known(nx, ny)
    if entry.seen and (entry.cell.kind == ckLava or entry.cell.obstacle):
      break
    result.add(Action(kind: akForward))
    if entry.seen and not entry.cell.passable():
      break                      ## a wall stops it; the turn is not wasted
    x = nx
    y = ny

proc scoutPlan*(sim: SimServer,
                params = DefaultBaselineParams): Directive =
  ## The deterministic frontier explorer with a goal check. Every turn, the
  ## FIRST matching rule wins, emitting at most `maxActionsPerTurn` actions.
  result.source = dsScripted
  let front = sim.agent.ahead()
  let frontCell = sim.task.grid.at(front.x, front.y)
  let cap = max(1, sim.config.maxActionsPerTurn)

  # 1. Finish if you can.
  let wanted = sim.missionTarget()
  if wanted.found and not sim.agent.carries() and
      sim.task.grid.objectAt(front.x, front.y) == wanted.obj and
      wanted.obj.kind in {ckKey, ckBall, ckBox}:
    result.actions.add(Action(kind: akPickup))
    return
  if frontCell.kind == ckDoor:
    if frontCell.door == dsLocked and sim.agent.carrying.kind == ckKey and
        sim.agent.carrying.colour == frontCell.colour:
      result.actions.add(Action(kind: akToggle))
      return
    if frontCell.door == dsClosed:
      result.actions.add(Action(kind: akToggle))
      return
  if frontCell.kind == ckGoal:
    result.actions.add(Action(kind: akForward))
    return
  if frontCell.kind == ckLava or frontCell.obstacle:
    ## Never stand looking at what kills you with a forward in the plan.
    result.actions.add(Action(kind: akRight))
    return

  # 2. Go to the known target.
  if wanted.found:
    let spot = sim.knownObject(wanted.obj)
    if spot.found:
      result.actions.add(Action(kind: akGoto, x: spot.x, y: spot.y))
      result.actions.add(Action(kind: akPickup))
      return
  block doors:
    ## A locked door is never worth a turn without the key in hand.
    let carriedKey =
      if sim.agent.carrying.kind == ckKey: sim.agent.carrying.colour
      else: coNone
    if carriedKey != coNone:
      let locked = sim.knownDoor(carriedKey, {dsLocked})
      if locked.found:
        result.actions.add(Action(kind: akGoto, x: locked.x, y: locked.y))
        result.actions.add(Action(kind: akToggle))
        result.actions.add(Action(kind: akForward))   ## through the door
        break doors
    let goal = sim.goalCell()
    if goal.found and sim.task.family in
        {tfLavagap, tfDoorkey, tfMultiroom, tfDynamic}:
      result.actions.add(Action(kind: akGoto, x: goal.x, y: goal.y))
      break doors
    let closed = sim.knownDoor(coNone, {dsClosed})
    if closed.found:
      result.actions.add(Action(kind: akGoto, x: closed.x, y: closed.y))
      result.actions.add(Action(kind: akToggle))
      result.actions.add(Action(kind: akForward))     ## through the door
      break doors
  if result.actions.len > 0:
    if result.actions.len > cap:
      result.actions.setLen(cap)
    return

  # 3. Go to the nearest frontier, then actually cross into the unknown and
  #    change heading so the next view is a different one.
  let frontier = sim.frontierCell(params)
  if frontier.found:
    result.actions.add(Action(kind: akGoto, x: frontier.x, y: frontier.y))
    ## Cross INTO the unknown, then change heading so the next view is a
    ## different one — but never step onto a cell already known to be lava or
    ## to hold an obstacle.
    let walk = gotoPrimitives(sim.knownMap, sim.agent.x, sim.agent.y,
      sim.agent.dir, frontier.x, frontier.y, sim.config.macroPrimitiveCap)
    for action in safeForwards(sim, walk.x, walk.y, walk.dir, 2):
      result.actions.add(action)
    result.actions.add(Action(kind: akRight))
    return

  # 4. Spin: the whole reachable region is mapped and the target is not in it.
  for i in 0 ..< min(params.spinTurns, cap):
    result.actions.add(Action(kind: akRight))

proc bumperPlan*(sim: SimServer,
                 params = DefaultBaselineParams): Directive =
  ## The reactive control, four lines: every turn emit twelve actions, each
  ## `forward` if the cell it expects to face is traversable in the known map
  ## and not lava, else `right`. No memory, no BFS, no mission parsing.
  result.source = dsScripted
  var
    x = sim.agent.x
    y = sim.agent.y
    dir = sim.agent.dir
  for i in 0 ..< max(1, sim.config.maxActionsPerTurn):
    let
      nx = x + DirDx[dir]
      ny = y + DirDy[dir]
    if sim.knownMap.traversable(nx, ny) and
        sim.knownMap.known(nx, ny).cell.kind != ckLava:
      result.actions.add(Action(kind: akForward))
      x = nx
      y = ny
    else:
      result.actions.add(Action(kind: akRight))
      dir = Dir((ord(dir) + 1) mod 4)

proc scriptedPlan*(sim: SimServer, kind: Baseline,
                   params = DefaultBaselineParams): Directive =
  ## The one entry point. `scout` is imported by the decision engine as its
  ## fallback — never duplicated — so the two cannot drift.
  case kind
  of blScout: scoutPlan(sim, params)
  of blBumper: bumperPlan(sim, params)

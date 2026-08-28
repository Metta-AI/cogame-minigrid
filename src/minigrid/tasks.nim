## The seven task families: a generator, a success predicate and three named
## subgoal predicates each, plus the mission-sentence builders (including the
## BabyAI three-rule grammar) and the ladder tables for the two variants.
##
## DETERMINISM. Every draw inside a generator is a read of the pure hash
## `mix64(seed, taskIndex, salt)` for an increasing salt — never a consumed
## stream. Nothing the policy does can shift a draw, reorder draws, or consume
## one out from under a later task: task k's layout is identical no matter
## what happened in task k-1. That is the strongest form of the idea's "task
## seeds held out" and what makes per-task success rates comparable.

import std/[strutils]
import sim_types, grid, xland

type
  Task* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    family*: TaskFamily
    mission*: string
    grid*: Grid
    startX*, startY*: int
    startDir*: Dir
    obstacles*: seq[Obstacle]
    rules*: seq[ProductionRule]
    subgoalNames*: array[3, string]
    ## Family-specific referents, hidden from the seat:
    targetA*, targetB*: ObjectRef
    goalObject*: ObjectRef
    keyColour*: Colour
    doorX*, doorY*: int
    gapX*, gapY*: int
    instructionKind*: int

const
  ObjectKinds* = [ckKey, ckBall, ckBox]
  LadderGauntlet* = [tfLavagap, tfDoorkey, tfMultiroom, tfKeycorridor, tfBabyai]
  LadderXland* = [tfDynamic, tfXland, tfXland, tfXland, tfBabyai]

proc parseFamily*(text: string): tuple[ok: bool, family: TaskFamily] =
  for family in TaskFamily:
    if $family == text.strip().toLowerAscii():
      return (true, family)
  (false, tfLavagap)

proc freeCells(g: Grid): seq[int] =
  for slot in 0 ..< GridCells:
    if g.cells[slot].kind == ckEmpty:
      result.add(slot)

proc takeFree(g: var Grid, seed, taskIndex, salt: int): tuple[x, y: int] =
  ## One seeded free floor cell. Deterministic given the salt AND the grid,
  ## and every caller consumes its cell before the next draw so two draws with
  ## different salts can never collide on one cell.
  let free = g.freeCells()
  if free.len == 0:
    return (1, 1)
  let slot = free[draw(seed, taskIndex, salt, free.len)]
  (slot mod GridSize, slot div GridSize)

proc placeObject(g: var Grid, x, y: int, obj: ObjectRef) =
  g.setAt(x, y, Cell(kind: obj.kind, colour: obj.colour))

# ---------------------------------------------------------------------------
#  1. lavagap
# ---------------------------------------------------------------------------

proc generateLavagap(seed, taskIndex: int): Task =
  result.family = tfLavagap
  result.mission = "get to the green goal square"
  result.grid.clearTo(ckEmpty)
  result.grid.walled()
  result.gapX = 4 + draw(seed, taskIndex, 1, 5)          ## 4 .. 8
  result.gapY = 1 + draw(seed, taskIndex, 2, 11)         ## 1 .. 11
  for y in 1 ..< GridSize - 1:
    if y != result.gapY:
      result.grid.setAt(result.gapX, y, Cell(kind: ckLava))
  result.grid.setAt(GridSize - 2, GridSize - 2, Cell(kind: ckGoal))
  result.startX = 1
  result.startY = 1
  result.startDir = dirEast
  result.subgoalNames = ["gap_seen", "crossed", "on_goal"]

# ---------------------------------------------------------------------------
#  2. doorkey
# ---------------------------------------------------------------------------

proc generateDoorkey(seed, taskIndex: int): Task =
  result.family = tfDoorkey
  result.mission =
    "use the yellow key to open the door and then get to the green goal square"
  result.grid.clearTo(ckEmpty)
  result.grid.walled()
  let wallX = 5 + draw(seed, taskIndex, 1, 3)            ## 5 .. 7
  for y in 1 ..< GridSize - 1:
    result.grid.setAt(wallX, y, Cell(kind: ckWall))
  let doorY = 1 + draw(seed, taskIndex, 2, 11)           ## 1 .. 11
  result.grid.setAt(wallX, doorY,
    Cell(kind: ckDoor, colour: coYellow, door: dsLocked))
  result.doorX = wallX
  result.doorY = doorY
  result.keyColour = coYellow
  result.gapX = wallX

  ## The key and the agent go WEST of the wall; the goal goes EAST of it.
  var westFree: seq[int]
  var eastFree: seq[int]
  for y in 1 ..< GridSize - 1:
    for x in 1 ..< GridSize - 1:
      if x < wallX: westFree.add(idx(x, y))
      elif x > wallX: eastFree.add(idx(x, y))
  let keySlot = westFree[draw(seed, taskIndex, 3, westFree.len)]
  result.grid.setAt(keySlot mod GridSize, keySlot div GridSize,
    Cell(kind: ckKey, colour: coYellow))
  var startSlot = westFree[draw(seed, taskIndex, 4, westFree.len)]
  if startSlot == keySlot:
    startSlot = westFree[(draw(seed, taskIndex, 4, westFree.len) + 1) mod westFree.len]
  result.startX = startSlot mod GridSize
  result.startY = startSlot div GridSize
  result.startDir = dirEast
  let goalSlot = eastFree[draw(seed, taskIndex, 5, eastFree.len)]
  result.grid.setAt(goalSlot mod GridSize, goalSlot div GridSize,
    Cell(kind: ckGoal))
  result.subgoalNames = ["has_key", "door_open", "on_goal"]

# ---------------------------------------------------------------------------
#  3. multiroom
# ---------------------------------------------------------------------------

proc roomOf*(x, y: int): int =
  ## NW = 0, NE = 1, SE = 2, SW = 3. The walls are at x = 6 and y = 6.
  if x < 6 and y < 6: 0
  elif x > 6 and y < 6: 1
  elif x > 6 and y > 6: 2
  elif x < 6 and y > 6: 3
  else: -1

proc generateMultiroom(seed, taskIndex: int): Task =
  result.family = tfMultiroom
  result.mission = "get to the green goal square"
  result.grid.clearTo(ckEmpty)
  result.grid.walled()
  for i in 1 ..< GridSize - 1:
    result.grid.setAt(6, i, Cell(kind: ckWall))
    result.grid.setAt(i, 6, Cell(kind: ckWall))
  ## Three closed, unlocked doors pierce the 0->1, 1->2 and 2->3 boundaries
  ## only; the 0<->3 boundary is solid wall, so the only route is 0->1->2->3.
  let
    door01Y = 1 + draw(seed, taskIndex, 1, 5)             ## on x = 6, y in 1..5
    door12X = 7 + draw(seed, taskIndex, 2, 5)             ## on y = 6, x in 7..11
    door23Y = 7 + draw(seed, taskIndex, 3, 5)             ## on x = 6, y in 7..11
  result.grid.setAt(6, door01Y,
    Cell(kind: ckDoor, colour: coBlue, door: dsClosed))
  result.grid.setAt(door12X, 6,
    Cell(kind: ckDoor, colour: coGreen, door: dsClosed))
  result.grid.setAt(6, door23Y,
    Cell(kind: ckDoor, colour: coPurple, door: dsClosed))
  result.startX = 1 + draw(seed, taskIndex, 4, 5)
  result.startY = 1 + draw(seed, taskIndex, 5, 5)
  result.startDir = dirEast
  let
    goalX = 1 + draw(seed, taskIndex, 6, 5)
    goalY = 7 + draw(seed, taskIndex, 7, 5)
  result.grid.setAt(goalX, goalY, Cell(kind: ckGoal))
  result.subgoalNames = ["in_room_1", "in_room_2", "on_goal"]

# ---------------------------------------------------------------------------
#  4. keycorridor
# ---------------------------------------------------------------------------

const KeycorridorRooms* = [[1, 3], [5, 7], [9, 11]]

proc generateKeycorridor(seed, taskIndex: int): Task =
  result.family = tfKeycorridor
  result.mission = "pick up the blue ball"
  result.grid.clearTo(ckEmpty)
  result.grid.walled()
  ## A vertical corridor at x = 6; three side rooms east of it.
  for y in 1 ..< GridSize - 1:
    result.grid.setAt(7, y, Cell(kind: ckWall))
  for room in 0 .. 2:
    ## The room separators: each side room is closed off from its neighbours,
    ## so the only way in is through its door on the corridor wall.
    let rows = KeycorridorRooms[room]
    if rows[0] > 1:
      for x in 8 ..< GridSize - 1:
        result.grid.setAt(x, rows[0] - 1, Cell(kind: ckWall))
    if rows[1] < GridSize - 2:
      for x in 8 ..< GridSize - 1:
        result.grid.setAt(x, rows[1] + 1, Cell(kind: ckWall))
  let lockedRoom = draw(seed, taskIndex, 1, 3)
  var doorYs: array[3, int]
  for room in 0 .. 2:
    let rows = KeycorridorRooms[room]
    doorYs[room] = rows[0] + draw(seed, taskIndex, 10 + room, rows[1] - rows[0] + 1)
    if room == lockedRoom:
      result.grid.setAt(7, doorYs[room],
        Cell(kind: ckDoor, colour: coRed, door: dsLocked))
    else:
      result.grid.setAt(7, doorYs[room],
        Cell(kind: ckDoor, colour: coGrey, door: dsClosed))
  result.doorX = 7
  result.doorY = doorYs[lockedRoom]
  result.keyColour = coRed
  ## The blue ball is in the locked room; the red key is in one of the other
  ## two.
  let lockedRows = KeycorridorRooms[lockedRoom]
  let
    ballX = 8 + draw(seed, taskIndex, 20, 4)
    ballY = lockedRows[0] + draw(seed, taskIndex, 21, lockedRows[1] - lockedRows[0] + 1)
  result.grid.setAt(ballX, ballY, Cell(kind: ckBall, colour: coBlue))
  result.goalObject = ObjectRef(kind: ckBall, colour: coBlue)
  var unlocked: seq[int]
  for room in 0 .. 2:
    if room != lockedRoom: unlocked.add(room)
  let keyRoom = unlocked[draw(seed, taskIndex, 22, unlocked.len)]
  let keyRows = KeycorridorRooms[keyRoom]
  let
    keyX = 8 + draw(seed, taskIndex, 23, 4)
    keyY = keyRows[0] + draw(seed, taskIndex, 24, keyRows[1] - keyRows[0] + 1)
  result.grid.setAt(keyX, keyY, Cell(kind: ckKey, colour: coRed))
  result.startX = 2
  result.startY = 6
  result.startDir = dirEast
  result.subgoalNames = ["has_key", "door_open", "has_ball"]

# ---------------------------------------------------------------------------
#  5. dynamic
# ---------------------------------------------------------------------------

proc generateDynamic(seed, taskIndex, obstacleCount: int): Task =
  result.family = tfDynamic
  result.mission = "get to the green goal square without touching a grey ball"
  result.grid.clearTo(ckEmpty)
  result.grid.walled()
  result.grid.setAt(GridSize - 2, GridSize - 2, Cell(kind: ckGoal))
  result.startX = 1
  result.startY = 1
  result.startDir = dirEast
  for i in 0 ..< obstacleCount:
    var placed = false
    for attempt in 0 ..< 32:
      let
        x = 1 + draw(seed, taskIndex, 100 + i * 8 + attempt, GridSize - 2)
        y = 1 + draw(seed, taskIndex, 200 + i * 8 + attempt, GridSize - 2)
      if result.grid.at(x, y).kind != ckEmpty:
        continue
      if x == result.startX and y == result.startY:
        continue
      if manhattan(x, y, result.startX, result.startY) <= 2:
        continue
      result.grid.setAt(x, y,
        Cell(kind: ckBall, colour: coGrey, obstacle: true))
      result.obstacles.add(Obstacle(x: x, y: y))
      placed = true
      break
    if not placed:
      break
  result.subgoalNames = ["within_12", "within_6", "on_goal"]

# ---------------------------------------------------------------------------
#  6/7. babyai and xland share the object scatter
# ---------------------------------------------------------------------------

proc distinctObjects*(seed, taskIndex, count: int): seq[ObjectRef] =
  ## `count` (type, colour) pairs drawn WITHOUT repetition from
  ## {key, ball, box} x 6 colours, so every referent is unique.
  var pool: seq[ObjectRef]
  for kind in ObjectKinds:
    for colour in Colours:
      pool.add(ObjectRef(kind: kind, colour: colour))
  for i in 0 ..< count:
    if pool.len == 0:
      break
    let pick = draw(seed, taskIndex, 300 + i, pool.len)
    result.add(pool[pick])
    pool.delete(pick)

proc scatterObjects(task: var Task, seed, taskIndex, count: int): seq[ObjectRef] =
  result = distinctObjects(seed, taskIndex, count)
  for i, obj in result:
    let spot = task.grid.takeFree(seed, taskIndex, 400 + i)
    task.grid.placeObject(spot.x, spot.y, obj)

proc generateBabyai(seed, taskIndex, objectCount: int): Task =
  result.family = tfBabyai
  result.grid.clearTo(ckEmpty)
  result.grid.walled()
  let objects = result.scatterObjects(seed, taskIndex, objectCount)
  let start = result.grid.takeFree(seed, taskIndex, 500)
  result.startX = start.x
  result.startY = start.y
  result.startDir = Dirs[draw(seed, taskIndex, 501, 4)]
  result.instructionKind = draw(seed, taskIndex, 40, 3)
  let a = objects[draw(seed, taskIndex, 502, objects.len)]
  var b = objects[draw(seed, taskIndex, 503, objects.len)]
  if b == a:
    b = objects[(draw(seed, taskIndex, 503, objects.len) + 1) mod objects.len]
  result.targetA = a
  result.targetB = b
  case result.instructionKind
  of 0:
    result.mission = "go to the " & a.describe()
    result.subgoalNames = ["target_seen", "target_near", "facing_target"]
  of 1:
    result.mission = "pick up the " & a.describe()
    result.subgoalNames = ["target_seen", "adjacent_facing", "carried"]
  else:
    result.mission = "put the " & a.describe() & " next to the " & b.describe()
    result.subgoalNames = ["carried_first", "brought_near", "placed_next_to"]

proc generateXland(seed, taskIndex, objectCount, ruleCount: int): Task =
  result.family = tfXland
  result.grid.clearTo(ckEmpty)
  result.grid.walled()
  let objects = result.scatterObjects(seed, taskIndex, objectCount)
  let start = result.grid.takeFree(seed, taskIndex, 500)
  result.startX = start.x
  result.startY = start.y
  result.startDir = Dirs[draw(seed, taskIndex, 501, 4)]
  result.rules = sampleRuleSet(seed, taskIndex, objects, ruleCount)
  result.goalObject = result.rules[result.rules.high].output
  result.mission = "make a " & result.goalObject.describe()
  result.subgoalNames = ["rule_fired", "both_products", "goal_made"]

# ---------------------------------------------------------------------------

proc generate*(family: TaskFamily, seed, taskIndex, obstacleCount,
               babyaiObjects, xlandObjects, xlandRules: int): Task =
  ## The one entry point. A pure function of (family, seed, taskIndex) and the
  ## variant's rule constants.
  case family
  of tfLavagap: generateLavagap(seed, taskIndex)
  of tfDoorkey: generateDoorkey(seed, taskIndex)
  of tfMultiroom: generateMultiroom(seed, taskIndex)
  of tfKeycorridor: generateKeycorridor(seed, taskIndex)
  of tfDynamic: generateDynamic(seed, taskIndex, obstacleCount)
  of tfBabyai: generateBabyai(seed, taskIndex, babyaiObjects)
  of tfXland: generateXland(seed, taskIndex, xlandObjects, xlandRules)

proc ladderFor*(variant: string): seq[TaskFamily] =
  case variant.strip().toLowerAscii()
  of "xland":
    for family in LadderXland: result.add(family)
  else:
    for family in LadderGauntlet: result.add(family)

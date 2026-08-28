## The agent record, the seven primitives of tick step 3 with their exact
## effects, the carry slot, and the known-map merge of tick step 7.
##
## `applyPrimitive` is the WHOLE physics of one agent action and nothing else
## mutates the world through it: an inapplicable primitive is a no-op that
## still costs a tick.

import sim_types, grid

type
  PrimitiveEffect* = enum
    ## What one primitive did, for the event stream. `peNone` is the honest
    ## outcome of a `wait` and of every inapplicable primitive.
    peNone
    peTurned
    peMoved
    peBlocked
    pePickup
    peDrop
    peOpen
    peClose
    peUnlock
    peBoxOpen
    peLava
    peCrash

  Agent* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    x*, y*: int
    dir*: Dir
    carrying*: ObjectRef

  PrimitiveResult* = object
    effect*: PrimitiveEffect
    x*, y*: int              ## the cell the effect happened on
    obj*: ObjectRef
    colour*: Colour

proc ahead*(agent: Agent): tuple[x, y: int] =
  (agent.x + DirDx[agent.dir], agent.y + DirDy[agent.dir])

proc carries*(agent: Agent): bool = agent.carrying.kind != ckEmpty

proc applyPrimitive*(agent: var Agent, g: var Grid,
                     primitive: Primitive): PrimitiveResult =
  ## Tick step 3, exactly.
  let front = agent.ahead()
  result.x = front.x
  result.y = front.y
  case primitive
  of pLeft:
    agent.dir = Dir((ord(agent.dir) + 3) mod 4)
    result.effect = peTurned
  of pRight:
    agent.dir = Dir((ord(agent.dir) + 1) mod 4)
    result.effect = peTurned
  of pForward:
    let cell = g.at(front.x, front.y)
    if cell.obstacle:
      ## Walking into a grey ball ends the task; the agent does NOT move.
      result.effect = peCrash
    elif cell.passable():
      agent.x = front.x
      agent.y = front.y
      result.effect = if cell.kind == ckLava: peLava else: peMoved
      result.x = agent.x
      result.y = agent.y
    else:
      result.effect = peBlocked
  of pPickup:
    let cell = g.at(front.x, front.y)
    if not agent.carries() and cell.pickupable():
      agent.carrying = ObjectRef(kind: cell.kind, colour: cell.colour)
      g.setAt(front.x, front.y, Cell(kind: ckEmpty))
      result.effect = pePickup
      result.obj = agent.carrying
  of pDrop:
    let cell = g.at(front.x, front.y)
    if agent.carries() and cell.kind == ckEmpty and not cell.obstacle:
      g.setAt(front.x, front.y,
        Cell(kind: agent.carrying.kind, colour: agent.carrying.colour))
      result.effect = peDrop
      result.obj = agent.carrying
      agent.carrying = ObjectRef(kind: ckEmpty, colour: coNone)
  of pToggle:
    var cell = g.at(front.x, front.y)
    result.colour = cell.colour
    case cell.kind
    of ckDoor:
      case cell.door
      of dsClosed:
        cell.door = dsOpen
        g.setAt(front.x, front.y, cell)
        result.effect = peOpen
      of dsOpen:
        cell.door = dsClosed
        g.setAt(front.x, front.y, cell)
        result.effect = peClose
      of dsLocked:
        ## A locked door opens only with a carried key of the SAME COLOUR,
        ## and the key is NOT consumed.
        if agent.carrying.kind == ckKey and agent.carrying.colour == cell.colour:
          cell.door = dsOpen
          g.setAt(front.x, front.y, cell)
          result.effect = peUnlock
      else: discard
    of ckBox:
      if not cell.obstacle:
        let inside = decodeObject(cell.contents)
        if inside.kind == ckEmpty:
          g.setAt(front.x, front.y, Cell(kind: ckEmpty))
        else:
          g.setAt(front.x, front.y,
            Cell(kind: inside.kind, colour: inside.colour))
        result.effect = peBoxOpen
        result.obj = inside
    else: discard
  of pWait:
    discard

proc stepObstacles*(g: var Grid, obstacles: var seq[Obstacle], agent: Agent,
                    seed, taskIndex, tick: int) =
  ## Tick step 4. For each obstacle in ascending index, direction
  ## `mix64(seed, taskIndex, 900 + i, tick) mod 4` in the order east, south,
  ## west, north; it moves one cell iff the target is empty floor and is not
  ## the agent's cell. AN OBSTACLE NEVER MOVES INTO THE AGENT — a cog is only
  ## ever killed by a `forward` it chose.
  for i in 0 ..< obstacles.len:
    let
      dir = Dirs[int(mix64(seed, taskIndex, 900 + i, tick) mod 4'u64)]
      nx = obstacles[i].x + DirDx[dir]
      ny = obstacles[i].y + DirDy[dir]
    if not inBounds(nx, ny):
      continue
    if nx == agent.x and ny == agent.y:
      continue
    if g.at(nx, ny).kind != ckEmpty:
      continue
    let old = g.at(obstacles[i].x, obstacles[i].y)
    g.setAt(obstacles[i].x, obstacles[i].y, Cell(kind: ckEmpty))
    g.setAt(nx, ny, old)
    obstacles[i].x = nx
    obstacles[i].y = ny

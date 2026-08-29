## The driver: directive -> per-tick actuation, retargeted from the starter's
## `control.nim` pixel steering to a PRIMITIVE QUEUE.
##
## It is the ONLY producer of primitives and it contains no randomness. It
## never invents an action the schema does not express, and it never produces
## a `forward` into a cell it believes is lava or a wall — but it makes no
## promise about a cell it has never seen, which is why walking into the
## unknown costs an explicit `forward` from the policy.

import std/strutils
import sim_types, grid

type
  ActionKind* = enum
    akLeft = "left"
    akRight = "right"
    akForward = "forward"
    akPickup = "pickup"
    akDrop = "drop"
    akToggle = "toggle"
    akWait = "wait"
    akGoto = "goto"
    akFace = "face"

  Action* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    kind*: ActionKind
    x*, y*: int
    dir*: Dir

  Expansion* = object
    primitives*: seq[Primitive]
    truncated*: bool
    unreachable*: int
    partial*: int
      ## macros that walked as close as the KNOWN map allows and turned toward
      ## the target instead of yielding nothing (addendum v2.1 Case C).

const PrimitiveOf*: array[akLeft .. akWait, Primitive] =
  [pLeft, pRight, pForward, pPickup, pDrop, pToggle, pWait]

proc parseActionKind*(text: string): tuple[ok: bool, kind: ActionKind] =
  ## `do` is lower-cased before matching, and capped at 8 runes by the
  ## validator before it ever reaches here.
  let key = text.strip().toLowerAscii()
  for kind in ActionKind:
    if $kind == key:
      return (true, kind)
  (false, akWait)

proc gotoPrimitives*(map: KnownMap, ax, ay: int, dir: Dir, tx, ty: int,
                     cap: int): tuple[ok: bool, primitives: seq[Primitive],
                                      x, y: int, dir: Dir, partial: bool] =
  ## The `goto` BFS, run against the known map as of TURN START. THREE cases:
  ##
  ## A. the target is traversable and reached — the path ends ON it.
  ## B. the target is not traversable but is 4-adjacent to some reached cell —
  ##    the path ends on the nearest such cell and a final turn toward the
  ##    target is appended.
  ## C. neither — the macro walks BEST-EFFORT to the reached cell that
  ##    minimises, in order, (i) Manhattan distance to the target, (ii) BFS
  ##    distance from the agent, (iii) cell index, then turns toward the axis
  ##    of greatest remaining offset (ties -> the x axis). It reports
  ##    `partial`. ONLY when that cell is the agent's own does the macro yield
  ##    zero primitives and count as `unreachable`.
  ##
  ## The walk is confined to SEEN, TRAVERSABLE cells in every case, so partial
  ## observability, lava safety and "never path through ?" are untouched — and
  ## the target's coordinates came from the policy, not from the game, so
  ## nothing about an unseen cell is leaked back.
  result.x = ax
  result.y = ay
  result.dir = dir
  if not inBounds(tx, ty):
    return
  let search = map.bfs(ax, ay)
  var
    goalX = tx
    goalY = ty
    faceTarget = false
  if not map.traversable(tx, ty) or not search.reached[idx(tx, ty)]:
    var
      best = -1
      bestSlot = -1
    for adjacent in Dirs:
      let
        nx = tx + DirDx[adjacent]
        ny = ty + DirDy[adjacent]
      if not inBounds(nx, ny) or not search.reached[idx(nx, ny)]:
        continue
      let distance = search.dist[idx(nx, ny)]
      if best < 0 or distance < best or
          (distance == best and idx(nx, ny) < bestSlot):
        best = distance
        bestSlot = idx(nx, ny)
    if bestSlot < 0:
      ## CASE C. Get as close as the known map allows.
      var
        bestManhattan = manhattan(ax, ay, tx, ty)
        bestDistance = 0
      bestSlot = idx(ax, ay)
      for slot in 0 ..< GridCells:
        if not search.reached[slot]:
          continue
        let
          cx = slot mod GridSize
          cy = slot div GridSize
          toTarget = manhattan(cx, cy, tx, ty)
          fromAgent = search.dist[slot]
        if toTarget < bestManhattan or
            (toTarget == bestManhattan and fromAgent < bestDistance) or
            (toTarget == bestManhattan and fromAgent == bestDistance and
             slot < bestSlot):
          bestManhattan = toTarget
          bestDistance = fromAgent
          bestSlot = slot
      if bestSlot == idx(ax, ay):
        ## Already as close as the map allows: nothing to walk.
        return
      result.partial = true
    goalX = bestSlot mod GridSize
    goalY = bestSlot div GridSize
    faceTarget = true

  var
    cx = ax
    cy = ay
    cdir = dir
    primitives: seq[Primitive]
  for slot in search.pathTo(goalX, goalY):
    let
      nx = slot mod GridSize
      ny = slot div GridSize
      toward = dirToward(cx, cy, nx, ny)
    if not toward.ok:
      break
    for turn in turnsBetween(cdir, toward.dir):
      primitives.add(turn)
    cdir = toward.dir
    primitives.add(pForward)
    cx = nx
    cy = ny
    if primitives.len > cap:
      break
  if faceTarget:
    ## Face the target when it is 4-adjacent (case B), else the AXIS of the
    ## greatest remaining offset, x before y on a tie (case C).
    var toward = dirToward(cx, cy, tx, ty)
    if not toward.ok:
      let
        dx = tx - cx
        dy = ty - cy
      if dx != 0 or dy != 0:
        toward.ok = true
        toward.dir =
          if abs(dx) >= abs(dy):
            (if dx > 0: dirEast else: dirWest)
          else:
            (if dy > 0: dirSouth else: dirNorth)
    if toward.ok:
      for turn in turnsBetween(cdir, toward.dir):
        primitives.add(turn)
      cdir = toward.dir
  ## Bounded by macroPrimitiveCap primitives.
  if primitives.len > cap:
    primitives.setLen(cap)
  result.ok = true
  result.primitives = primitives
  result.x = cx
  result.y = cy
  result.dir = cdir

proc expandPlan*(map: KnownMap, ax, ay: int, dir: Dir, actions: seq[Action],
                 macroPrimitiveCap, turnTicks: int): Expansion =
  ## Turn step 6c/6d: macros expand against the known map as of turn start,
  ## then the whole queue is truncated to `turnTicks` primitives. The surplus
  ## is discarded and nothing carries over to the next turn.
  var
    cx = ax
    cy = ay
    cdir = dir
  for action in actions:
    case action.kind
    of akGoto:
      let walk = gotoPrimitives(map, cx, cy, cdir, action.x, action.y,
                                macroPrimitiveCap)
      if not walk.ok:
        inc result.unreachable
        continue
      if walk.partial:
        inc result.partial
      for primitive in walk.primitives:
        result.primitives.add(primitive)
      cx = walk.x
      cy = walk.y
      cdir = walk.dir
    of akFace:
      for turn in turnsBetween(cdir, action.dir):
        result.primitives.add(turn)
      cdir = action.dir
    else:
      let primitive = PrimitiveOf[action.kind]
      result.primitives.add(primitive)
      ## Track the virtual pose so a later macro plans from where the earlier
      ## primitives actually left the agent.
      case primitive
      of pLeft: cdir = Dir((ord(cdir) + 3) mod 4)
      of pRight: cdir = Dir((ord(cdir) + 1) mod 4)
      of pForward:
        let
          nx = cx + DirDx[cdir]
          ny = cy + DirDy[cdir]
        if map.traversable(nx, ny):
          cx = nx
          cy = ny
      else: discard
  if result.primitives.len > turnTicks:
    result.primitives.setLen(turnTicks)
    result.truncated = true

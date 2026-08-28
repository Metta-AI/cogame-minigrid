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
                                      x, y: int, dir: Dir] =
  ## The `goto` BFS, run against the known map as of TURN START.
  ##
  ## If the target is traversable, the path ends ON it. If it is not
  ## traversable but is 4-adjacent to some reached cell, the path ends on the
  ## nearest such cell and a final `face` toward the target is appended. If
  ## neither, the macro yields ZERO primitives and counts as `unreachable`.
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
  if not map.traversable(tx, ty):
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
      return
    goalX = bestSlot mod GridSize
    goalY = bestSlot div GridSize
    faceTarget = true
  elif not search.reached[idx(tx, ty)]:
    return

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
    let toward = dirToward(cx, cy, tx, ty)
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

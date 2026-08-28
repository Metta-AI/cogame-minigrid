## The 13 x 13 integer cell grid: 4-adjacency in the fixed order
## east/south/west/north, the BFS `goto` and `scout` share, and the exact
## 7 x 7 visibility flood of the design note.
##
## PURE INTEGER. There is no floating point in this module, no pixie, and no
## pixel query — that is what makes the native <-> wasm hash chain exact by
## construction, and a test greps for it.

import std/[strutils]
import sim_types

type
  Grid* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    cells*: array[GridCells, Cell]

  KnownCell* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    seen*: bool
    cell*: Cell
    seenTick*: int

  KnownMap* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    cells*: array[GridCells, KnownCell]

proc idx*(x, y: int): int {.inline.} = y * GridSize + x

proc inBounds*(x, y: int): bool {.inline.} =
  x >= 0 and y >= 0 and x < GridSize and y < GridSize

proc at*(grid: Grid, x, y: int): Cell =
  if not inBounds(x, y):
    return Cell(kind: ckWall)
  grid.cells[idx(x, y)]

proc setAt*(grid: var Grid, x, y: int, cell: Cell) =
  if inBounds(x, y):
    grid.cells[idx(x, y)] = cell

proc clearTo*(grid: var Grid, kind: CellKind) =
  for cell in grid.cells.mitems:
    cell = Cell(kind: kind)

proc walled*(grid: var Grid) =
  ## The entire border ring is wall, so the playable interior is 11 x 11.
  for i in 0 ..< GridSize:
    grid.setAt(i, 0, Cell(kind: ckWall))
    grid.setAt(i, GridSize - 1, Cell(kind: ckWall))
    grid.setAt(0, i, Cell(kind: ckWall))
    grid.setAt(GridSize - 1, i, Cell(kind: ckWall))

proc known*(map: KnownMap, x, y: int): KnownCell =
  if not inBounds(x, y):
    return KnownCell(seen: true, cell: Cell(kind: ckWall))
  map.cells[idx(x, y)]

proc knownGlyph*(map: KnownMap, x, y: int): char =
  ## '?' until the visibility flood has marked the cell at least once.
  let entry = map.known(x, y)
  if not entry.seen: '?' else: entry.cell.glyphOf()

# ---------------------------------------------------------------------------
#  The 7 x 7 visibility flood — the restated MiniGrid occlusion rule, and the
#  only visibility rule in this game.
# ---------------------------------------------------------------------------

proc viewToWorld*(ax, ay: int, dir: Dir, i, j: int): tuple[x, y: int] =
  ## View coordinate (i, j) -> world cell, for an agent at (ax, ay) facing
  ## `dir`. `i` runs 0..6 LEFT TO RIGHT in the agent's frame; `j` runs 0..6
  ## far to near, so the agent itself sits at (3, 6).
  let
    lateral = i - ViewSize div 2   ## +ve = to the agent's RIGHT
    ahead = ViewSize - 1 - j       ## cells forward of the agent
    fx = DirDx[dir]
    fy = DirDy[dir]
    rx = -fy                       ## forward rotated 90 degrees clockwise
    ry = fx
  (ax + ahead * fx + lateral * rx, ay + ahead * fy + lateral * ry)

proc visibleMask*(grid: Grid, ax, ay: int, dir: Dir): array[ViewSize * ViewSize, bool] =
  ## The flood, exactly as written in the design note. Both sweeps run in the
  ## order given; the rule is integer-only and has no ties to break.
  template vis(i, j: int): untyped = result[j * ViewSize + i]
  template sees(i, j: int): bool =
    let w = viewToWorld(ax, ay, dir, i, j)
    grid.at(w.x, w.y).seesBehind()
  vis(ViewSize div 2, ViewSize - 1) = true
  for j in countdown(ViewSize - 1, 0):
    for i in 0 ..< ViewSize - 1:                    # sweep right
      if vis(i, j) and sees(i, j):
        vis(i + 1, j) = true
        if j > 0:
          vis(i + 1, j - 1) = true
          vis(i, j - 1) = true
    for i in countdown(ViewSize - 1, 1):            # sweep left
      if vis(i, j) and sees(i, j):
        vis(i - 1, j) = true
        if j > 0:
          vis(i - 1, j - 1) = true
          vis(i, j - 1) = true

proc viewRows*(grid: Grid, ax, ay: int, dir: Dir): seq[string] =
  ## Seven strings of seven glyphs, agent-up. The agent's own cell reads 'A';
  ## a cell the flood did not mark reads '?'. Out-of-grid cells read '#'.
  let mask = grid.visibleMask(ax, ay, dir)
  for j in 0 ..< ViewSize:
    var row = newString(ViewSize)
    for i in 0 ..< ViewSize:
      if i == ViewSize div 2 and j == ViewSize - 1:
        row[i] = 'A'
      elif not mask[j * ViewSize + i]:
        row[i] = '?'
      else:
        let w = viewToWorld(ax, ay, dir, i, j)
        row[i] = grid.at(w.x, w.y).glyphOf()
    result.add(row)

proc mergeVisible*(map: var KnownMap, grid: Grid, ax, ay: int, dir: Dir,
                   tick: int): int =
  ## Merges the current 7 x 7 visible set into the known map, stamping each
  ## newly or re-observed cell with `tick`. Returns how many cells were seen
  ## for the FIRST time, which is what `taskCellsSeen` counts.
  let mask = grid.visibleMask(ax, ay, dir)
  for j in 0 ..< ViewSize:
    for i in 0 ..< ViewSize:
      if not mask[j * ViewSize + i]:
        continue
      let w = viewToWorld(ax, ay, dir, i, j)
      if not inBounds(w.x, w.y):
        continue
      let slot = idx(w.x, w.y)
      if not map.cells[slot].seen:
        inc result
      map.cells[slot].seen = true
      map.cells[slot].cell = grid.cells[slot]
      map.cells[slot].seenTick = tick

proc cellsSeen*(map: KnownMap): int =
  for entry in map.cells:
    if entry.seen: inc result

proc knownRows*(map: KnownMap): seq[string] =
  ## Thirteen strings of thirteen glyphs, in WORLD orientation.
  for y in 0 ..< GridSize:
    var row = newString(GridSize)
    for x in 0 ..< GridSize:
      row[x] = map.knownGlyph(x, y)
    result.add(row)

# ---------------------------------------------------------------------------
#  The goto BFS, run against the known map as of turn start
# ---------------------------------------------------------------------------

proc traversable*(map: KnownMap, x, y: int): bool =
  ## A cell is traversable iff its KNOWN glyph is '.', 'G' or 'D'. '?' is
  ## not — the driver plans on what is known, not on hope — and neither is a
  ## cell known to hold an obstacle ball.
  if not inBounds(x, y):
    return false
  let entry = map.known(x, y)
  if not entry.seen or entry.cell.obstacle:
    return false
  case entry.cell.kind
  of ckEmpty, ckGoal: true
  of ckDoor: entry.cell.door == dsOpen
  else: false

type BfsResult* = object
  reached*: array[GridCells, bool]
  parent*: array[GridCells, int]
  dist*: array[GridCells, int]

proc bfs*(map: KnownMap, sx, sy: int): BfsResult =
  ## Breadth-first from the agent's cell; edges are 4-adjacency in the fixed
  ## order east, south, west, north, so the path is UNIQUE for a given known
  ## map. The start cell is always reached, even when it is not traversable
  ## (the agent may be standing on lava it just walked into).
  for i in 0 ..< GridCells:
    result.parent[i] = -1
    result.dist[i] = -1
  if not inBounds(sx, sy):
    return
  var queue = @[idx(sx, sy)]
  result.reached[idx(sx, sy)] = true
  result.dist[idx(sx, sy)] = 0
  var head = 0
  while head < queue.len:
    let
      current = queue[head]
      cx = current mod GridSize
      cy = current div GridSize
    inc head
    for dir in Dirs:
      let
        nx = cx + DirDx[dir]
        ny = cy + DirDy[dir]
      if not inBounds(nx, ny):
        continue
      let slot = idx(nx, ny)
      if result.reached[slot] or not map.traversable(nx, ny):
        continue
      result.reached[slot] = true
      result.parent[slot] = current
      result.dist[slot] = result.dist[current] + 1
      queue.add(slot)

proc pathTo*(search: BfsResult, tx, ty: int): seq[int] =
  ## The cell chain from (exclusive) the start to (inclusive) the target, or
  ## an empty seq when the target was never reached.
  if not inBounds(tx, ty) or not search.reached[idx(tx, ty)]:
    return @[]
  var current = idx(tx, ty)
  while search.parent[current] >= 0:
    result.add(current)
    current = search.parent[current]
  for i in 0 ..< result.len div 2:
    swap(result[i], result[result.len - 1 - i])

proc turnsBetween*(fromDir, toDir: Dir): seq[Primitive] =
  ## The shorter rotation. A 180 degree turn is `right, right`, NEVER
  ## `left, left` — pinned for determinism.
  let delta = (ord(toDir) - ord(fromDir) + 4) mod 4
  case delta
  of 0: @[]
  of 1: @[pRight]
  of 2: @[pRight, pRight]
  else: @[pLeft]

proc dirToward*(fromX, fromY, toX, toY: int): tuple[ok: bool, dir: Dir] =
  ## The 4-adjacent direction from one cell to another, if they touch.
  for dir in Dirs:
    if fromX + DirDx[dir] == toX and fromY + DirDy[dir] == toY:
      return (true, dir)
  (false, dirEast)

proc manhattan*(ax, ay, bx, by: int): int =
  abs(ax - bx) + abs(ay - by)

proc frontierScore*(map: KnownMap, x, y: int): int =
  ## How many of a cell's four neighbours are still '?'. A cell that touches
  ## '?' is where new information is.
  for dir in Dirs:
    let
      nx = x + DirDx[dir]
      ny = y + DirDy[dir]
    if inBounds(nx, ny) and not map.known(nx, ny).seen:
      inc result

proc describe*(obj: ObjectRef): string =
  if obj.kind == ckEmpty: "" else: toLowerAscii($obj.colour & " " & $obj.kind)

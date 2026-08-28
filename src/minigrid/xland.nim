## The hidden-production-rule family: the rule-set sampler, the adjacency scan
## of tick step 5, and the production history the observation exposes.
##
## The rule table is NEVER shown to the seat. The only way to learn it is to
## push things together and read the `productions` list in the next
## observation — the idea's meta-RL test, and the one place in this game where
## the right play on turn 1 is a deliberate experiment.

import sim_types, grid

proc sampleRuleSet*(seed, taskIndex: int, present: seq[ObjectRef],
                    ruleCount: int): seq[ProductionRule] =
  ## Three chained rules: (A)+(B) -> P0, (C)+(D) -> P1, (P0)+(P1) -> GOAL.
  ## A, B, C, D are four distinct objects present on the board; P0, P1 and
  ## GOAL are three (type, colour) pairs NOT present at the start and distinct
  ## from each other.
  if present.len < 4 or ruleCount < 3:
    return @[]
  var inputs = present
  var chosen: seq[ObjectRef]
  for i in 0 ..< 4:
    let pick = draw(seed, taskIndex, 600 + i, inputs.len)
    chosen.add(inputs[pick])
    inputs.delete(pick)

  var pool: seq[ObjectRef]
  for kind in [ckKey, ckBall, ckBox]:
    for colour in Colours:
      let candidate = ObjectRef(kind: kind, colour: colour)
      if candidate notin present:
        pool.add(candidate)
  if pool.len < 3:
    return @[]
  var products: seq[ObjectRef]
  for i in 0 ..< 3:
    let pick = draw(seed, taskIndex, 610 + i, pool.len)
    products.add(pool[pick])
    pool.delete(pick)

  result.add(ProductionRule(a: chosen[0], b: chosen[1], output: products[0]))
  result.add(ProductionRule(a: chosen[2], b: chosen[3], output: products[1]))
  result.add(ProductionRule(a: products[0], b: products[1],
                            output: products[2]))

proc matches*(rule: ProductionRule, first, second: ObjectRef): bool =
  ## A rule fires on an unordered pair.
  (rule.a == first and rule.b == second) or
    (rule.a == second and rule.b == first)

proc objectAt*(g: Grid, x, y: int): ObjectRef =
  let cell = g.at(x, y)
  if cell.kind in {ckKey, ckBall, ckBox} and not cell.obstacle:
    ObjectRef(kind: cell.kind, colour: cell.colour)
  else:
    ObjectRef(kind: ckEmpty, colour: coNone)

proc stepProductions*(g: var Grid, rules: seq[ProductionRule],
                      tick: int): tuple[fired: bool, record: Production] =
  ## Tick step 5. Scan cells in ascending (y, x); for each cell holding an
  ## uncarried object, check its four neighbours in the fixed order east,
  ## south, west, north; for the FIRST (cell, neighbour) pair matching any
  ## rule — rules checked in ascending index — fire it. AT MOST ONE
  ## production per tick. A carried object never participates.
  if rules.len == 0:
    return
  for y in 0 ..< GridSize:
    for x in 0 ..< GridSize:
      let first = g.objectAt(x, y)
      if first.kind == ckEmpty:
        continue
      for dir in Dirs:
        let
          nx = x + DirDx[dir]
          ny = y + DirDy[dir]
        if not inBounds(nx, ny):
          continue
        let second = g.objectAt(nx, ny)
        if second.kind == ckEmpty:
          continue
        for rule in rules:
          if not rule.matches(first, second):
            continue
          ## The product appears in the input cell with the LOWER (y, x).
          let
            lowerFirst = (y < ny) or (y == ny and x < nx)
            px = if lowerFirst: x else: nx
            py = if lowerFirst: y else: ny
          g.setAt(x, y, Cell(kind: ckEmpty))
          g.setAt(nx, ny, Cell(kind: ckEmpty))
          g.setAt(px, py,
            Cell(kind: rule.output.kind, colour: rule.output.colour))
          return (true, Production(a: first, b: second, output: rule.output,
                                   x: px, y: py, tick: tick))

proc objectExists*(g: Grid, obj: ObjectRef): bool =
  for y in 0 ..< GridSize:
    for x in 0 ..< GridSize:
      if g.objectAt(x, y) == obj:
        return true
  false

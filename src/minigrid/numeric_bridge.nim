## Numeric candidate bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:minigrid-numeric-bridge src/minigrid/numeric_bridge.nim

import std/[hashes, json, os, strutils]
import sim, baselines, directives, driver

const
  PrimitiveNames = ["wait", "left", "right", "forward", "pickup", "drop", "toggle"]
  Directions = ["N", "E", "S", "W"]
  Families = ["lavagap", "doorkey", "multiroom", "keycorridor", "dynamic", "babyai", "xland"]
  Colours = ["red", "green", "blue", "purple", "yellow", "grey"]
  Types = ["key", "ball", "box", "door", "goal"]
  GotoStart = PrimitiveNames.len + Directions.len
  ChoiceCount = GotoStart + 13 * 13

var
  game: SimServer
  decisionId: int
  actingSeat: int
  variant = "gauntlet"

proc glyphIndex(glyph: char): int =
  case glyph
  of '?': 0
  of '.': 1
  of '#': 2
  of '~': 3
  of 'G': 4
  of 'k': 5
  of 'o': 6
  of 'b': 7
  of 'D': 8
  of 'd': 9
  of 'L': 10
  of 'A': 11
  else: raise newException(ValueError, "unknown MiniGrid glyph: " & $glyph)

proc category(value: string, names: openArray[string]): int =
  for i, name in names:
    if value == name: return i + 1
  0

proc addText(bins: var array[64, int], value: string) =
  var word = ""
  for ch in value.toLowerAscii() & " ":
    if ch.isAlphaNumeric():
      word.add(ch)
    elif word.len > 0:
      var hash = 2166136261'u32
      for letter in word:
        hash = (hash xor uint32(ord(letter))) * 16777619'u32
      inc bins[int(hash mod 64'u32)]
      word.setLen(0)

proc values*(view: JsonNode, variant: string): JsonNode =
  result = newJArray()
  for name in ["gauntlet", "xland"]:
    result.add(%(if variant == name: 1 else: 0))
  for name in Families:
    result.add(%(if view["task"]["family"].getStr() == name: 1 else: 0))
  for name in ["index", "of", "turns_left", "ticks_left"]:
    result.add(view["task"][name])
  for name in ["turn", "tick", "tasks_solved"]: result.add(view[name])
  let agent = view["agent"]
  for name in ["x", "y"]: result.add(agent[name])
  for name in ["north", "east", "south", "west"]:
    result.add(%(if agent["dir"].getStr() == name: 1 else: 0))
  let carried = agent["carrying"]
  result.add(%(if carried.kind == JNull: 0 else: 1))
  for name in Types:
    result.add(%(if carried.kind != JNull and carried["type"].getStr() == name: 1 else: 0))
  for name in Colours:
    result.add(%(if carried.kind != JNull and carried["color"].getStr() == name: 1 else: 0))
  result.add(%glyphIndex(agent["ahead"]["glyph"].getStr()[0]))
  var
    colors: array[169, int]
    kinds: array[169, int]
    states: array[169, int]
    seen: array[169, int]
    moves: array[169, int]
  for item in view["objects"]:
    let x = item["x"].getInt()
    let y = item["y"].getInt()
    doAssert x in 0 .. 12 and y in 0 .. 12
    let index = y * 13 + x
    colors[index] = category(item["color"].getStr(), Colours)
    kinds[index] = category(item["type"].getStr(), Types)
    states[index] = category(item["state"].getStr(), ["open", "closed", "locked"])
    seen[index] = item["seen_tick"].getInt()
    moves[index] = if item.hasKey("moves") and item["moves"].getBool(): 1 else: 0
  doAssert view["known"].len == 13
  for y in 0 ..< 13:
    let text = view["known"][y].getStr()
    doAssert text.len == 13
    for x, glyph in text:
      let index = y * 13 + x
      for value in [glyphIndex(glyph), colors[index], kinds[index],
          states[index], seen[index], moves[index]]:
        result.add(%value)
  doAssert view["view"].len == 7
  for row in view["view"]:
    let text = row.getStr()
    doAssert text.len == 7
    for glyph in text: result.add(%glyphIndex(glyph))
  let last = view["last_plan"]
  result.add(%last["executed"].len)
  for name in ["truncated", "dropped", "unreachable", "partial"]:
    result.add(%(if last[name].kind == JBool:
      (if last[name].getBool(): 1 else: 0) else: last[name].getInt()))
  var mission, subgoals, productions: array[64, int]
  mission.addText(view["task"]["mission"].getStr())
  for goal in view["subgoals"]:
    subgoals.addText(goal["name"].getStr() &
      (if goal["earned"].getBool(): " earned" else: " unearned"))
  for production in view["productions"]: productions.addText($production)
  for bins in [mission, subgoals, productions]:
    for count in bins: result.add(%count)

proc candidates*(view: JsonNode): JsonNode =
  result = newJArray()
  for choice in 0 ..< ChoiceCount:
    var legal = true
    if choice >= GotoStart:
      let index = choice - GotoStart
      let glyph = view["known"][index div 13].getStr()[index mod 13]
      legal = glyph notin {'?', '#', '~'}
    result.add(if legal: %*{"choice": choice} else: newJNull())

proc currentDecision(): JsonNode =
  let view = game.observationJson(actingSeat, true)
  %*{"kind": "decision", "game": "minigrid", "decision_id": decisionId,
    "seat": actingSeat, "engine_seat": actingSeat,
    "turn": game.turnsPlayed, "semantic_view": view, "inbox": [],
    "messages": [
      {"role": "system", "content": "Choose a legal MiniGrid plan candidate from this seat's observation."},
      {"role": "user", "content": $view}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0, "maximum": ChoiceCount - 1}},
      "required": ["choice"]},
    "typed_question": newJNull()}

proc reset(command: JsonNode): JsonNode =
  doAssert command["players"].getInt() == LaneCount
  var config = defaultGameConfig()
  config.seed = int(hash(command["seed"].getStr()) and hash(high(int)))
  config.variant = variant
  if variant == "xland":
    config.taskLadder = @["dynamic", "xland", "xland", "xland", "babyai"]
    config.parTasks = 2
  config.validate()
  game = initSimServer(config)
  game.phase = Playing
  game.beginTurn()
  decisionId = 0
  actingSeat = game.activeSeats()[0]
  currentDecision()

proc planFor*(choice: int): JsonNode =
  doAssert choice in 0 ..< ChoiceCount
  if choice < PrimitiveNames.len:
    return %*{"actions": [{"do": PrimitiveNames[choice]}]}
  if choice < GotoStart:
    return %*{"actions": [{"do": "face", "dir": Directions[choice - PrimitiveNames.len]}]}
  let index = choice - GotoStart
  %*{"actions": [{"do": "goto", "x": index mod 13, "y": index div 13}]}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let candidate = parseJson(command["response"].getStr())
  let choice = candidate["choice"].getInt()
  doAssert choice in 0 ..< ChoiceCount and
    candidates(game.observationJson(actingSeat, true))[choice].kind != JNull
  let plan = parseDirective(planFor(choice), game.config.maxActionsPerTurn)
  let expanded = expandPlan(game.lanes[actingSeat].knownMap,
    game.lanes[actingSeat].agent.x, game.lanes[actingSeat].agent.y,
    game.lanes[actingSeat].agent.dir, plan.actions,
    game.config.macroPrimitiveCap, game.config.turnTicks)
  game.installLanePlan(actingSeat, expanded.primitives, expanded.truncated,
    plan.dropped, expanded.unreachable, expanded.partial)
  var nextSeat = LaneCount
  for slot in game.activeSeats():
    if slot > actingSeat:
      nextSeat = slot
      break
  if nextSeat < LaneCount:
    actingSeat = nextSeat
  else:
    for tick in 0 ..< game.config.turnTicks:
      game.stepTick()
      game.pending.setLen(0)
      if game.phase != Playing or game.waitingForPlan(): break
    game.beginTurn()
    if game.phase == Playing: actingSeat = game.activeSeats()[0]
  inc decisionId
  if game.phase != Playing:
    var scores = newJObject()
    for slot in 0 ..< LaneCount: scores[$slot] = %game.score(slot)
    return %*{"kind": "accepted", "action": candidate,
      "observation": {"kind": "terminal", "scores": scores}}
  %*{"kind": "accepted", "action": candidate,
    "observation": currentDecision()}

when isMainModule:
  if paramCount() > 1: quit("usage: minigrid-numeric-bridge [gauntlet|xland]", 1)
  if paramCount() == 1: variant = paramStr(1)
  doAssert variant in ["gauntlet", "xland"]
  for line in stdin.lines:
    let request = parseJson(line)
    let response = case request["kind"].getStr()
      of "reset": reset(request)
      of "encode": %*{"decision_id": decisionId,
        "values": values(game.observationJson(actingSeat, true), variant),
        "actions": candidates(game.observationJson(actingSeat, true))}
      of "teacher":
        let first = actionsJson(scoutPlan(game.lanes[actingSeat], game.config).actions)[0]
        let legal = candidates(game.observationJson(actingSeat, true))
        var choice = -1
        for index in 0 ..< ChoiceCount:
          if legal[index].kind != JNull and planFor(index)["actions"][0] == first:
            choice = index
            break
        doAssert choice >= 0
        %*{"response": $(%*{"choice": choice})}
      of "step": step(request)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()

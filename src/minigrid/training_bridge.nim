## Headless MiniGrid gauntlets for Metta post-training.
## Stdout carries one JSON response per request; the game rules stay in sim.nim.

import std/[hashes, json, os]
import sim, baselines, directives, driver

const SystemPrompt = "Play one MiniGrid lane. Reply with one JSON object: " &
  "{\"actions\":[{\"do\":\"left|right|forward|pickup|drop|toggle|wait\"}]} " &
  "or use {\"do\":\"goto\",\"x\":0..12,\"y\":0..12} or " &
  "{\"do\":\"face\",\"dir\":\"N|E|S|W\"}. " &
  "At most 24 actions run per turn; unseen cells and rival lanes are hidden."

var
  game: SimServer
  decisionId: int
  actingSeat: int
  variant = "gauntlet"

proc currentDecision(): JsonNode =
  let view = game.observationJson(actingSeat, true)
  %*{
    "kind": "decision",
    "game": "minigrid",
    "decision_id": decisionId,
    "seat": actingSeat,
    "engine_seat": actingSeat,
    "turn": game.turnsPlayed,
    "semantic_view": view,
    "inbox": [],
    "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": $view},
    ],
    "speech_messages": [],
    "action_schema": {
      "type": "object",
      "properties": {
        "actions": {"type": "array", "maxItems": 24, "items": {
          "type": "object", "required": ["do"], "properties": {
            "do": {"enum": ["left", "right", "forward", "pickup",
              "drop", "toggle", "wait", "goto", "face"]},
            "x": {"type": "integer", "minimum": 0, "maximum": 12},
            "y": {"type": "integer", "minimum": 0, "maximum": 12},
            "dir": {"enum": ["N", "E", "S", "W"]},
          },
        }},
        "say": {"type": "string", "maxLength": 140},
        "notes": {"type": "string", "maxLength": 300},
      },
    },
    "typed_question": newJNull(),
  }

proc reset(command: JsonNode): JsonNode =
  if command["players"].getInt() != LaneCount:
    raise newException(ValueError, "MiniGrid has exactly four isolated lanes")
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

proc teacher(): JsonNode =
  let plan = scoutPlan(game.lanes[actingSeat], game.config)
  %*{"response": $(%*{"actions": actionsJson(plan.actions)})}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  var plan: Directive
  try:
    plan = parseDirective(parseJson(command["response"].getStr()),
      game.config.maxActionsPerTurn)
  except JsonParsingError, DirectiveError:
    return %*{"kind": "rejected", "reason": "reply must be a JSON object"}
  let action = %*{"actions": actionsJson(plan.actions),
    "say": plan.say, "notes": plan.notes}
  let expanded = expandPlan(game.lanes[actingSeat].knownMap,
      game.lanes[actingSeat].agent.x, game.lanes[actingSeat].agent.y,
      game.lanes[actingSeat].agent.dir, plan.actions,
      game.config.macroPrimitiveCap, game.config.turnTicks)
  game.installLanePlan(actingSeat, expanded.primitives, expanded.truncated,
    plan.dropped, expanded.unreachable, expanded.partial)
  game.lanes[actingSeat].notes = plan.notes
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
      if game.phase != Playing or game.waitingForPlan():
        break
    game.beginTurn()
    if game.phase == Playing:
      actingSeat = game.activeSeats()[0]
  inc decisionId
  if game.phase != Playing:
    var scores = newJObject()
    for slot in 0 ..< LaneCount:
      scores[$slot] = %game.score(slot)
    return %*{"kind": "accepted", "action": action,
      "observation": {"kind": "terminal", "scores": scores}}
  %*{"kind": "accepted", "action": action,
    "observation": currentDecision()}

when isMainModule:
  if paramCount() > 1:
    raise newException(ValueError, "Pass at most one variant: gauntlet or xland")
  if paramCount() == 1:
    variant = paramStr(1)
  if variant notin ["gauntlet", "xland"]:
    raise newException(ValueError, "Variant must be gauntlet or xland")
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "teacher": teacher()
      of "step": step(command)
      else: raise newException(ValueError, "Unknown bridge command")
    stdout.writeLine($response)
    stdout.flushFile()

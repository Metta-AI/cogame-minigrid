## Choose a MiniGrid plan from the seat-private observation in the player.

import std/[json, os, strutils]
import curly

proc choosePlan*(observation: JsonNode, deadlineMs: int): JsonNode =
  var criteria = newJObject()
  var plans = newJObject()
  for verb in ["forward", "left", "right", "pickup", "toggle", "drop", "wait"]:
    criteria[verb] = %("Use " & verb & " this turn")
    plans[verb] = %*{"actions": [{"do": verb}]}
  for item in observation["objects"]:
    let x = item["x"].getInt()
    let y = item["y"].getInt()
    let choice = "goto_" & $x & "_" & $y
    criteria[choice] = %("Walk toward the visible " & item["type"].getStr() &
      " at (" & $x & "," & $y & ")")
    plans[choice] = %*{"actions": [{"do": "goto", "x": x, "y": y}]}

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "MiniGrid Jev policy has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $observation["lane"].getInt()
  let body = %*{
    "model": model,
    "state": "You are playing MiniGrid. Solve the current mission using only " &
      "this seat-private observation. Choose a plan candidate:\n" &
      $observation,
    "questions": {"decision": {
      "type": "choice",
      "instructions": "Choose one movement or interaction plan for this turn.",
      "criteria": criteria
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body,
    max(1, min(30, (deadlineMs - 1000) div 1000)))
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len or
      answer["confidence"].getFloat() < 0 or
      answer["confidence"].getFloat() > 1:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  var selected = ""
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      selected = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  echo "MiniGrid Jev player: choice ", selected,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
  result = plans[selected]

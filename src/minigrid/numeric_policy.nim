## Player-side adapter for a numeric policy served over HTTP.

import std/[json, os]
import curly
import numeric_bridge

proc chooseNumericPlan*(request: JsonNode, session: string): JsonNode =
  let
    view = request["observation"]
    variant = request["variant"].getStr()
    legal = candidates(view)
    endpoint = getEnv("PLAYER_NUMERIC_URL")
  doAssert variant in ["gauntlet", "xland"]
  doAssert endpoint.len > 0
  var mask = newJArray()
  for candidate in legal:
    mask.add(%(candidate.kind != JNull))
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  let key = getEnv("PLAYER_NUMERIC_KEY")
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  let body = %*{
    "session": session,
    "seat": view["lane"],
    "decision_id": request["rid"],
    "values": values(view, variant),
    "action_mask": mask
  }
  let response = newCurly().post(endpoint, headers, $body,
    max(1, request["deadline_ms"].getInt() div 1000))
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "numeric policy HTTP " & $response.code)
  let choice = parseJson(response.body)["choice"].getInt()
  if choice notin 0 ..< legal.len or legal[choice].kind == JNull:
    raise newException(ValueError, "numeric policy returned an illegal choice")
  planFor(choice)

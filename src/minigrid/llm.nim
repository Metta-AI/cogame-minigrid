## Claude-backed per-seat command. A policy is just a prompt: the game server
## composes each seat's partially observed view plus that seat's PLAYER_PROMPT
## and asks Claude what that cog does for the next twenty-four ticks.
##
## Forked from `coworld-ctf/src/ctf/llm.nim` behaviour for behaviour — the
## credential ladder, the Bedrock model rotation, the fence-tolerant JSON
## extraction and the rune-boundary truncation are all that file's, because
## they are all scar tissue from real hosted failures.
##
## Minigrid is a SIMULTANEOUS-DECISION game with FOUR isolated lanes, so the
## starter's one-parallel-batch-per-turn machinery (`curly.makeRequests`)
## carries one request per ACTIVE seat — at most four in flight, never a
## sequential per-seat loop.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to
## the scripted layer INSTANTLY, with no network wait — which is what lets
## offline certification finish in seconds.

import
  std/[json, os, strutils],
  bitworld/runtime,
  curly,
  sim_types, sim_config

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## The provider answered 429 and there is no other candidate model to
      ## rotate to. Set per turn, cleared by the turn loop: retrying inside
      ## the same turn cannot succeed, so the seat fails fast to the scripted
      ## fallback instead of spending the turn budget on a call that will be
      ## refused again.

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "minigrid llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; BEDROCK_MODEL pins
  ## one. `us.anthropic.claude-sonnet-4-6` is DELIBERATELY NOT A CANDIDATE:
  ## it times out on every sidecar call (cogame-raid round 2, 2026-08-23).
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "minigrid llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "minigrid llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "minigrid llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back" in decide.nim: "LLM provider is unavailable".
    echo "minigrid llm: no credentials — the LLM provider is unavailable; ",
      "every turn is falling back to the scripted layer"

proc requestFor*(
  client: LlmClient, system, user: string
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none. Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model for the next
  ## batch instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and truncateRunes downstream only SHORTENS — it cannot repair a
    ## broken one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(
      LlmError, "llm auth failed (" & $response.code & ") at " & url & ": " &
      detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  ## Cap the read at MaxReplyBytes before parsing: a provider body is
  ## arbitrary bytes and the reply schema bounds what may be read.
  let payload = parseJson(
    if response.body.len > 4 * MaxReplyBytes:
      response.body[0 ..< 4 * MaxReplyBytes]
    else:
      response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if result.len > MaxReplyBytes:
    result = result.truncateRunes(MaxReplyBytes)
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const SystemPrompt* = """
You are one cog alone in a 13x13 walled gridworld. You can only see a 7x7 window
around yourself. A sentence tells you what to do. You will be given five tasks in
a row; each has its own world and its own sentence and its own six turns.

WHAT YOU GET EACH TURN
- "view": seven rows of seven characters, YOUR OWN VIEW, rotated so you always
  face UP. The bottom middle character is A, that is you. Row 0 is farthest ahead.
- "known": the whole 13x13 board as you remember it. ? means you have never seen
  that cell. Closed and locked doors and walls block sight, so ? stays ? until you
  walk somewhere you can see it from.
- "objects": everything you have ever seen, with world x,y and how many ticks ago.
- "agent": your x, y, which way you face, and what you are carrying (at most one).

GLYPHS
  .  floor      #  wall        ~  LAVA - stepping on it ends the task
  G  goal       k  key         o  ball        b  box
  D  open door  d  closed door L  locked door (needs a key of the SAME COLOUR)
  A  you        ?  never seen

WHAT YOU SEND
One JSON object with up to 24 actions. They run one per tick, in order, and then
you are asked again. Anything past 24 ticks of movement is CUT OFF - re-issue it
next turn.
NEVER send a turn whose only action is a goto you are unsure of. Follow every
goto with two or three "forward" and one "right", so the turn still moves and
still looks somewhere new even if the goto stops short.
  {"do":"forward"}  step into the cell ahead (walls and closed doors stop you)
  {"do":"left"} {"do":"right"}   turn 90 degrees
  {"do":"pickup"}   take the object in the cell AHEAD (you must be empty-handed)
  {"do":"drop"}     put what you carry into the cell AHEAD (it must be floor)
  {"do":"toggle"}   open/close the door AHEAD; a LOCKED door opens only if you are
                    carrying a key of the same colour; a box opens into its contents
  {"do":"wait"}     waste a tick
  {"do":"face","dir":"E"}      turn to face east/south/west/north
  {"do":"goto","x":6,"y":3}    WALK THERE. This is your main action. It finds the
                    shortest path through cells you have ALREADY SEEN and stops
                    facing the target if the target is a door or an object, or
                    standing on it if it is floor or the goal. It never walks
                    through ? cells or lava, so if the target is still ? it walks
                    you AS CLOSE AS IT CAN and turns you toward it - that is a
                    "partial" walk, and it is the right way to explore: aim at the
                    unknown and re-issue the same goto next turn. "unreachable"
                    means it could not move you at all; when you see it, goto a
                    SEEN floor cell next to the ? region instead.

RULES THAT KILL YOU
Stepping on ~ ends the task immediately. Walking into a grey ball that moves ends
the task immediately. Nothing else can kill you.

HOW YOU ARE SCORED
Only how many of the five tasks you SOLVE. Partial progress on a task you fail is
the tie-break, and solving fast is the tie-break after that. A task you never even
started scores nothing, so never stall.

REPLY FORMAT
Reply with ONE JSON object and NOTHING else. Your reply MUST begin with the
character { and end with }. No prose, no markdown, no code fences.
{"actions":[{"do":"goto","x":6,"y":3},{"do":"toggle"}],"say":"<=140 chars","notes":"<=300 chars"}
"""

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how
  ## much weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  ## The user message: the operator's guidance, a blank line, then the seat's
  ## observation. The observation is built server-side (see sim_state.nim).
  operatorBlock(operatorPrompt) & viewJson

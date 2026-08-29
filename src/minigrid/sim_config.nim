## `GameConfig` lifecycle: the defaults, `config.update` (the resolved config
## JSON a replay carries and re-derives from), and the validators the design's
## deadlines are chosen to satisfy.
##
## Forked from `coworld-ctf/src/ctf/sim_config.nim`, keeping its validator set:
## whole-second `attempt1Ms` / `retryMs` (curly hands the deadline to
## CURLOPT_TIMEOUT, whose granularity is WHOLE SECONDS, so a config that is
## not a whole number of seconds is not the deadline it claims to be),
## `attempt1Ms + retryMs <= turnBudgetMs`, and a positive
## `wallClockBudgetSeconds`.

import std/[json, strutils]
import sim_types

type
  PlayerSlot* = object
    name*: string

  GameConfig* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    seed*: int
    variant*: string
    numAgents*: int
    minPlayers*: int
    players*: seq[PlayerSlot]
    slots*: seq[int]
    tokens*: seq[string]

    gridSize*: int
    viewSize*: int
    turnTicks*: int
    taskTurnCap*: int
    taskCount*: int
    taskLadder*: seq[string]
    maxTurns*: int
    maxTicks*: int
    parTasks*: int
    obstacleCount*: int
    xlandRules*: int
    xlandObjects*: int
    babyaiObjects*: int
    maxActionsPerTurn*: int
    macroPrimitiveCap*: int
    spinTurns*: int

    attempt1Ms*: int
    retryMs*: int
    turnBudgetMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    lobbyJoinTimeoutTicks*: int
    gameOverTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    model*: string
    maxOutputTokens*: int

  ConfigError* = object of ValueError

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    variant: "gauntlet",
    numAgents: LaneCount,
    minPlayers: LaneCount,
    players: @[PlayerSlot(name: "Alpha"), PlayerSlot(name: "Beta"),
               PlayerSlot(name: "Gamma"), PlayerSlot(name: "Delta")],
    slots: @[0, 1, 2, 3],
    tokens: @[],
    gridSize: GridSize,
    viewSize: ViewSize,
    turnTicks: 24,
    taskTurnCap: 6,
    taskCount: 5,
    taskLadder: @["lavagap", "doorkey", "multiroom", "keycorridor", "babyai"],
    maxTurns: 30,
    maxTicks: 720,
    parTasks: 3,
    obstacleCount: 6,
    xlandRules: 3,
    xlandObjects: 6,
    babyaiObjects: 6,
    maxActionsPerTurn: 24,
    macroPrimitiveCap: 40,
    spinTurns: 24,
    attempt1Ms: 11000,
    retryMs: 6000,
    turnBudgetMs: 17000,
    turnSpacingMs: 11000,
    wallClockBudgetSeconds: 660,
    lobbyJoinTimeoutTicks: 2400,
    gameOverTicks: 480,
    fastMode: true,
    showPlayerLabels: false,
    model: "",
    maxOutputTokens: 900
  )

proc readInt(node: JsonNode, key: string, target: var int) =
  let value = node{key}
  if value.isNil: return
  case value.kind
  of JInt: target = int(value.getBiggestInt())
  of JFloat: target = int(value.getFloat())
  of JString:
    try: target = parseInt(value.getStr().strip())
    except ValueError: discard
  else: discard

proc readBool(node: JsonNode, key: string, target: var bool) =
  let value = node{key}
  if value.isNil: return
  case value.kind
  of JBool: target = value.getBool()
  of JInt: target = value.getBiggestInt() != 0
  else: discard

proc readStr(node: JsonNode, key: string, target: var string) =
  let value = node{key}
  if value.isNil or value.kind != JString: return
  target = value.getStr()

proc validate*(config: GameConfig) =
  ## The validators the shipped numbers are chosen to satisfy. Each is a
  ## scar: a sub-second deadline is not the deadline it claims to be, and an
  ## unbounded wall clock is an episode the platform silently discards.
  if config.attempt1Ms <= 0 or config.attempt1Ms mod 1000 != 0:
    raise newException(ConfigError,
      "attempt1Ms must be a positive WHOLE number of seconds (curly hands " &
      "the deadline to CURLOPT_TIMEOUT, whose granularity is seconds); got " &
      $config.attempt1Ms)
  if config.retryMs <= 0 or config.retryMs mod 1000 != 0:
    raise newException(ConfigError,
      "retryMs must be a positive WHOLE number of seconds; got " &
      $config.retryMs)
  if config.attempt1Ms + config.retryMs > config.turnBudgetMs:
    raise newException(ConfigError,
      "attempt1Ms + retryMs must fit inside turnBudgetMs; got " &
      $config.attempt1Ms & " + " & $config.retryMs & " > " &
      $config.turnBudgetMs)
  if config.wallClockBudgetSeconds <= 0:
    raise newException(ConfigError,
      "wallClockBudgetSeconds must be positive")
  if config.numAgents != LaneCount:
    raise newException(ConfigError,
      "minigrid seats FOUR isolated lanes: num_agents must be " &
      $LaneCount & ", got " & $config.numAgents)
  if config.gridSize != GridSize or config.viewSize != ViewSize:
    raise newException(ConfigError,
      "gridSize/viewSize are pinned at " & $GridSize & "/" & $ViewSize)
  if config.taskCount <= 0 or config.taskLadder.len != config.taskCount:
    raise newException(ConfigError,
      "taskLadder must carry exactly taskCount entries; got " &
      $config.taskLadder.len & " for taskCount " & $config.taskCount)
  if config.maxTurns != config.taskCount * config.taskTurnCap:
    raise newException(ConfigError,
      "maxTurns must equal taskCount * taskTurnCap")
  if config.maxTicks != config.maxTurns * config.turnTicks:
    raise newException(ConfigError,
      "maxTicks must equal maxTurns * turnTicks")
  ## The xland rule sampler needs four distinct objects on the board and three
  ## unused (type, colour) pairs left over for the chained triple; below that
  ## it returns an EMPTY rule set and `generateXland` reads `rules[^1]`. The
  ## manifest's config_schema carries the same bounds; this is the check for
  ## every other way a config arrives (a replay's config JSON, a direct
  ## construction, a hand-run container).
  if config.xlandRules != 3:
    raise newException(ConfigError,
      "xlandRules is the chained triple and must be 3; got " &
      $config.xlandRules)
  if config.xlandObjects < 4 or config.xlandObjects > 8:
    raise newException(ConfigError,
      "xlandObjects must be between 4 and 8 (the rule sampler draws four " &
      "distinct board objects and three unused pairs); got " &
      $config.xlandObjects)

proc update*(config: var GameConfig, configJson: string) =
  ## Applies the resolved config JSON (the runner's, or the one a replay
  ## carries). Unknown keys are ignored; every known key is read through the
  ## tolerant readers above so a stringified integer from a runner never
  ## silently resets a rule constant to its default.
  if configJson.strip().len == 0:
    return
  var node: JsonNode
  try:
    node = parseJson(configJson)
  except CatchableError as error:
    raise newException(ConfigError, "bad game config JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(ConfigError, "game config must be a JSON object")

  node.readInt("seed", config.seed)
  node.readStr("variant", config.variant)
  node.readInt("num_agents", config.numAgents)
  node.readInt("numAgents", config.numAgents)
  node.readInt("minPlayers", config.minPlayers)
  node.readInt("gridSize", config.gridSize)
  node.readInt("viewSize", config.viewSize)
  node.readInt("turnTicks", config.turnTicks)
  node.readInt("taskTurnCap", config.taskTurnCap)
  node.readInt("taskCount", config.taskCount)
  node.readInt("maxTurns", config.maxTurns)
  node.readInt("maxTicks", config.maxTicks)
  node.readInt("parTasks", config.parTasks)
  node.readInt("obstacleCount", config.obstacleCount)
  node.readInt("xlandRules", config.xlandRules)
  node.readInt("xlandObjects", config.xlandObjects)
  node.readInt("babyaiObjects", config.babyaiObjects)
  node.readInt("maxActionsPerTurn", config.maxActionsPerTurn)
  node.readInt("macroPrimitiveCap", config.macroPrimitiveCap)
  node.readInt("spinTurns", config.spinTurns)
  node.readInt("attempt1Ms", config.attempt1Ms)
  node.readInt("retryMs", config.retryMs)
  node.readInt("turnBudgetMs", config.turnBudgetMs)
  node.readInt("turnSpacingMs", config.turnSpacingMs)
  node.readInt("wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  node.readInt("lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  node.readInt("gameOverTicks", config.gameOverTicks)
  node.readBool("fastMode", config.fastMode)
  node.readBool("showPlayerLabels", config.showPlayerLabels)
  node.readStr("model", config.model)
  node.readInt("maxOutputTokens", config.maxOutputTokens)

  let ladder = node{"taskLadder"}
  if not ladder.isNil and ladder.kind == JArray:
    config.taskLadder = @[]
    for item in ladder:
      if item.kind == JString:
        config.taskLadder.add(item.getStr())

  let players = node{"players"}
  if not players.isNil and players.kind == JArray:
    config.players = @[]
    for item in players:
      if item.kind == JObject:
        config.players.add(PlayerSlot(
          name: item{"name"}.getStr(seatAlias(config.players.len))))
      elif item.kind == JString:
        config.players.add(PlayerSlot(name: item.getStr()))

  let tokens = node{"tokens"}
  if not tokens.isNil and tokens.kind == JArray:
    config.tokens = @[]
    for item in tokens:
      if item.kind == JString:
        config.tokens.add(item.getStr())

  let slots = node{"slots"}
  if not slots.isNil and slots.kind == JArray:
    config.slots = @[]
    for item in slots:
      if item.kind == JInt:
        config.slots.add(int(item.getBiggestInt()))

  if config.players.len == 0:
    for slot in 0 ..< max(1, config.numAgents):
      config.players.add(PlayerSlot(name: seatAlias(slot)))
  config.validate()

proc resolvedJson*(config: GameConfig): string =
  ## The config JSON written into the replay header. It carries EVERY rule
  ## constant, the seed, the variant and the real player names, which is what
  ## makes the replay bytes self-sufficient: the viewer re-generates every
  ## layout, mission sentence and hidden rule table from this plus the code.
  ## `tokens` is deliberately absent — a replay is a public artifact.
  var players = newJArray()
  for slot in config.players:
    players.add(%*{"name": slot.name})
  var ladder = newJArray()
  for family in config.taskLadder:
    ladder.add(%family)
  var slots = newJArray()
  for slot in config.slots:
    slots.add(%slot)
  $(%*{
    "seed": config.seed,
    "variant": config.variant,
    "num_agents": config.numAgents,
    "minPlayers": config.minPlayers,
    "players": players,
    "slots": slots,
    "gridSize": config.gridSize,
    "viewSize": config.viewSize,
    "turnTicks": config.turnTicks,
    "taskTurnCap": config.taskTurnCap,
    "taskCount": config.taskCount,
    "taskLadder": ladder,
    "maxTurns": config.maxTurns,
    "maxTicks": config.maxTicks,
    "parTasks": config.parTasks,
    "obstacleCount": config.obstacleCount,
    "xlandRules": config.xlandRules,
    "xlandObjects": config.xlandObjects,
    "babyaiObjects": config.babyaiObjects,
    "maxActionsPerTurn": config.maxActionsPerTurn,
    "macroPrimitiveCap": config.macroPrimitiveCap,
    "spinTurns": config.spinTurns,
    "attempt1Ms": config.attempt1Ms,
    "retryMs": config.retryMs,
    "turnBudgetMs": config.turnBudgetMs,
    "turnSpacingMs": config.turnSpacingMs,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "gameOverTicks": config.gameOverTicks,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels
  })

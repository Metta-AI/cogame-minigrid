## The mummy HTTP/websocket server implementing the Coworld contract.
##
## Forked from `coworld-ctf/src/ctf/server.nim` with the THREE NAMED EDITS of
## the design note:
##
## 1. TURN BOUNDARY — unchanged in shape, with a variable turn length (the
##    tick loop breaks early when a task finishes) and ONE seat in the batch.
## 2. REGISTRATION INTERCEPTION — the seat's Sprite v1 chat message whose text
##    parses as a registration object is consumed as REGISTRATION, not applied
##    as a shout and not written to the replay chat stream; the server writes a
##    REDACTED `register` record instead (policy label and kind, never the
##    prompt). The server LOGS LOUDLY AND REFUSES TO START the game when the
##    joined seat has no register record (the grf-football silent-default scar).
## 3. WALL-CLOCK STOP — the starter's `wallClockBudgetSeconds` check at the top
##    of every loop iteration, kept, forcing GameOver / reason `deadline` /
##    endRule `wallClock`, and written as a LOAD-BEARING stop record so the
##    hash chain stays clean at the stop tick (the particle-worlds scar).
##
## The certifier's browser probes are served for real and registered BEFORE any
## catch-all asset route: `GET /client/player?slot=&token=` (token-checked, and
## it must NOT open the player socket), `GET /client/global`, the `/global`
## websocket's first message, and `/healthz` — all kept answering for the
## `gameOverTicks` grace after artifacts are written (the lantern scars). The
## player websocket handler CLOSES unless the token matches the seat (the
## certifier probes with a bad token — cogame-flatland 0.1.1). Global
## broadcasts are fire-and-forget so a slow viewer can never stall the episode.

import
  std/[json, locks, monotimes, os, strutils, tables, times],
  bitworld/client as bitworldClient,
  bitworld/spriteprotocol, bitworld/runtime,
  mummy,
  sim, replays, broadcast, replay_runtime, events, wire_constants,
  driver, directives, baselines, decide
import global as board

const
  HealthPath = "/healthz"
  PlayerWebSocketPath = "/player"
  GlobalWebSocketPath = "/global"
  ReplayWebSocketPath = "/replay"
  ReplayDataPath = "/replay-data"
  BroadcastFontPath = "/font.ttf"
  WallTextureHorizontalPath = "/art/walls/wall_h.jpg"
  WallTextureVerticalPath = "/art/walls/wall_v.jpg"

  EmbeddedBroadcastReplayHtml = staticRead("../../client/replay_broadcast.html")
  EmbeddedChromeCommonJs = staticRead("../../client/chrome_common.js")
  EmbeddedBroadcastCoreJs = staticRead("../../client/broadcast_core.js")
  BroadcastFont = staticRead("../../data/font.ttf")
  WallTextureHorizontal = staticRead("../../client/art/walls/wall_h.jpg")
  WallTextureVertical = staticRead("../../client/art/walls/wall_v.jpg")
  LockerRoomAssets = [
    ("/art/lockerroom/bg.jpg", staticRead("../../client/art/lockerroom/bg.jpg")),
    ("/art/lockerroom/red_1.webp",
     staticRead("../../client/art/lockerroom/red_1.webp")),
    ("/art/lockerroom/red_2.webp",
     staticRead("../../client/art/lockerroom/red_2.webp")),
    ("/art/lockerroom/red_3.webp",
     staticRead("../../client/art/lockerroom/red_3.webp")),
    ("/art/lockerroom/red_5.webp",
     staticRead("../../client/art/lockerroom/red_5.webp")),
    ("/art/lockerroom/red_6.webp",
     staticRead("../../client/art/lockerroom/red_6.webp"))
  ]

type
  AppState = object
    lock: Lock
    config: GameConfig
    replayLoaded: bool
    globalViewers: Table[WebSocket, board.GlobalViewerState]
    playerViewers: Table[WebSocket, board.PlayerViewerState]
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    playerNames: Table[WebSocket, string]
    chatMessages: Table[WebSocket, string]
    inputMasks: Table[WebSocket, uint8]
    pressedMasks: Table[WebSocket, uint8]
    closedSockets: seq[WebSocket]

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

var appState: AppState
appState.lock.initLock()

proc spliceClientPage(page: string): string =
  ## The served page carries its chrome inline: the wire constants, the
  ## byte-identical `chrome_common.js` and the forked `broadcast_core.js` are
  ## spliced into the markers the page ships with, exactly as the starter does
  ## it, so a locally served page and the static bundle run the same code.
  result = page.spliceWireConstants()
  result = result.replace("<!-- CHROME_COMMON -->",
    "<script>" & EmbeddedChromeCommonJs & "</script>")
  result = result.replace("<!-- BROADCAST_CORE -->",
    "<script>" & EmbeddedBroadcastCoreJs & "</script>")

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Upgrade"].toLowerAscii() == "websocket"

proc playerSlot(request: Request): int =
  try: parseInt(request.queryParams.getOrDefault("slot", "0"))
  except ValueError: -1

proc playerToken(request: Request): string =
  request.queryParams.getOrDefault("token", "")

proc tokenMatches(config: GameConfig, slot: int, token: string): bool =
  ## The certifier probes with a WRONG token and requires the socket to close
  ## (cogame-flatland 0.1.1). An episode whose runner injected no tokens at
  ## all accepts any token, which is what lets a local `tmp/run_e2e.sh` work.
  if slot < 0 or slot >= max(1, config.numAgents):
    return false
  if config.tokens.len <= slot or config.tokens[slot].len == 0:
    return true
  config.tokens[slot] == token

proc respondForbidden(request: Request, reason: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  request.respond(403, headers, reason & "\n")

proc disconnectWebSocket(websocket: WebSocket) =
  try:
    websocket.close()
  except CatchableError:
    discard

proc httpHandler(request: Request) {.gcsafe.} =
  ## Route order is load-bearing: every certifier probe is registered BEFORE
  ## the catch-all.
  if request.path == HealthPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, "healthy")
  elif request.path == PlayerWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      slot = request.playerSlot()
      token = request.playerToken()
    var ok = false
    {.gcsafe.}:
      withLock appState.lock:
        ok = appState.config.tokenMatches(slot, token)
    if not ok:
      ## CLOSE unless the token matches the seat.
      request.respondForbidden("bad player slot or token")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerSlots[websocket] = slot
        appState.playerTokens[websocket] = token
        appState.playerViewers[websocket] = board.PlayerViewerState()
        appState.inputMasks[websocket] = 0
        appState.pressedMasks[websocket] = 0
    echo "minigrid: player connected on slot ", slot
  elif request.path in [GlobalWebSocketPath, ReplayWebSocketPath] and
      request.httpMethod == "GET" and request.isWebSocketUpgrade():
    if request.queryParams.getOrDefault("token", "").len > 0:
      request.respondForbidden("viewer sockets take no player credentials")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = board.initGlobalViewerState()
  elif request.path == bitworldClient.PlayerClientRoute and
      request.httpMethod == "GET":
    ## The certifier fetches this with slot+token and requires a real page.
    ## It must NOT open the player socket.
    let
      slot = request.playerSlot()
      token = request.playerToken()
    var ok = true
    {.gcsafe.}:
      withLock appState.lock:
        if request.queryParams.getOrDefault("token", "").len > 0:
          ok = appState.config.tokenMatches(slot, token)
    if not ok:
      request.respondForbidden("bad player slot or token")
      return
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers,
      "<!doctype html><meta charset=\"utf-8\"><title>minigrid seat</title>" &
      "<body style=\"background:#14120f;color:#f2e8d8;font:14px system-ui\">" &
      "<h1>minigrid</h1><p>Seat " & $slot & " is driven by its policy " &
      "container over <code>/player?slot=&amp;token=</code>. " &
      "The spectator view is <a href=\"/client/replay\">/client/replay</a>." &
      "</p></body>")
  elif request.path in [bitworldClient.ReplayClientRoute,
                        bitworldClient.CoworldReplayClientRoute] and
      request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, spliceClientPage(EmbeddedBroadcastReplayHtml))
  elif request.path == BroadcastFontPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "font/ttf"
    headers["Cache-Control"] = "public, max-age=3600"
    request.respond(200, headers, BroadcastFont)
  elif request.path in [WallTextureHorizontalPath, WallTextureVerticalPath] and
      request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "image/jpeg"
    headers["Cache-Control"] = "public, max-age=3600"
    request.respond(200, headers,
      if request.path == WallTextureHorizontalPath: WallTextureHorizontal
      else: WallTextureVertical)
  elif request.path == ReplayDataPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "application/octet-stream"
    request.respond(404, headers, "")
  elif request.httpMethod == "GET" and (block:
      var hit = false
      for (path, art) in LockerRoomAssets:
        if request.path == path:
          hit = true
          break
      hit):
    var headers: HttpHeaders
    headers["Content-Type"] =
      if request.path.endsWith(".webp"): "image/webp" else: "image/jpeg"
    headers["Cache-Control"] = "public, max-age=3600"
    for (path, art) in LockerRoomAssets:
      if request.path == path:
        request.respond(200, headers, art)
        break
  elif bitworldClient.serveClientRoute(request,
                                       bitworldClient.GlobalClientRoute):
    discard
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "minigrid server")

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
                      message: Message) {.gcsafe.} =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    ## The Ping -> Pong branch, and NOTHING else guarded: a `kind !=
    ## TextMessage` guard would drop the seat's BINARY registration frames
    ## (lux-ai 0.1.0, snake-royale 0.1.0).
    if message.kind == Ping:
      websocket.send(message.data, Pong)
    elif message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.globalViewers:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data)
          elif websocket in appState.playerViewers:
            var
              mask = appState.inputMasks.getOrDefault(websocket, 0)
              pressed = appState.pressedMasks.getOrDefault(websocket, 0)
              chatText = ""
            appState.playerViewers[websocket].applyPlayerViewerMessage(
              message.data, mask, pressed, chatText)
            appState.inputMasks[websocket] = mask
            appState.pressedMasks[websocket] = pressed
            if chatText.len > 0:
              appState.chatMessages[websocket] =
                appState.chatMessages.getOrDefault(websocket, "") & chatText
  of ErrorEvent, CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc declarePlayerFailure(slot: int, message: string) =
  ## The platform's CLOSED payload — exactly `{"message",
  ## "failed_policy_index"}`, nothing else.
  let uri = getEnv("COGAME_PLAYER_FAILURE_URI")
  if uri.len == 0:
    return
  try:
    writeCogameUri(uri,
      $(%*{"message": message.truncateRunes(MaxStopDetailRunes),
           "failed_policy_index": slot}),
      "application/json", "COGAME_PLAYER_FAILURE_URI")
  except CatchableError as error:
    echo "minigrid: failed to declare player failure: ", error.msg

proc parseRegistration*(text: string): tuple[ok: bool, isLlm: bool,
                                             prompt, label, scripted: string] =
  ## The seat's registration blob:
  ##   {"policy":"<label>","prompt":"<PLAYER_PROMPT>","scripted":"scout"|null}
  ## Consumed as REGISTRATION, never applied as a shout and never written to
  ## the replay chat stream.
  if text.len == 0 or text.strip().len == 0 or text.strip()[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject:
    return
  if not (node.hasKey("policy") or node.hasKey("prompt") or
          node.hasKey("scripted")):
    return
  result.ok = true
  result.label = node{"policy"}.getStr().truncateRunes(MaxPolicyLabelRunes)
  result.prompt = node{"prompt"}.getStr().truncateRunes(MaxPromptRunes)
  let scripted = node{"scripted"}
  if not scripted.isNil and scripted.kind == JString:
    result.scripted = scripted.getStr()
  result.isLlm = result.prompt.strip().len > 0 and result.scripted.len == 0

proc broadcastPacket(packet: seq[uint8], websocket: WebSocket) =
  ## Fire-and-forget: a slow viewer can never stall the episode.
  try:
    websocket.send(blobFromBytes(packet), BinaryMessage)
  except CatchableError:
    discard

proc runServerLoop*() =
  ## The whole episode: lobby, turns, artifacts, a bounded shutdown grace.
  var config = defaultGameConfig()
  let configUri = getEnv("COGAME_CONFIG_URI")
  if configUri.len > 0:
    config.update(readCogameUri(configUri, "COGAME_CONFIG_URI"))
  else:
    let inline = getEnv("COGAME_CONFIG")
    if inline.len > 0:
      config.update(inline)
  ## The seed is randomised HERE, before any seed-derived draw, so every draw
  ## follows the FINAL seed (the starter's rule).
  if config.seed == 0:
    config.seed = int(getTime().toUnixFloat() * 1000) and 0x7fffffff
  config.validate()

  withLock appState.lock:
    appState.config = config

  var sim = initSimServer(config)
  var engine = initDecisionEngine(sim)

  let
    ## Both spellings: the platform's episode runner sets HOST/PORT and the
    ## shared tools/ci/docker_smoke.sh sets COGAME_HOST/COGAME_PORT.
    host = getEnv("COGAME_HOST", getEnv("HOST", "0.0.0.0"))
    port = try: parseInt(getEnv("COGAME_PORT", getEnv("PORT", "8080")))
           except ValueError: 8080
  var httpServer = newServer(httpHandler, websocketHandler)
  var thread: Thread[ServerThreadArgs]
  createThread(thread, serverThreadProc,
    ServerThreadArgs(server: httpServer.addr, address: host, port: port))
  echo "minigrid: serving on ", host, ":", port, " seed ", config.seed,
    " variant ", config.variant

  var replayWriter: ReplayWriter
  let replayPath = "/tmp/minigrid-" & $config.seed & ".replay"
  try:
    replayWriter = openReplayWriter(replayPath, config.resolvedJson())
  except CatchableError as error:
    echo "minigrid: replay writer unavailable: ", error.msg

  var
    eventRows: seq[string]
    started = getMonoTime()
    joinedSlots: Table[int, bool]
    registered = false
    faultDetail = ""

  proc elapsedSeconds(): int = (getMonoTime() - started).inSeconds.int

  proc writeChat(record: string, atTick = -1) =
    if replayWriter.enabled:
      try:
        replayWriter.writeChat(
          tickTime(if atTick >= 0: atTick else: sim.tickCount), 0, record)
      except CatchableError:
        discard
    sim.pushFeedDirective(record)

  proc broadcastFrame(events: JsonNode) =
    var sockets: seq[WebSocket]
    withLock appState.lock:
      for websocket in appState.globalViewers.keys:
        sockets.add(websocket)
      for websocket in sockets:
        var next: board.GlobalViewerState
        var packet = board.buildSpriteProtocolUpdates(
          sim, appState.globalViewers[websocket], next,
          sim.tickCount, true, 1, sim.effectiveMaxTicks(), false, false, -1)
        appState.globalViewers[websocket] = next
        packet.addChrome(sim.buildStateJson(events, true, 1,
          sim.effectiveMaxTicks(), false, false, -1, -1))
        broadcastPacket(packet, websocket)

  proc drainSockets() =
    ## Joins, registrations and disconnects, once per tick.
    withLock appState.lock:
      for websocket, slot in appState.playerSlots.pairs:
        if joinedSlots.getOrDefault(slot, false):
          continue
        let name = appState.playerNames.getOrDefault(websocket, "")
        let token = appState.playerTokens.getOrDefault(websocket, "")
        let seatName = if name.len > 0: name else: "seat-" & $slot
        if sim.addPlayer(seatName, slot, token, trusted = true) >= 0:
          joinedSlots[slot] = true
      var handled: seq[WebSocket]
      for websocket, text in appState.chatMessages.pairs:
        handled.add(websocket)
        let slot = appState.playerSlots.getOrDefault(websocket, -1)
        if slot < 0:
          continue
        let parsed = parseRegistration(text)
        if not parsed.ok:
          ## Any other chat text from the seat is DROPPED — the cog speaks
          ## through `say`.
          continue
        var label = parsed.label
        if label.len == 0:
          label = if parsed.isLlm: "llm" else: parsed.scripted
        if slot < engine.seats.len:
          engine.seats[slot].isLlm = parsed.isLlm
          engine.seats[slot].prompt = parsed.prompt
          engine.seats[slot].baseline = parseBaseline(parsed.scripted)
          engine.seats[slot].label = label
          engine.seats[slot].registered = true
        for entry in sim.players.mitems:
          if entry.slot == slot:
            entry.name = (if label.len > 0: label else: entry.name)
            entry.policy = label
            entry.kind = (if parsed.isLlm: "llm" else: "scripted")
            entry.registered = true
        if slot < sim.policyKinds.len:
          sim.policyKinds[slot] = (if parsed.isLlm: "llm" else: "scripted")
        registered = true
        ## The JOIN record carries the seat's REAL policy name, which is only
        ## known once it registers — so it is written here, at the same tick
        ## as the redacted `register` record, and playback replays both in
        ## that order.
        if replayWriter.enabled:
          try:
            replayWriter.writeJoin(tickTime(sim.tickCount), slot,
              (if label.len > 0: label else: "seat-" & $slot), slot,
              appState.playerTokens.getOrDefault(websocket, ""))
          except CatchableError:
            discard
        writeChat(registerRecord(slot, seatAlias(slot), label,
          (if parsed.isLlm: "llm" else: "scripted"),
          (if parsed.isLlm: "" else: $parseBaseline(parsed.scripted))))
        echo "minigrid: seat ", slot, " registered as ", label, " (",
          (if parsed.isLlm: "llm" else: "scripted"), ")"
      for websocket in handled:
        appState.chatMessages.del(websocket)
      for websocket in appState.closedSockets:
        let slot = appState.playerSlots.getOrDefault(websocket, -1)
        if slot >= 0 and slot < sim.deadSeats.len:
          sim.deadSeats[slot] = true
        appState.playerSlots.del(websocket)
        appState.playerViewers.del(websocket)
        appState.globalViewers.del(websocket)
      appState.closedSockets.setLen(0)

  proc recordHash() =
    if replayWriter.enabled:
      try:
        replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())
      except CatchableError:
        discard

  let tickSeconds = 1.0 / float(TargetFps)
  var nextTick = getMonoTime()

  try:
    while sim.phase != GameOver:
      ## EDIT 3: the wall-clock stop, at the top of every loop iteration.
      if elapsedSeconds() >= config.wallClockBudgetSeconds:
        sim.applyStop(edWallClock,
          "wall clock budget of " & $config.wallClockBudgetSeconds &
          "s reached")
        break

      drainSockets()

      if sim.phase == Lobby:
        let wasLobby = true
        sim.step()
        recordHash()
        var events = newJArray()
        var tracker = initBroadcastTracker()
        sim.stepEvents(tracker, events)
        broadcastFrame(events)
        if sim.phase == Playing and joinedSlots.len > 0 and not registered:
          ## EDIT 2, second half: the seat joined and the lobby ran out
          ## without a register record. LOG LOUDLY AND REFUSE TO START — a
          ## silent default would report a champion as scripted (the
          ## grf-football 2026-08-27 scar).
          echo "minigrid: FATAL — the joined seat sent no register record; ",
            "refusing to start the game (a silent default would report a ",
            "champion as scripted)"
          declarePlayerFailure(0, "seat joined but never registered")
          sim.applyStop(edFault, "seat joined but never registered")
          break
        if wasLobby and sim.phase == Playing and joinedSlots.len == 0:
          ## A seat that never connects does NOT end the episode: the gauntlet
          ## runs to its natural end driven by `scout`, with the seat marked
          ## dead and ONE closed-schema failure payload reported.
          echo "minigrid: no seat connected inside the lobby window; the ",
            "gauntlet plays out on the scout baseline"
          declarePlayerFailure(0, "seat never connected")
          sim.deadSeats[0] = true
        ## THE LOBBY ALWAYS PACES IN WALL CLOCK, fastMode or not: it is a wait
        ## for a container to dial in, not a simulation. Without this the
        ## whole episode completes in milliseconds before the player process
        ## has finished its first connect retry.
        nextTick = nextTick + initDuration(
          nanoseconds = int(tickSeconds * 1_000_000_000))
        let now = getMonoTime()
        if nextTick > now:
          sleep((nextTick - now).inMilliseconds.int)
        continue

      ## EDIT 1: the turn boundary. ONE seat, so this is a batch of one.
      if sim.waitingForPlan():
        sim.advanceTasks()
        if sim.phase != Playing:
          break
        let turnIndex = sim.turnsPlayed + 1
        let observation = sim.observationJson(includeNotes = false)
        let decision = engine.turn(sim, turnIndex, elapsedSeconds())
        for record in decision.records:
          writeChat(record)
        let record = sim.applyDirective(decision.directive, observation)
        writeChat(record)

      var events = newJArray()
      var tracker = initBroadcastTracker()
      let before = sim.queue
      sim.step()
      if before.len > 0 and sim.executed.len > 0 and
          getEnv("COGAME_EVENTS_URI").len > 0:
        eventRows.add(sim.primitiveRow(sim.executed[^1]))
      recordHash()
      for event in sim.pending:
        if getEnv("COGAME_EVENTS_URI").len > 0:
          let row = sim.eventRow(event)
          if row.len > 0: eventRows.add(row)
      sim.stepEvents(tracker, events)
      broadcastFrame(events)

      if not config.fastMode:
        nextTick = nextTick + initDuration(
          nanoseconds = int(tickSeconds * 1_000_000_000))
        let now = getMonoTime()
        if nextTick > now:
          sleep((nextTick - now).inMilliseconds.int)
  except CatchableError as error:
    ## A defect: caught, the episode is settled from the last completed tick
    ## and artifacts are still written. `docker_smoke.sh` fails the build if
    ## the smoke episode reports it.
    faultDetail = error.msg.truncateRunes(MaxStopDetailRunes)
    echo "minigrid: FAULT — ", faultDetail
    sim.applyStop(edFault, faultDetail)

  if sim.phase != GameOver:
    sim.finish(erComplete, edGauntletComplete)

  ## THE LOAD-BEARING STOP RECORD, for EVERY end reason — not just the
  ## wall-clock one. It is written at the LAST SIMULATED TICK and applied on
  ## playback by the SAME proc (`sim.applyStop`) at the start of the step that
  ## follows that tick — exactly where the live loop settles — so record and
  ## re-derive agree bit for bit at the stop tick (the particle-worlds
  ## 2026-08-26 scar). One more tick is then stepped and hashed from the
  ## SETTLED state, which is what gives playback a tick to apply it on.
  writeChat(stopRecord(sim.tickCount, sim.endRule,
    (if faultDetail.len > 0: faultDetail else: sim.stopDetail)))
  sim.step()
  recordHash()

  let results = sim.gauntletResultsJson()
  writeChat(resultRecord(sim))

  try:
    if replayWriter.enabled:
      replayWriter.closeReplayWriter()
  except CatchableError:
    discard

  try:
    let uri = getEnv("COGAME_RESULTS_URI")
    if uri.len > 0:
      writeCogameUri(uri, results, "application/json", "COGAME_RESULTS_URI")
  except CatchableError as error:
    echo "minigrid: failed to write results: ", error.msg
  try:
    let uri = getEnv("COGAME_SAVE_REPLAY_URI")
    if uri.len > 0 and fileExists(replayPath):
      writeCogameUri(uri, readFile(replayPath),
        "application/octet-stream", "COGAME_SAVE_REPLAY_URI")
  except CatchableError as error:
    echo "minigrid: failed to write replay: ", error.msg
  try:
    let uri = getEnv("COGAME_EVENTS_URI")
    if uri.len > 0:
      eventRows.add(sim.summaryRow(eventRows.len))
      writeCogameUri(uri, eventsJsonl(eventRows), "application/x-ndjson",
        "COGAME_EVENTS_URI")
  except CatchableError as error:
    echo "minigrid: failed to write events: ", error.msg

  echo "minigrid: episode complete — reason ", sim.endReason, " endRule ",
    sim.endRule, " solved ", sim.tasksSolved(), "/", config.taskCount,
    " score ", sim.score()

  ## The gameOverTicks hold: `/healthz` and `/global` keep answering for a
  ## BOUNDED grace after artifacts are written (the lantern 0.1.3 `/global`
  ## ping scar), then the process exits 0.
  let holdSeconds = max(1, min(30, config.gameOverTicks div TargetFps))
  for i in 0 ..< holdSeconds * TargetFps:
    var events = newJArray()
    var tracker = initBroadcastTracker()
    sim.step()
    sim.stepEvents(tracker, events)
    broadcastFrame(events)
    sleep(int(1000 / TargetFps))
  quit(0)

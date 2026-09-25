## The minigrid player container: scripted, prompt, or external action policy.
##
## The scripted and prompt modes use the existing game decision path. External
## mode exercises the ordinary player observation/plan path with one fixed
## action, Jev choice, or numeric policy; each uses the same WebSocket messages.
##
##   PLAYER_PROMPT        a strategy in plain English -> this seat is an LLM seat
##   PLAYER_SCRIPTED      scout | bumper             -> this seat is scripted
##   PLAYER_POLICY_LABEL  a free label for the replay's `register` record
##   PLAYER_EXTERNAL      1 to request player-side plans
##   PLAYER_EXTERNAL_ACTION  a fixed action verb for the protocol fixture
##   PLAYER_JEV           1 to rank player-visible plans through System One
##   PLAYER_NUMERIC_URL   HTTP endpoint returning {"choice": int} from numeric
##                        values and action_mask
##   PLAYER_NUMERIC_KEY   optional bearer key for that endpoint
##
## A seat that sets neither is `scout`. To field your own policy, reuse
## this image and set PLAYER_PROMPT:
##
##   coworld upload-policy <minigrid-image> --name my-minigrid \
##     --run /bin/minigrid-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils, sysrand],
  bitworld/spriteprotocol,
  minigrid/jev_policy,
  minigrid/numeric_policy,
  minigrid/sim_types,
  whisky

const
  ConnectAttempts = 240      ## 240 x 500 ms = 2 minutes of dialling.
  ConnectRetryMs = 500
  RegistrationResends = 10   ## re-sends after the first, ~1 s apart.
  ResendEveryFrames = 24     ## ~1 s of frames at 24 Hz.
  ReconnectAttempts = 6      ## 6 x 500 ms of re-dialling after a live socket
                             ## dies, before accepting the game is gone.

proc registrationBlob(prompt, scripted, policy: string,
                      external: bool): string =
  ## The one registration message. `scripted` is JSON null when the seat is
  ## an LLM seat, so the server can tell "no baseline named" from "scout
  ## named explicitly".
  ## Both caps are applied HERE, on RUNE boundaries, before the blob goes on
  ## the wire; the server re-applies them on receipt because a seat container
  ## is not trusted input.
  var node = %*{
    "type": "register",
    "prompt": prompt.truncateRunes(MaxPromptRunes),
    "policy": policy.truncateRunes(MaxPolicyLabelRunes)
  }
  if external:
    node["mode"] = %"external"
  if scripted.len > 0:
    node["scripted"] = %scripted
  else:
    node["scripted"] = newJNull()
  blobFromSpriteChat($node)

proc readyBlob(): string =
  ## The Sprite v1 player-ready packet (0x85). Legitimate here in a way it is
  ## not for an ordinary player client: this seat sends NO inputs at all (the
  ## server computes every actuator mask), so the dead-reckoning hazard
  ## docs/PROTOCOL.md warns about cannot arise, and a fastMode server can
  ## advance the tick as soon as the seat has acknowledged the frame.
  result = newString(1)
  result[0] = char(0x85)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let
    prompt = getEnv("PLAYER_PROMPT").strip()
    scripted = getEnv("PLAYER_SCRIPTED").strip()
    jev = getEnv("PLAYER_JEV") == "1"
    numeric = getEnv("PLAYER_NUMERIC_URL").strip().len > 0
    external = getEnv("PLAYER_EXTERNAL") == "1" or jev or numeric
    externalAction = getEnv("PLAYER_EXTERNAL_ACTION", "wait")
    label = block:
      let explicit = getEnv("PLAYER_POLICY_LABEL").strip()
      if explicit.len > 0: explicit
      elif prompt.len > 0: "prompt"
      elif scripted.len > 0: scripted
      elif jev: "jev"
      elif numeric: "numeric"
      elif external: "external-action"
      else: "scout"
  if external and (prompt.len > 0 or scripted.len > 0):
    quit("PLAYER_EXTERNAL cannot be combined with prompt or scripted", 1)
  if jev and numeric:
    quit("PLAYER_JEV cannot be combined with PLAYER_NUMERIC_URL", 1)
  let numericSession = block:
    var id = ""
    if numeric:
      for value in urandom(16):
        id.add(toHex(int(value), 2))
    id
  echo "minigrid player: kind=",
    (if jev: "jev" elif numeric: "numeric" elif external: "external"
     elif prompt.len > 0: "llm" else: "scripted"),
    " baseline=", (if scripted.len > 0: scripted else: "scout"),
    " label=", label

  proc dial(attempts: int): WebSocket =
    ## Bounded dialling. The game bakes its supersampled board render caches
    ## BEFORE it opens the listener (a viewer's first-message clock starts at
    ## connect, so nothing may be accepted until every frame can be assembled
    ## instantly), and the episode runner starts the players at the same
    ## instant as the game — so the first dial always lands on a closed port.
    for attempt in 0 ..< attempts:
      try:
        return newWebSocket(url)
      except CatchableError as error:
        if attempt == 0:
          echo "minigrid player: game not listening yet (", error.msg,
            "); retrying"
        sleep(ConnectRetryMs)
    nil

  var socket = dial(ConnectAttempts)
  if socket == nil:
    quit("minigrid player: game never accepted a connection", 1)
  echo "minigrid player: connected"

  # Each session is wrapped: whisky's receiveMessage RAISES on a close frame or
  # a truncated read (only a timeout returns none), and mummy's send only
  # QUEUES — so the game's own quit(0) can outrun the flushed frame. A naive
  # player exits 1 on that race and fails certification intermittently
  # (cogame-raid 0.1.3). Exiting 0 on a dead socket is the fix.
  #
  # REGISTRATION IS RE-SENT, NOT SENT ONCE. Joins are slot-sequential, so a
  # seat whose slot is not the next open one is not admitted until the lower
  # slots have joined — and the lobby sends frames to a socket before it is
  # admitted, so the first registration AND a single re-send keyed on the first
  # received frame can both land while the seat has no index yet. The server
  # dropped them and the champion played the scripted baseline for the whole
  # episode (paintball round 3, 2026-08-25). The server now holds an
  # unappliable registration, and this end keeps re-sending it for the first
  # ~10 s of frames, which covers the lobby however late the single seat lands.
  # Registering twice is harmless: the server just re-reads the same fields.
  var reconnects = 0
  while true:
    var sessionFrames = 0
    try:
      socket.send(registrationBlob(prompt, scripted, label, external), BinaryMessage)
      var resends = 0
      while true:
        let received = socket.receiveMessage()
        if received.isNone:
          continue                    ## a read timeout, not a closed socket
        inc sessionFrames
        if resends < RegistrationResends and
            sessionFrames mod ResendEveryFrames == 1:
          inc resends
          socket.send(registrationBlob(prompt, scripted, label, external), BinaryMessage)
        if external and received.get().kind == TextMessage:
          let request = parseJson(received.get().data)
          if request{"type"}.getStr() == "decision":
            doAssert request["observation"]["lane"].kind == JInt
            doAssert request["observation"]["known"].kind == JArray
            let plan =
              if jev: choosePlan(request["observation"],
                request["deadline_ms"].getInt())
              elif numeric: chooseNumericPlan(request, numericSession)
              else: %*{"actions": [{"do": externalAction}]}
            socket.send($( %*{
              "type": "plan",
              "rid": request["rid"],
              "plan": plan
            }), TextMessage)
        socket.send(readyBlob(), BinaryMessage)
    except CatchableError as error:
      echo "minigrid player: socket closed (", error.msg, ")"
    # NEVER exit while the game is still serving: a seat that drops keeps its
    # cogs for the whole episode and revives on reconnect, so a dropped socket
    # mid-episode is worth re-dialling and re-registering. Bounded on both
    # counts — a session that never received a frame means the game is winding
    # down (its shutdown grace still answers the route), and the re-dial is
    # capped — so this can never outlive the game or spin: the runner waits on
    # process exit either way.
    if sessionFrames == 0 or reconnects >= ReconnectAttempts:
      break
    inc reconnects
    echo "minigrid player: re-dialling the seat (attempt ", reconnects, ")"
    socket = dial(ReconnectAttempts)
    if socket == nil:
      echo "minigrid player: game is no longer listening, exiting cleanly"
      break
    echo "minigrid player: reconnected, re-registering"
  quit(0)

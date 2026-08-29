## The decision layer: the per-turn loop that asks every ACTIVE seat what its
## cog does next, and ALWAYS has an answer for every one of them.
##
## Cadence: one turn every `turnTicks` (24) ticks, at most 30 turns per
## episode. THE PER-TURN LLM CALL BUDGET IS EXACTLY ONE REQUEST PER ACTIVE
## SEAT, PLUS AT MOST ONE RETRY EACH — at most 4 requests per batch, at most 8
## per turn, at most `4 x 30 x 2 = 240` provider calls per episode. Seats are
## NEVER queried sequentially: this is a genuinely simultaneous-decision game,
## so all of a turn's calls go out as ONE `curly.makeRequests` batch through
## the starter's unchanged batching path.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms` (18 s), the single retry gets `retryMs` (12 s), and the whole
## turn is wrapped in a monotonic `turnBudgetMs` (30 s) deadline. THE LADDER IS
## SIZED FOR A CONCURRENT BATCH (addendum v2.1): a batch of three measured p90
## 8.6-10.1 s against the single call's 6.0 s, and the design permits four, so
## 18 s is 1.5x the projected four-seat p90 and 12 s is a genuine second
## chance on the much faster retry batch. The worst case is bounded by the
## BUDGET GUARD, not by arithmetic: the guard lets no turn start after 578 s,
## so 578 + 30 + 20 = 628 s < the 660 s stop.
##
## A rolling 60 s request counter skips the call outright when the sidecar's
## per-episode cap is in reach. On a second failure the seat plays the `scout`
## scripted plan for ITS OWN LANE — the SAME PROC the `scout` baseline uses,
## imported, never duplicated — and a `fallback` record names the TRUE cause.
##
## THE CAUSE IS SET AT THE POINT OF FAILURE AND COPIED, NEVER RE-DERIVED. v1
## derived it from the parse step — which is where the ladder lands when there
## is no body to parse — and logged two transport timeouts as `parse_error`
## (VERIFY check 5). EVERY failed attempt of a turn that fell back is counted,
## not just the last: a turn that failed `schema_error` then
## `transport_timeout` records both (addendum v2.1 §2).

import
  std/[json, monotimes, os, strutils, times],
  curly,
  sim, driver, directives, baselines, llm

const
  RateGuardWindowSeconds* = 60
  RateGuardMaxRequests* = 28
    ## The sidecar caps 30 requests/minute PER EPISODE. `turnSpacingMs` pins
    ## the steady state at 4 requests / 11 s = 21.8 req/min; a turn in which
    ## all four seats retry adds four more inside the window (~26 req/min). If
    ## issuing a seat's request would push the trailing-60 s count above this,
    ## that seat skips the call and takes the `scout` plan with cause
    ## `rate_guard`. Bounded, logged, never a sleep on the critical path.

type
  SeatPolicy* = object
    ## What the seat registered as. A seat that registers with neither field —
    ## or never registers at all — is `scout`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    seats*: seq[SeatPolicy]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here on
    requestTimes*: seq[MonoTime]
    lastBatchSize*: int        ## requests in the most recent batch
    lastRequestCount*: int     ## requests this turn, both attempts
    totalRequests*: int        ## requests this episode
    records*: seq[string]      ## chat records queued for the replay writer

  SeatDecision* = object
    slot*: int
    directive*: Directive

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  result.seats = newSeq[SeatPolicy](sim.seatCount())
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blScout
    result.seats[i].label = "scout"

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

# ---------------------------------------------------------------------------
#  Records
# ---------------------------------------------------------------------------

proc fallbackRecord*(turn, slot, attempt: int, cause: FallbackCause,
                     detail: string): string =
  ## ONE record PER ATTEMPT, each with ITS OWN cause — so a replay shows
  ## `transport_timeout, transport_timeout` rather than one mislabelled line.
  $(%*{
    "k": "fallback",
    "turn": turn,
    "slot": slot,
    "attempt": attempt,
    "cause": $cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc registerRecord*(slot: int, alias, policy, kind, baseline: string): string =
  ## The REDACTED registration record. The seat's prompt is NEVER written:
  ## only the policy label, the kind, and which baseline a scripted seat
  ## picked.
  $(%*{
    "k": "register",
    "slot": slot,
    "alias": alias,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

proc stopRecord*(tick: int, rule: EndRule, detail: string): string =
  ## The load-bearing wall-clock/fault stop. A wall-clock fact cannot be
  ## re-derived from sim state, so it is written as ONE record applied by the
  ## SAME proc (`sim.applyStop`) on record and on playback.
  $(%*{"k": "stop", "tick": tick, "endRule": $rule,
       "detail": detail.truncateRunes(MaxStopDetailRunes)})

proc resultRecord*(sim: SimServer): string =
  ## The episode's whole results document, written once into the replay chat
  ## stream at episode end. It is what makes the replay SELF-SUFFICIENT. The
  ## document is already valid JSON, so it is embedded verbatim rather than
  ## re-parsed: nothing on the path to the artifact writes may raise.
  "{\"k\":\"result\",\"results\":" & sim.gauntletResultsJson() & "}"

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc transportCause*(error: string, status: int): FallbackCause =
  ## THE CAUSE OF A FAILED ATTEMPT, decided WHERE IT FAILS. `parse_error` is
  ## only ever reached with a body in hand — a timeout has no body to parse,
  ## which is exactly what v1 mislabelled (VERIFY check 5).
  if error.len > 0:
    if "timeout" in error.toLowerAscii(): fcTransportTimeout
    else: fcTransportError
  elif status >= 400: fcHttpError
  else: fcParseError

proc exceptionCause*(message: string): FallbackCause =
  ## The same decision for a raise out of the client or the parser.
  if message.startsWith("llm transport"):
    (if "timeout" in message.toLowerAscii(): fcTransportTimeout
     else: fcTransportError)
  elif message.startsWith("llm throttled") or
      message.startsWith("llm auth") or
      message.startsWith("anthropic error"): fcHttpError
  else: fcParseError

proc usableReply*(directive: Directive): bool =
  ## A reply is USABLE when it carries an `actions` array or a `say`. A body
  ## that parses but carries neither is a SCHEMA failure, not a parse failure.
  directive.actions.len > 0 or directive.say.len > 0

proc scoutFallback*(sim: SimServer, slot: int, cause: FallbackCause,
                    causes: seq[FallbackCause] = @[]): Directive =
  ## THE fallback plan for ONE lane, computed server-side by the SAME proc the
  ## `scout` baseline uses. `tests/test_minigrid_driver.nim` asserts the two
  ## resolve to one proc so they cannot drift.
  result = scoutPlan(sim.lanes[clamp(slot, 0, sim.lanes.high)], sim.config)
  result.source = dsFallback
  result.cause = cause
  result.causes = (if causes.len > 0: causes else: @[cause])

proc rateGuardCapacity(engine: var DecisionEngine): int =
  ## How many more requests may be issued inside the trailing 60 s window.
  let now = getMonoTime()
  var kept: seq[MonoTime]
  for stamp in engine.requestTimes:
    if (now - stamp).inSeconds.int < RateGuardWindowSeconds:
      kept.add(stamp)
  engine.requestTimes = kept
  max(0, RateGuardMaxRequests - engine.requestTimes.len)

proc noteRequest(engine: var DecisionEngine) =
  engine.requestTimes.add(getMonoTime())
  inc engine.lastRequestCount
  inc engine.totalRequests

proc turn*(engine: var DecisionEngine, sim: var SimServer, turnIndex,
           elapsedSeconds: int): tuple[decisions: seq[SeatDecision],
                                       records: seq[string]] =
  ## Runs ONE decision turn for EVERY active seat and returns their plans plus
  ## the replay chat records the turn produced. NEVER RAISES: every failure
  ## path ends in a legal plan for every seat.
  let
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  ## Throttle state is PER TURN: a 429 on turn k says nothing about turn k+1.
  engine.client.throttled = false
  engine.lastRequestCount = 0
  engine.lastBatchSize = 0

  # --- budget guard: settle EARLY rather than overrun ----------------------
  if not engine.llmOff:
    let turnSeconds = (sim.config.turnBudgetMs + sim.config.turnSpacingMs +
      999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.records.add(budgetGuardRecord(turnIndex,
        max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "minigrid: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted in every lane"

  let seats = sim.activeSeats()
  var open: seq[int]
  var causeOf = newSeq[FallbackCause](sim.lanes.len)
  var causesOf = newSeq[seq[FallbackCause]](sim.lanes.len)
  var have = newSeq[bool](sim.lanes.len)
  var plans = newSeq[Directive](sim.lanes.len)

  var capacity = engine.rateGuardCapacity()
  for slot in seats:
    if slot >= engine.seats.len or not engine.seats[slot].isLlm:
      ## A scripted seat computes locally, instantly, and consumes no request.
      plans[slot] = scriptedPlan(sim.lanes[slot], sim.config,
        engine.seats[slot].baseline)
      have[slot] = true
      continue
    var blocked = true
    if engine.client.disabled or engine.client.transport == ltNone:
      causeOf[slot] = fcNoCredentials
    elif engine.llmOff:
      causeOf[slot] = fcBudgetGuard
    elif capacity <= 0:
      causeOf[slot] = fcRateGuard
    elif sim.deadSeats.len > slot and sim.deadSeats[slot]:
      causeOf[slot] = fcDisconnected
    else:
      blocked = false
    if blocked:
      ## An LLM seat that CANNOT call the LLM this turn is a FALLBACK, not a
      ## scripted policy, and the cause enum names every reason it happens.
      ## Recording it is what makes the two countable.
      causesOf[slot] = @[causeOf[slot]]
      plans[slot] = scoutFallback(sim, slot, causeOf[slot], causesOf[slot])
      have[slot] = true
      result.records.add(fallbackRecord(turnIndex, slot, 1, causeOf[slot],
        "the LLM is unavailable for this turn; playing scout"))
      echo "minigrid llm: seat ", slot, " falling back to scout (",
        causeOf[slot], ") on turn ", turnIndex
      continue
    dec capacity
    open.add(slot)

  if open.len == 0:
    for slot in seats:
      result.decisions.add(SeatDecision(slot: slot, directive: plans[slot]))
    return

  # --- the rate floor ------------------------------------------------------
  ## A floor on the wall clock between consecutive BATCH STARTS, not between
  ## requests: all of a turn's requests leave together.
  if engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  engine.lastBatchStart = getMonoTime()
  engine.batchStarted = true

  var observations = newSeq[string](sim.lanes.len)
  for slot in open:
    observations[slot] = $sim.observationJson(slot, includeNotes = true)

  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    let remainingMs = (budget - (getMonoTime() - turnStart)).inMilliseconds.int
    if remainingMs <= 0:
      for slot in open:
        causeOf[slot] = fcTransportTimeout
        causesOf[slot].add(fcTransportTimeout)
        result.records.add(fallbackRecord(turnIndex, slot, attempt + 1,
          fcTransportTimeout,
          "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    ## turnBudgetMs is a monotonic deadline around the WHOLE turn, the
    ## turnSpacingMs rate floor included, so an attempt is given the SMALLER
    ## of its configured deadline and the time the turn has left.
    let deadlineMs = min(
      (if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs),
      remainingMs)
    ## ONE BATCH, one request per still-open seat. Never a sequential
    ## per-seat loop.
    var batch: RequestBatch
    for slot in open:
      var user = observations[slot]
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{', with an " &
          "\"actions\" array.")
      let request = engine.client.requestFor(
        SystemPrompt, userMessage(engine.seats[slot].prompt, user))
      batch.post(request.url, request.headers, request.body, $slot)
      engine.noteRequest()
    engine.lastBatchSize = max(engine.lastBatchSize, open.len)
    let started = getMonoTime()
    ## curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is
    ## WHOLE SECONDS, so this conversion FLOORS — and sim_config REJECTS a
    ## sub-second value, so the floor is an identity: 11000 -> 11 s,
    ## 6000 -> 6 s, worst case 17 s inside the 17 s turnBudgetMs cap.
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, slot in open:
      ## THE CAUSE IS SET WHERE THE FAILURE HAPPENS. `parse_error` is only
      ## ever reached with a body in hand.
      var cause = fcParseError
      var failed = false
      var detail = ""
      if responses[position].error.len > 0 or
          responses[position].response.code >= 400:
        failed = true
        detail =
          if responses[position].error.len > 0: responses[position].error
          else: "http " & $responses[position].response.code
        cause = transportCause(responses[position].error,
          responses[position].response.code)
      if not failed:
        try:
          let text = engine.client.textOf(
            responses[position].response, responses[position].error,
            batch[position].url)
          let payload = extractJsonObject(text)
          var directive = parseDirective(payload,
            sim.config.maxActionsPerTurn)
          if not directive.usableReply():
            ## The body parsed but carries neither a usable `actions` array
            ## nor a `say`: that is a SCHEMA failure, not a parse failure.
            failed = true
            cause = fcSchemaError
            detail = "reply has neither actions nor say"
          else:
            directive.source = dsLlm
            directive.latencyMs = latency
            if attempt > 0 and causesOf[slot].len > 0:
              ## Attempt 1 failed and attempt 2 SUCCEEDED: that is a RETRIED
              ## turn, counted by `retriedTurns[i]` and deliberately kept OUT
              ## of `fallbackCauses`, which is scoped to turns that fell back.
              directive.retried = true
              directive.firstCause = causesOf[slot][0]
            plans[slot] = directive
            have[slot] = true
        except CatchableError as error:
          failed = true
          detail = error.msg
          cause = exceptionCause(error.msg)
      if failed:
        causeOf[slot] = cause
        causesOf[slot].add(cause)
        result.records.add(
          fallbackRecord(turnIndex, slot, attempt + 1, cause, detail))
        ## Attempt 1 says WILL RETRY. Only a genuine second failure may say
        ## "falling back" — that is the phrase phase 60 greps the game log
        ## for.
        if attempt == 0:
          echo "minigrid llm: seat ", slot, " attempt 1 failed, will retry (",
            cause, "): ", detail
        else:
          echo "minigrid llm: seat ", slot, " attempt 2 failed (", cause,
            "): ", detail
        stillOpen.add(slot)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      ## FAIL FAST. The only model left answered 429, so the retry batch would
      ## be refused the same way.
      echo "minigrid llm: provider throttled with no other candidate; ",
        "the open seats fall back for turn ", turnIndex
      break

  for slot in open:
    plans[slot] = scoutFallback(sim, slot, causeOf[slot], causesOf[slot])
    have[slot] = true
    ## "falling back" is the phrase phase 60 greps the GAME log for, and the
    ## line names BOTH causes when the two attempts failed differently —
    ## reading the summary alone must not hide a malformed reply behind a
    ## later timeout (addendum v2.1 §2).
    var detail = $causeOf[slot]
    if causesOf[slot].len > 1 and causesOf[slot][0] != causeOf[slot]:
      detail.add("; attempt 1: " & $causesOf[slot][0])
    echo "minigrid llm: seat ", slot, " falling back to scout (", detail,
      ") on turn ", turnIndex

  for slot in seats:
    if not have[slot]:
      plans[slot] = scoutFallback(sim, slot, causeOf[slot], causesOf[slot])
    result.decisions.add(SeatDecision(slot: slot, directive: plans[slot]))

proc applyDirective*(sim: var SimServer, slot: int, directive: Directive,
                     view: JsonNode): string =
  ## Turn steps 6 and 7 for ONE seat: expand its plan against ITS OWN lane's
  ## known map, truncate it to `turnTicks`, install it, and return the replay
  ## `directive` record.
  let lane = sim.lanes[clamp(slot, 0, sim.lanes.high)]
  let expansion = expandPlan(lane.knownMap, lane.agent.x, lane.agent.y,
    lane.agent.dir, directive.actions, sim.config.macroPrimitiveCap,
    sim.config.turnTicks)
  ## An entry that fails validation is counted ONCE, in `repliesRepaired`;
  ## `actionsDropped` counts the entries past `maxActionsPerTurn` and nothing
  ## else (design note §Turn structure 6a/6b).
  sim.lanes[slot].repliesRepaired += directive.dropped
  sim.lanes[slot].notes = directive.notes
  let turn = sim.turnsPlayed
  let task = sim.taskIndex
  sim.installLanePlan(slot, expansion.primitives, expansion.truncated,
    directive.overCap, expansion.unreachable, expansion.partial)
  case directive.source
  of dsLlm:
    inc sim.lanes[slot].llmTurns
    if directive.retried:
      inc sim.lanes[slot].retriedTurns
  of dsFallback:
    inc sim.lanes[slot].fallbackTurns
    ## EVERY failed attempt, each under its own cause.
    if directive.causes.len == 0:
      inc sim.lanes[slot].fallbackCauses[directive.cause]
    else:
      for cause in directive.causes:
        inc sim.lanes[slot].fallbackCauses[cause]
  else: discard
  if directive.say.len > 0:
    sim.pending.add(SimEvent(kind: evSay, tick: sim.tickCount, slot: slot,
      a: directive.say))
  boundedDirectiveRecord(directive, turn, task, slot, seatAlias(slot),
    expansion.primitives, expansion.truncated,
    directive.overCap, expansion.unreachable, view, expansion.partial)

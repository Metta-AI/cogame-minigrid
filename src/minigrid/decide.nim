## The decision layer: the per-turn loop that asks the seat what its cog does
## next, and ALWAYS has an answer.
##
## Cadence: one turn every <= `turnTicks` (12) ticks, at most 55 turns per
## episode. There is exactly ONE seat, so the starter's
## one-parallel-batch-per-turn machinery (`curly.makeRequests`) carries a
## batch of one and is otherwise untouched. THE PER-TURN LLM CALL BUDGET IS
## EXACTLY ONE REQUEST, PLUS AT MOST ONE RETRY — at most 110 provider calls
## per episode, and never more than one in flight.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms`, the single retry gets `retryMs`, and the whole turn is
## wrapped in a monotonic `turnBudgetMs` deadline. A rolling 60 s request
## counter skips the call outright when the sidecar's per-episode cap is in
## reach. On a second failure the seat plays the `scout` scripted plan — the
## SAME PROC the `scout` baseline uses, imported, never duplicated — and a
## `fallback` record names the cause.

import
  std/[json, monotimes, os, strutils, times],
  curly,
  sim, driver, directives, baselines, llm

const
  RateGuardWindowSeconds* = 60
  RateGuardMaxRequests* = 28
    ## The sidecar caps 30 requests/minute PER EPISODE. `turnSpacingMs` pins
    ## the steady state at 23 req/min, but a run of retrying turns issues two
    ## each; if issuing the next request would push the trailing-60 s count
    ## above this, the turn skips the call and takes the `scout` plan with
    ## cause `rate_guard`. Bounded, logged, never a sleep on the critical path.

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
    records*: seq[string]      ## chat records queued for the replay writer

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

proc fallbackRecord*(turn, attempt: int, cause, detail: string): string =
  $(%*{
    "k": "fallback",
    "turn": turn,
    "attempt": attempt,
    "cause": cause,
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

proc scoutFallback*(sim: SimServer): Directive =
  ## THE fallback plan, computed server-side by the SAME proc the `scout`
  ## baseline uses. `tests/test_minigrid_driver.nim` asserts the two resolve
  ## to one proc so they cannot drift.
  result = scoutPlan(sim)
  result.source = dsFallback

proc rateGuardBlocked(engine: var DecisionEngine): bool =
  let now = getMonoTime()
  var kept: seq[MonoTime]
  for stamp in engine.requestTimes:
    if (now - stamp).inSeconds.int < RateGuardWindowSeconds:
      kept.add(stamp)
  engine.requestTimes = kept
  engine.requestTimes.len >= RateGuardMaxRequests

proc noteRequest(engine: var DecisionEngine) =
  engine.requestTimes.add(getMonoTime())

proc turn*(engine: var DecisionEngine, sim: var SimServer, turnIndex,
           elapsedSeconds: int): tuple[directive: Directive,
                                       records: seq[string]] =
  ## Runs ONE decision turn for the single seat and returns its plan plus the
  ## replay chat records the turn produced. NEVER RAISES: every failure path
  ## ends in a legal plan.
  let
    seat = 0
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  ## Throttle state is PER TURN: a 429 on turn k says nothing about turn k+1.
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun ----------------------
  if not engine.llmOff:
    let turnSeconds = (sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.records.add(budgetGuardRecord(turnIndex,
        max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "minigrid: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- a scripted seat computes locally, instantly, and consumes no request -
  if not engine.seats[seat].isLlm:
    result.directive = scriptedPlan(sim, engine.seats[seat].baseline)
    return

  var blockedCause = ""
  if engine.client.disabled or engine.client.transport == ltNone:
    blockedCause = "no_credentials"
  elif engine.llmOff:
    blockedCause = "budget_guard"
  elif engine.rateGuardBlocked():
    blockedCause = "rate_guard"
  if blockedCause.len > 0:
    ## An LLM seat that CANNOT call the LLM this turn is a FALLBACK, not a
    ## scripted policy, and the design's `fallback.cause` enum names every
    ## reason it happens. Recording it is what makes the two countable.
    result.directive = scoutFallback(sim)
    result.records.add(fallbackRecord(turnIndex, 1, blockedCause,
      "the LLM is unavailable for this turn; playing scout"))
    echo "minigrid llm: seat ", seat, " falling back to scout (", blockedCause,
      ") on turn ", turnIndex
    return

  # --- the rate floor ------------------------------------------------------
  if engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  engine.lastBatchStart = getMonoTime()
  engine.batchStarted = true

  let observation = sim.observationJson(includeNotes = true)
  var attempt = 0
  var open = true
  while open and attempt < 2:
    if engine.client.disabled:
      break
    let remainingMs = (budget - (getMonoTime() - turnStart)).inMilliseconds.int
    if remainingMs <= 0:
      result.records.add(fallbackRecord(turnIndex, attempt + 1, "timeout",
        "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    ## turnBudgetMs is a monotonic deadline around the WHOLE turn, the
    ## turnSpacingMs rate floor included, so an attempt is given the SMALLER of
    ## its configured deadline and the time the turn has left. Unclamped, a
    ## 2.6 s spacing sleep plus a 6 s attempt 1 left this guard satisfied at
    ## 8.6 s and a full 3 s retry then ran the turn to 11.6 s, past the 9.5 s
    ## the note's episode arithmetic budgets per turn.
    let deadlineMs = min(
      (if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs),
      remainingMs)
    var user = $observation
    if attempt > 0:
      user.add("\n\nYour previous reply was not usable. Reply with ONLY the " &
        "JSON object described above, starting with '{', with an " &
        "\"actions\" array.")
    let request = engine.client.requestFor(
      SystemPrompt, userMessage(engine.seats[seat].prompt, user))
    ## ONE seat, so this is a batch of ONE through the starter's unchanged
    ## batching path. Never a sequential per-cog loop.
    var batch: RequestBatch
    batch.post(request.url, request.headers, request.body, $seat)
    let started = getMonoTime()
    engine.noteRequest()
    ## curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    ## SECONDS, so this conversion FLOORS — and sim_config REJECTS a
    ## sub-second value, so the floor below is an identity: 6000 -> 6 s,
    ## 3000 -> 3 s, worst case 9 s inside the 9.5 s turnBudgetMs cap.
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var cause = "parse_error"
    try:
      let text = engine.client.textOf(
        responses[0].response, responses[0].error, batch[0].url)
      var directive = parseDirective(
        extractJsonObject(text), sim.config.maxActionsPerTurn)
      directive.source = dsLlm
      directive.latencyMs = latency
      result.directive = directive
      open = false
    except CatchableError as error:
      if responses[0].error.len > 0:
        cause = (if "timeout" in responses[0].error.toLowerAscii():
                   "timeout" else: "transport_error")
      elif error.msg.startsWith("llm throttled"):
        cause = "throttled"
      result.records.add(
        fallbackRecord(turnIndex, attempt + 1, cause, error.msg))
      ## Attempt 1 says WILL RETRY. Only a genuine second failure may say
      ## "falling back" — that is the phrase phase 60 greps the game log for.
      if attempt == 0:
        echo "minigrid llm: seat ", seat, " attempt 1 failed, will retry: ",
          error.msg
      else:
        echo "minigrid llm: seat ", seat, " attempt 2 failed: ", error.msg
    inc attempt
    if engine.client.throttled and open:
      ## FAIL FAST. The only model left answered 429, so the retry batch would
      ## be refused the same way.
      echo "minigrid llm: provider throttled with no other candidate; ",
        "seat falls back for turn ", turnIndex
      break

  if open:
    result.directive = scoutFallback(sim)
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.records.add(fallbackRecord(turnIndex, 2, cause,
      "seat fell back to the scout plan"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "minigrid llm: seat ", seat, " falling back to scout (", cause,
      ") on turn ", turnIndex

proc applyDirective*(sim: var SimServer, directive: Directive,
                     view: JsonNode): string =
  ## Turn steps 6 and 7: expand the plan against the known map as of turn
  ## start, truncate it to `turnTicks`, install it, and return the replay
  ## `directive` record.
  let expansion = expandPlan(sim.knownMap, sim.agent.x, sim.agent.y,
    sim.agent.dir, directive.actions, sim.config.macroPrimitiveCap,
    sim.config.turnTicks)
  ## An entry that fails validation is counted ONCE, in `repliesRepaired`;
  ## `actionsDropped` counts the entries past `maxActionsPerTurn` and nothing
  ## else (design note §Turn structure 6a/6b). The same number rides the
  ## `directive` record's `dropped` slot, which is what playback feeds back
  ## into `installPlan`, so the two counters agree live and in replay.
  sim.repliesRepaired += directive.dropped
  sim.notes = directive.notes
  let turn = sim.turnsPlayed + 1
  let task = sim.taskIndex
  sim.installPlan(expansion.primitives, expansion.truncated,
    directive.overCap, expansion.unreachable)
  case directive.source
  of dsLlm: inc sim.llmTurns
  of dsFallback: inc sim.fallbackTurns
  else: discard
  if directive.say.len > 0:
    sim.pending.add(SimEvent(kind: evSay, tick: sim.tickCount,
      a: directive.say))
  boundedDirectiveRecord(directive, turn, task, 0, seatAlias(0),
    expansion.primitives, expansion.truncated,
    directive.overCap, expansion.unreachable, view)

proc applyRecordedDirective*(sim: var SimServer, record: JsonNode) =
  ## PLAYBACK. The `directive` record's `executed` array IS this game's input
  ## log: it installs the identical primitive queue, so re-simulation is
  ## exact. Everything else in the record is non-hashed feed state.
  let primitives = parseRecordedActions(record{"executed"})
  sim.notes = ""
  sim.installPlan(primitives, record{"truncated"}.getBool(),
    record{"dropped"}.getInt(), record{"unreachable"}.getInt())
  case record{"source"}.getStr()
  of "llm": inc sim.llmTurns
  of "fallback": inc sim.fallbackTurns
  else: discard
  let say = record{"say"}.getStr()
  if say.len > 0:
    sim.pending.add(SimEvent(kind: evSay, tick: sim.tickCount, a: say))

## The decision layer — addendum v2 §Tests items 49, 50 and 51.
##
## The batch, the truthful causes and the deadline ladder. Nothing here talks
## to a provider: the cause decision is a named pure function set AT THE POINT
## OF FAILURE (`transportCause` / `exceptionCause` / `usableReply`), the batch
## shape is asserted against the source, and the guards are driven for real.

import std/[json, monotimes, os, strutils, times, unittest]
import minigrid/[sim, decide, directives, baselines, llm]
import helpers

suite "minigrid decisions":

  test "49. ONE batch per turn, one request per ACTIVE seat, never sequential":
    let source = readRepo("src/minigrid/decide.nim")
    ## Exactly ONE call site, and it is the batched one.
    var calls = 0
    var cursor = 0
    while true:
      let hit = source.find("curl.makeRequests(", cursor)
      if hit < 0: break
      inc calls
      cursor = hit + 1
    check calls == 1
    check "engine.client.curl.makeRequests(\n      batch, max(1, deadlineMs div 1000))" in source
    ## The batch is built from the OPEN seats, in one loop, before the call.
    check "for slot in open:" in source
    check "batch.post(request.url, request.headers, request.body, $slot)" in source

    ## The batch is the ACTIVE seats: 4 with four active lanes, 2 with two
    ## resolved, 0 with all four resolved — an idling lane costs no request.
    var sim = initSimServer(testConfig())
    sim.phase = Playing
    sim.startPhase(0)
    sim.beginTurn()
    check sim.activeSeats().len == LaneCount
    sim.lanes[1].taskOutcome = toSolved
    sim.lanes[3].taskOutcome = toTimeout
    check sim.activeSeats() == @[0, 2]
    for slot in 0 ..< sim.lanes.len:
      sim.lanes[slot].taskOutcome = toSolved
    check sim.activeSeats().len == 0

    ## The per-episode call budget: at most one request per active seat per
    ## turn plus one retry each.
    check LaneCount * sim.config.maxTurns * 2 == 240
    check LaneCount * sim.config.maxTurns == 120

    ## A scripted seat consumes NO request at all, and every seat still gets a
    ## legal plan.
    var engine = initDecisionEngine(sim)
    for slot in 0 ..< LaneCount:
      engine.seats[slot].isLlm = false
      engine.seats[slot].baseline = blScout
    var live = initSimServer(testConfig())
    live.phase = Playing
    live.startPhase(0)
    live.beginTurn()
    let turn = engine.turn(live, 1, 0)
    check turn.decisions.len == LaneCount
    check engine.lastRequestCount == 0
    check engine.totalRequests == 0
    for decision in turn.decisions:
      check decision.directive.source == dsScripted
      check decision.directive.actions.len <= live.config.maxActionsPerTurn

  test "50. the recorded cause is the cause that ACTUALLY happened":
    ## A transport timeout on BOTH attempts is `transport_timeout` twice —
    ## never `parse_error`, which is where v1's ladder landed because it
    ## derived the cause from the parse step (VERIFY check 5).
    check transportCause("llm transport: Timeout was reached", 0) ==
      fcTransportTimeout
    check transportCause("Timeout was reached", 200) == fcTransportTimeout
    check transportCause("connection reset by peer", 0) == fcTransportError
    check transportCause("", 500) == fcHttpError
    check transportCause("", 429) == fcHttpError
    check transportCause("", 200) == fcParseError
    check exceptionCause("llm transport: Timeout was reached") ==
      fcTransportTimeout
    check exceptionCause("llm transport: could not resolve host") ==
      fcTransportError
    check exceptionCause("llm throttled (429): slow down") == fcHttpError
    check exceptionCause("llm auth failed (401)") == fcHttpError
    check exceptionCause("anthropic error 500: boom") == fcHttpError
    check exceptionCause("no JSON object in reply: sorry") == fcParseError

    ## A non-JSON body is a parse failure; a parsed body with neither
    ## `actions` nor `say` is a SCHEMA failure.
    var parsed = false
    try:
      discard extractJsonObject("I cannot help with that.")
    except DirectiveError as error:
      parsed = true
      check exceptionCause(error.msg) == fcParseError
    check parsed
    let empty = parseDirective(parseJson("""{"thoughts":"hmm"}"""), 24)
    check not empty.usableReply()
    let sayOnly = parseDirective(parseJson("""{"say":"thinking"}"""), 24)
    check sayOnly.usableReply()
    let acted = parseDirective(
      parseJson("""{"actions":[{"do":"forward"}]}"""), 24)
    check acted.usableReply()

    ## Every cause in the CLOSED enum is spelled the way the results document
    ## and the log line spell it.
    var names: seq[string]
    for cause in FallbackCause:
      names.add($cause)
    check names == @["transport_timeout", "transport_error", "http_error",
                     "parse_error", "schema_error", "no_credentials",
                     "rate_guard", "budget_guard", "disconnected"]

    ## A `fallback` record is written PER ATTEMPT, each with its own cause and
    ## its own slot.
    let first = parseJson(fallbackRecord(7, 2, 1, fcTransportTimeout, "t/o"))
    let second = parseJson(fallbackRecord(7, 2, 2, fcTransportTimeout, "t/o"))
    check first["attempt"].getInt() == 1
    check second["attempt"].getInt() == 2
    check first["slot"].getInt() == 2
    for record in [first, second]:
      check record["cause"].getStr() == "transport_timeout"
      check record["turn"].getInt() == 7

    ## `fallbackCauses[i]` counts EVERY FAILED ATTEMPT of a turn that fell
    ## back — both attempts, each under its own cause (addendum v2.1 §2). v2
    ## kept only the last, so a summary reader never learned a champion had
    ## also produced a malformed reply.
    var sim = initSimServer(testConfig())
    sim.phase = Playing
    sim.startPhase(0)
    sim.beginTurn()
    for slot in 0 ..< sim.lanes.len:
      var directive = scoutPlan(sim.lanes[slot], sim.config)
      directive.source = dsFallback
      case slot
      of 0:
        ## the round-17 case: schema_error then transport_timeout
        directive.causes = @[fcSchemaError, fcTransportTimeout]
      of 1:
        directive.causes = @[fcRateGuard]            ## blocked before any call
      of 2:
        directive.causes = @[fcTransportTimeout, fcTransportTimeout]
      else:
        directive.causes = @[fcParseError]
      directive.cause = directive.causes[^1]
      let record = sim.applyDirective(slot, directive, nil)
      check parseJson(record)["cause"].getStr() == $directive.cause
      check parseJson(record)["slot"].getInt() == slot
      var recorded: seq[string]
      for item in parseJson(record)["causes"]:
        recorded.add(item.getStr())
      check recorded.len == directive.causes.len
    let results = parseJson(sim.gauntletResultsJson())
    for slot in 0 ..< LaneCount:
      var total = 0
      for _, count in results["fallbackCauses"][slot].pairs:
        total += count.getInt()
      ## THE NEW IDENTITY, replacing v2's `== fallbackTurns`.
      let turns = results["fallbackTurns"][slot].getInt()
      check turns <= total
      check total <= 2 * turns
    ## A mixed-cause turn records BOTH keys.
    check results["fallbackCauses"][0]["schema_error"].getInt() == 1
    check results["fallbackCauses"][0]["transport_timeout"].getInt() == 1
    check results["fallbackTurns"][0].getInt() == 1
    ## Two failures of the SAME cause count twice under the one key.
    check results["fallbackCauses"][2]["transport_timeout"].getInt() == 2
    ## A turn blocked before any call has exactly one.
    check results["fallbackCauses"][1]["rate_guard"].getInt() == 1

    ## A RETRIED turn — attempt 1 failed, attempt 2 SUCCEEDED — is counted by
    ## `retriedTurns[i]` and stays OUT of `fallbackCauses`, which is scoped to
    ## turns that fell back.
    var retried = initSimServer(testConfig())
    retried.phase = Playing
    retried.startPhase(0)
    retried.beginTurn()
    var recovered = scoutPlan(retried.lanes[0], retried.config)
    recovered.source = dsLlm
    recovered.retried = true
    recovered.firstCause = fcSchemaError
    let retriedRecord = retried.applyDirective(0, recovered, nil)
    check parseJson(retriedRecord)["retried"].getBool()
    let retriedResults = parseJson(retried.gauntletResultsJson())
    check retriedResults["retriedTurns"][0].getInt() == 1
    check retriedResults["fallbackTurns"][0].getInt() == 0
    check retriedResults["fallbackCauses"][0].len == 0
    for slot in 1 ..< LaneCount:
      check retriedResults["retriedTurns"][slot].getInt() == 0

    ## The second-failure log line names BOTH causes when they differ, and
    ## still carries the phrase phase 60 greps for.
    let engineSource = readRepo("src/minigrid/decide.nim")
    check "; attempt 1: " in engineSource
    check "falling back to scout (" in engineSource
    check "causesOf[slot][0] != causeOf[slot]" in engineSource

    ## Only a genuine SECOND failure may log `falling back`; attempt 1 says
    ## `will retry`.
    let source = readRepo("src/minigrid/decide.nim")
    check "attempt 1 failed, will retry" in source
    check "falling back to scout (" in source

  test "51. the deadline ladder fits the validators AND the measurements":
    ## Whole seconds, both attempts inside the turn budget, and both at or
    ## above the provider's observed p90/max (VERIFY check 5: attempt1Ms 6000
    ## sat INSIDE the observed distribution and retryMs 3000 gave the retry
    ## LESS headroom than attempt 1).
    let m = manifest()
    var configs: seq[JsonNode]
    for variant in m["variants"]:
      configs.add(variant["game_config"])
    configs.add(m["certification"]["game_config"])
    for node in configs:
      var config = defaultGameConfig()
      var copied = node.copy()
      copied["tokens"] = %["t0", "t1", "t2", "t3"]
      config.update($copied)
      config.validate()
      check config.attempt1Ms mod 1000 == 0
      check config.retryMs mod 1000 == 0
      check config.attempt1Ms + config.retryMs <= config.turnBudgetMs
      check config.wallClockBudgetSeconds <= 660
      check config.attempt1Ms >= 18000
      check config.retryMs >= 12000
      ## THE GUARD BOUND (addendum v2.1 §1), replacing v2's arithmetic
      ## "fits always" bound, which no ladder covering the concurrent-batch
      ## p90 can satisfy at 30 turns. The budget guard lets no turn START
      ## after `wallClock - 2 * (spacing + budget)`; that turn costs at most
      ## one budget, every later turn runs `scout` in microseconds, and the
      ## artifacts take 21 s.
      let latestStart = config.wallClockBudgetSeconds -
        2 * (config.turnSpacingMs + config.turnBudgetMs) div 1000
      check latestStart + config.turnBudgetMs div 1000 + 21 <=
        config.wallClockBudgetSeconds
    ## The SHIPPED ladder, sized off the CONCURRENT-BATCH p90 — never off the
    ## right-censored maximum (addendum v2.1 §1).
    for variant in m["variants"]:
      let config = variant["game_config"]
      ## 1.5x the projected four-seat p90 (12.1 s), 1.8x the observed
      ## three-seat p90 (10.1 s).
      check config["attempt1Ms"].getInt() == 18000
      ## ~= the projected four-seat p90, so the retry is a genuine second
      ## chance (v1's error was retry < attempt 1).
      check config["retryMs"].getInt() == 12000
      check config["retryMs"].getInt() >= 12100 - 100
      check config["attempt1Ms"].getInt() + config["retryMs"].getInt() ==
        config["turnBudgetMs"].getInt()
      ## The rate guard is UNCHANGED and cannot be tripped: 4 requests / 11 s
      ## = 21.8 req/min steady, and a slow turn only lowers the rate.
      check config["turnSpacingMs"].getInt() == 11000
      check LaneCount * 60000 div config["turnSpacingMs"].getInt() <= 24
      check LaneCount * 60000 div config["turnSpacingMs"].getInt() +
        LaneCount <= RateGuardMaxRequests
      ## The guard bound, in the addendum's own arithmetic: 578 + 30 + 21.
      let latest = config["wallClockBudgetSeconds"].getInt() -
        2 * (config["turnSpacingMs"].getInt() +
             config["turnBudgetMs"].getInt()) div 1000
      check latest == 578
      check latest + config["turnBudgetMs"].getInt() div 1000 + 21 == 629
      check latest + config["turnBudgetMs"].getInt() div 1000 + 21 <=
        config["wallClockBudgetSeconds"].getInt()
      ## The per-episode call budget is untouched by the ladder.
      check LaneCount * config["maxTurns"].getInt() * 2 == 240
    ## The defaults the server runs with when a runner sends no config.
    let fallbackConfig = defaultGameConfig()
    check fallbackConfig.attempt1Ms == 18000
    check fallbackConfig.retryMs == 12000
    check fallbackConfig.turnBudgetMs == 30000
    check fallbackConfig.turnSpacingMs == 11000

  test "51b. every wait is BOUNDED and the guards never sleep on the path":
    ## The rate guard skips the call; it never sleeps. The budget guard
    ## switches the LLM off for every remaining turn and every lane.
    var config = testConfig()
    var sim = initSimServer(config)
    sim.phase = Playing
    sim.startPhase(0)
    sim.beginTurn()
    var engine = initDecisionEngine(sim)
    for slot in 0 ..< LaneCount:
      engine.seats[slot].isLlm = true
      engine.seats[slot].prompt = "p"
    engine.client.disabled = false
    engine.client.transport = ltAnthropic
    ## No headroom at all: every seat takes the rate guard, nothing is
    ## dialled, and the turn returns immediately with four legal plans.
    for i in 0 ..< RateGuardMaxRequests:
      engine.requestTimes.add(getMonoTime())
    let started = getMonoTime()
    let turn = engine.turn(sim, 3, 0)
    let elapsed = (getMonoTime() - started).inMilliseconds.int
    var guarded = 0
    for record in turn.records:
      if parseJson(record){"cause"}.getStr() == "rate_guard":
        inc guarded
    check guarded == LaneCount
    check engine.lastRequestCount == 0
    check turn.decisions.len == LaneCount
    ## and the whole turn stayed inside the turn budget.
    check elapsed <= config.turnBudgetMs + config.turnSpacingMs + 2000

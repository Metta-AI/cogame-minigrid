## End-to-end episode writing a replay — design note §Tests items 24..27.

import std/[json, os, osproc, sequtils, strutils, tables, unittest]
import std/monotimes
import minigrid/[sim, replays, decide, baselines, directives, llm]
import helpers

proc runEpisode(dir: string, extra: seq[(string, string)] = @[],
                seed = 42, variant = "gauntlet",
                players = @["scout", "bumper", "scout", "bumper"]
               ): tuple[code: int, log: string] =
  ## Runs the REAL binaries the image ships with FOUR seats, against a
  ## temp-dir COGAME_* URI set — the same contract the platform's episode
  ## runner uses.
  createDir(dir)
  var config = testConfig(variant, seed)
  config.lobbyJoinTimeoutTicks = 240
  config.wallClockBudgetSeconds = 120
  var node = parseJson(config.resolvedJson())
  var tokens = newJArray()
  for slot in 0 ..< LaneCount:
    tokens.add(%("token-" & $slot))
  node["tokens"] = tokens
  writeFile(dir / "config.json", $node)
  let root = repoRoot()
  let gameBin = dir / "minigrid"
  let playerBin = dir / "minigrid-player"
  doAssert execCmd("nim c -d:release --hints:off --path:" & root &
    "/src --out:" & gameBin & " " & root & "/src/minigrid.nim") == 0
  doAssert execCmd("nim c -d:release --hints:off --path:" & root &
    "/src --out:" & playerBin & " " & root & "/src/minigrid_player.nim") == 0
  var env = "COGAME_CONFIG_URI=file://" & dir & "/config.json " &
    "COGAME_RESULTS_URI=file://" & dir & "/results.json " &
    "COGAME_SAVE_REPLAY_URI=file://" & dir & "/replay.replay " &
    "COGAME_PLAYER_FAILURE_URI=file://" & dir & "/player_failure.json " &
    "COGAME_EVENTS_URI=file://" & dir & "/events.jsonl PORT=8901 "
  for (key, value) in extra:
    env.add(key & "=" & value & " ")
  var seats = ""
  for slot, player in players:
    if player.len == 0:
      continue
    if seats.len > 0:
      seats.add(" & ")
    let policyEnv =
      if player == "external":
        "PLAYER_EXTERNAL=1 PLAYER_EXTERNAL_ACTION=forward"
      elif player == "jev":
        "PLAYER_JEV=1"
      elif player == "numeric":
        "PLAYER_NUMERIC_URL=http://127.0.0.1:18995"
      else:
        "PLAYER_SCRIPTED=" & player
    seats.add("COWORLD_PLAYER_WS_URL='ws://127.0.0.1:8901/player?slot=" &
      $slot & "&token=token-" & $slot & "' " & policyEnv &
      " PLAYER_POLICY_LABEL=" & player & " " & playerBin & " > " & dir /
      ("player-" & $slot & ".log") & " 2>&1")
  if seats.len == 0:
    seats = "sleep 20"
  discard execCmd("(" & env & gameBin & " > " & dir & "/game.log 2>&1; " &
    "echo $? > " & dir & "/game.code) & sleep 2; " & seats & "; wait")
  result.code = try: parseInt(readFile(dir / "game.code").strip())
                except CatchableError: -1
  result.log = readFile(dir / "game.log")

suite "minigrid engine":

  test "external policy uses the normal seat observation and plan path":
    let dir = getTempDir() / "minigrid-external-policy"
    removeDir(dir)
    let run = runEpisode(dir,
      players = @["external", "bumper", "scout", "bumper"])
    check run.code == 0
    let results = parseJson(readFile(dir / "results.json"))
    let summary = parseJson(execProcess("python3 " & repoRoot() &
      "/tools/replay_summary.py " & dir / "replay.replay"))
    check results["reason"].getStr() == "complete"
    check results["policyKinds"][0].getStr() == "external"
    check results["fallbackTurns"][0].getInt() == 0
    var externalPlans = 0
    for plan in summary["plans"]:
      if plan["slot"].getInt() == 0:
        check plan["source"].getStr() == "external"
        check plan["verbs"][0].getStr() == "forward"
        inc externalPlans
    check externalPlans > 0

  test "Jev chooses through the same external seat protocol":
    let dir = getTempDir() / "minigrid-jev-policy"
    removeDir(dir)
    createDir(dir)
    let log = dir / "calls.jsonl"
    let stub = startProcess("python3", args = @[
      repoRoot() / "tests/jev_stub.py", "18996", log],
      options = {poUsePath})
    sleep(100)
    putEnv("TYPESAFE_BASE_URL", "http://127.0.0.1:18996")
    putEnv("TYPESAFE_API_KEY", "mock")
    try:
      let run = runEpisode(dir,
        players = @["jev", "bumper", "scout", "bumper"])
      check run.code == 0
      let results = parseJson(readFile(dir / "results.json"))
      let summary = parseJson(execProcess("python3 " & repoRoot() &
        "/tools/replay_summary.py " & dir / "replay.replay"))
      check results["reason"].getStr() == "complete"
      check results["policyKinds"][0].getStr() == "external"
      check results["fallbackTurns"][0].getInt() == 0
      var plans = 0
      for plan in summary["plans"]:
        if plan["slot"].getInt() == 0:
          check plan["source"].getStr() == "external"
          check plan["verbs"][0].getStr() == "forward"
          inc plans
      check plans > 0
      var calls = 0
      for line in readFile(log).splitLines():
        if line.len == 0: continue
        let call = parseJson(line)
        check call["lane"].getInt() == 0
        check call["choice"].getStr() == "forward"
        inc calls
      check calls == plans
    finally:
      stub.terminate()
      discard stub.waitForExit()
      stub.close()
      delEnv("TYPESAFE_BASE_URL")
      delEnv("TYPESAFE_API_KEY")

  test "numeric candidate becomes an ordinary player plan":
    let dir = getTempDir() / "minigrid-numeric-policy"
    removeDir(dir)
    createDir(dir)
    let log = dir / "calls.jsonl"
    let stub = startProcess("python3", args = @[
      repoRoot() / "tests/numeric_stub.py", "18995", log],
      options = {poUsePath})
    sleep(100)
    try:
      let run = runEpisode(dir,
        players = @["numeric", "bumper", "scout", "bumper"])
      check run.code == 0
      let results = parseJson(readFile(dir / "results.json"))
      let summary = parseJson(execProcess("python3 " & repoRoot() &
        "/tools/replay_summary.py " & dir / "replay.replay"))
      check results["reason"].getStr() == "complete"
      check results["fallbackTurns"][0].getInt() == 0
      var plans = 0
      for plan in summary["plans"]:
        if plan["slot"].getInt() == 0:
          check plan["source"].getStr() == "external"
          check plan["verbs"][0].getStr() == "forward"
          inc plans
      check plans > 0
      var sessions: seq[string]
      var decisions: seq[int]
      for line in readFile(log).splitLines():
        if line.len > 0:
          let call = parseJson(line)
          sessions.add(call["session"].getStr())
          decisions.add(call["decision_id"].getInt())
      check sessions.len == plans
      check sessions.allIt(it == sessions[0])
      for index in 1 ..< decisions.len:
        check decisions[index] > decisions[index - 1]
    finally:
      stub.terminate()
      discard stub.waitForExit()
      stub.close()

  test "24. an episode writes its artifacts":
    let dir = getTempDir() / "minigrid-e2e-24"
    removeDir(dir)
    let run = runEpisode(dir)
    check run.code == 0
    check fileExists(dir / "results.json")
    check fileExists(dir / "replay.replay")
    let results = parseJson(readFile(dir / "results.json"))
    check results["reason"].getStr() == "complete"
    ## THE FIVE RESULTS IDENTITIES of §Results v2.
    ## 1. the phase turns sum to the turns played.
    var phaseTurns = 0
    for value in results["phaseTurns"]:
      phaseTurns += value.getInt()
      ## 2. and no phase ran past the cap.
      check value.getInt() <= 6
    check phaseTurns == results["turnsPlayed"].getInt()
    for slot in 0 ..< 4:
      var ticks = 0
      var speed = 0
      for i in 0 ..< results["taskTurns"][slot].len:
        ticks += results["taskTicks"][slot][i].getInt()
        ## 2. taskTurns[i][t] <= phaseTurns[t] <= taskTurnCap.
        check results["taskTurns"][slot][i].getInt() <=
          results["phaseTurns"][i].getInt()
        ## 4. solved iff outcome == solved, and a solve implies 3 credits.
        check results["taskSolved"][slot][i].getBool() ==
          (results["taskOutcome"][slot][i].getStr() == "solved")
        if results["taskSolved"][slot][i].getBool():
          check results["taskProgress"][slot][i].getInt() == 3
          speed += 6 - results["taskTurns"][slot][i].getInt()
      ## 3. laneTicks[i] == sum taskTicks[i][t] <= finalTick <= turns x ticks.
      check ticks == results["laneTicks"][slot].getInt()
      check ticks <= results["finalTick"].getInt()
      check results["finalTick"].getInt() <=
        results["turnsPlayed"].getInt() * 24
      ## 5. the score identity, per lane.
      check results["speedTotal"][slot].getInt() == speed
      check results["scores"][slot].getInt() ==
        100_000 * results["tasksSolved"][slot].getInt() +
        1_000 * results["progressTotal"][slot].getInt() +
        10 * results["speedTotal"][slot].getInt()
      ## The truthful cause counts: EVERY failed attempt of a turn that fell
      ## back, so between one and two per fallback turn (addendum v2.1 §2).
      var causes = 0
      for _, count in results["fallbackCauses"][slot].pairs:
        causes += count.getInt()
      check results["fallbackTurns"][slot].getInt() <= causes
      check causes <= 2 * results["fallbackTurns"][slot].getInt()
      ## A retried turn is an LLM turn, never a fallback one.
      check results["retriedTurns"][slot].getInt() >= 0
      check results["retriedTurns"][slot].getInt() <=
        results["llmTurns"][slot].getInt()
      ## Case C reports itself: partial walks are counted, never silent.
      check results["macrosPartial"][slot].getInt() >= 0
    ## The results key set equals the manifest's results_schema key set
    ## EXACTLY — Coworld schemas are closed and undeclared keys are dropped.
    var declared: seq[string]
    for key in manifest()["game"]["results_schema"]["properties"].keys:
      declared.add(key)
    var emitted: seq[string]
    for key in results.keys:
      emitted.add(key)
    for key in declared:
      check key in emitted
    for key in emitted:
      check key in declared
    ## The seats' REAL policy names are spectator-side; the in-game aliases
    ## are the roster's, and the two name spaces never mix.
    check results["names"].len == 4
    check results["names"][0].getStr() == "scout"
    check results["names"][1].getStr() == "bumper"
    check results["aliases"].elems.mapIt(it.getStr()) ==
      @["Alpha", "Beta", "Gamma", "Delta"]
    check results["lanes"].elems.mapIt(it.getInt()) == @[0, 1, 2, 3]
    check results["policyKinds"][0].getStr() == "scripted"
    check results["endRule"].getStr() in
      ["allLanesComplete", "turnCap", "wallClock"]
    for slot in 0 ..< 4:
      check results["laneEndRule"][slot].getStr() in
        ["gauntletComplete", "turnCap", "wallClock"]
    ## SAME SEED, SAME CHALLENGE: the two lanes that played the same baseline
    ## scored identically, which is the fairness the head-to-head rests on.
    check results["scores"][0].getInt() == results["scores"][2].getInt()
    check results["scores"][1].getInt() == results["scores"][3].getInt()

  test "25. the certification seed is interesting":
    ## Seed 42 on `gauntlet` must solve at least one phase in at least one
    ## lane, open at least one door and pick up at least one key inside 720
    ## ticks, so the CI smoke replay always exercises the solved / unlock /
    ## pickup paths — and THE FOUR LANES' LAYOUTS MUST BE IDENTICAL.
    let sim = playScripted(testConfig("gauntlet", 42),
      kinds = @[blScout, blBumper, blScout, blBumper])
    var solved = 0
    var doors = 0
    var picked = 0
    for slot in 0 ..< sim.lanes.len:
      solved += sim.tasksSolved(slot)
      doors += sim.lanes[slot].doorsOpened
      picked += sim.lanes[slot].objectsPickedUp
      for i in 0 ..< sim.config.taskCount:
        check sim.lanes[slot].records[i].mission ==
          sim.lanes[0].records[i].mission
        check sim.lanes[slot].records[i].family ==
          sim.lanes[0].records[i].family
    check solved >= 1
    check doors >= 1
    check picked >= 1
    ## And the replay outlasts a 10 s viewer soak at 10 ticks/second.
    check sim.tickCount >= 120

  test "26. no seat can stall":
    ## Seats that never connect at all. Their LANES still run to a natural
    ## end on `scout`; the other lanes are untouched.
    let silent = getTempDir() / "minigrid-e2e-26"
    removeDir(silent)
    let run = runEpisode(silent, players = @["", "", "", ""])
    check run.code == 0
    check fileExists(silent / "results.json")
    let results = parseJson(readFile(silent / "results.json"))
    check results["reason"].getStr() == "complete"
    for slot in 0 ..< 4:
      check results["deadSeats"][slot].getBool()
    ## Exactly one CLOSED-schema failure payload: {"message",
    ## "failed_policy_index"} and nothing else.
    check fileExists(silent / "player_failure.json")
    let failure = parseJson(readFile(silent / "player_failure.json"))
    var keys: seq[string]
    for key in failure.keys:
      keys.add(key)
    check keys.len == 2
    check "message" in keys
    check "failed_policy_index" in keys
    check failure["failed_policy_index"].getInt() == 0

  test "27. the budget guard and the rate guard settle EARLY, every lane":
    ## With the guard forced, the episode finishes `complete`, not `deadline`,
    ## the record names the turn, and EVERY lane falls back.
    var config = testConfig()
    var engine = initDecisionEngine(initSimServer(config))
    for slot in 0 ..< LaneCount:
      engine.seats[slot].isLlm = true
      engine.seats[slot].prompt = "test"
    var sim = initSimServer(config)
    sim.phase = Playing
    sim.startPhase(0)
    sim.beginTurn()
    let turn = engine.turn(sim, 7, config.wallClockBudgetSeconds)
    check engine.llmOff
    var guarded = false
    var fellBack = 0
    for record in turn.records:
      let node = parseJson(record)
      if node["k"].getStr() == "budget_guard":
        guarded = true
        check node["turn"].getInt() == 7
      if node["k"].getStr() == "fallback":
        inc fellBack
        check node["cause"].getStr() in ["budget_guard", "no_credentials"]
        check node["slot"].getInt() in 0 ..< LaneCount
    check guarded
    check fellBack == LaneCount
    check turn.decisions.len == LaneCount
    for decision in turn.decisions:
      check decision.directive.source == dsFallback
    ## The rate guard: 28 requests inside the trailing 60 s window takes the
    ## scout plan with cause `rate_guard` rather than sleeping.
    var rated = initDecisionEngine(initSimServer(config))
    for slot in 0 ..< LaneCount:
      rated.seats[slot].isLlm = true
    rated.client.disabled = false
    rated.client.transport = ltAnthropic
    for i in 0 ..< RateGuardMaxRequests:
      rated.requestTimes.add(getMonoTime())
    let rateTurn = rated.turn(sim, 8, 0)
    var sawRateGuard = 0
    for record in rateTurn.records:
      if parseJson(record){"cause"}.getStr() == "rate_guard":
        inc sawRateGuard
    check sawRateGuard == LaneCount
    for decision in rateTurn.decisions:
      check decision.directive.source == dsFallback
      check decision.directive.cause == fcRateGuard

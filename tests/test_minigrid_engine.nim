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
    seats.add("COWORLD_PLAYER_WS_URL='ws://127.0.0.1:8901/player?slot=" &
      $slot & "&token=token-" & $slot & "' PLAYER_SCRIPTED=" & player &
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
      ## The truthful cause counts sum to the fallback turns.
      var causes = 0
      for _, count in results["fallbackCauses"][slot].pairs:
        causes += count.getInt()
      check causes == results["fallbackTurns"][slot].getInt()
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

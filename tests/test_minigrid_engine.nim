## End-to-end episode writing a replay — design note §Tests items 24..27.

import std/[json, os, osproc, strutils, tables, unittest]
import std/monotimes
import minigrid/[sim, replays, decide, baselines, directives, llm]
import helpers

proc runEpisode(dir: string, extra: seq[(string, string)] = @[],
                seed = 42, variant = "gauntlet",
                player = "scout"): tuple[code: int, log: string] =
  ## Runs the REAL binaries the image ships, against a temp-dir COGAME_* URI
  ## set — the same contract the platform's episode runner uses.
  createDir(dir)
  var config = testConfig(variant, seed)
  config.lobbyJoinTimeoutTicks = 240
  config.wallClockBudgetSeconds = 120
  var node = parseJson(config.resolvedJson())
  node["tokens"] = %["token-0"]
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
  discard execCmd("(" & env & gameBin & " > " & dir & "/game.log 2>&1; " &
    "echo $? > " & dir & "/game.code) & sleep 2; " &
    (if player.len > 0:
       "COWORLD_PLAYER_WS_URL='ws://127.0.0.1:8901/player?slot=0&token=token-0' " &
       "PLAYER_SCRIPTED=" & player & " PLAYER_POLICY_LABEL=" & player & " " &
       playerBin & " > " & dir & "/player.log 2>&1"
     else: "sleep 20") & "; wait")
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
    ## The four results identities of §Server.
    var turns = 0
    var ticks = 0
    for i in 0 ..< results["taskTurns"].len:
      turns += results["taskTurns"][i].getInt()
      ticks += results["taskTicks"][i].getInt()
      check results["taskSolved"][i].getBool() ==
        (results["taskOutcome"][i].getStr() == "solved")
      if results["taskSolved"][i].getBool():
        check results["taskProgress"][i].getInt() == 3
    check turns == results["turnsPlayed"].getInt()
    check ticks == results["finalTick"].getInt()
    check results["scores"][0].getInt() ==
      100_000 * results["tasksSolved"].getInt() +
      1_000 * results["progressTotal"].getInt() +
      10 * results["speedTotal"].getInt()
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
    ## The seat's REAL policy name is spectator-side; its alias is `Alpha`.
    check results["names"][0].getStr() == "scout"
    check results["aliases"][0].getStr() == "Alpha"
    check results["policyKinds"][0].getStr() == "scripted"

  test "25. the certification seed is interesting":
    ## Seed 42 on `gauntlet` must solve at least one task, open at least one
    ## door and pick up at least one key inside 660 ticks, so the CI smoke
    ## replay always exercises the solved / unlock / pickup paths.
    let sim = playScripted(testConfig("gauntlet", 42))
    check sim.tasksSolved() >= 1
    check sim.doorsOpened >= 1
    check sim.objectsPickedUp >= 1
    ## And the replay outlasts a 10 s viewer soak at 10 ticks/second.
    var totalTicks = 0
    for record in sim.records:
      totalTicks += record.ticks
    check totalTicks >= 120

  test "26. no seat can stall":
    ## A seat that never connects at all.
    let silent = getTempDir() / "minigrid-e2e-26"
    removeDir(silent)
    let run = runEpisode(silent, player = "")
    check run.code == 0
    check fileExists(silent / "results.json")
    let results = parseJson(readFile(silent / "results.json"))
    check results["reason"].getStr() == "complete"
    check results["deadSeats"][0].getBool()
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

  test "27. the budget guard and the rate guard settle EARLY":
    ## With the guard forced, the episode finishes `complete`, not `deadline`,
    ## and the record names the turn.
    var config = testConfig()
    var engine = initDecisionEngine(initSimServer(config))
    engine.seats[0].isLlm = true
    engine.seats[0].prompt = "test"
    var sim = initSimServer(config)
    sim.phase = Playing
    sim.startTask(0)
    let turn = engine.turn(sim, 7, config.wallClockBudgetSeconds)
    check engine.llmOff
    var guarded = false
    var fellBack = false
    for record in turn.records:
      let node = parseJson(record)
      if node["k"].getStr() == "budget_guard":
        guarded = true
        check node["turn"].getInt() == 7
      if node["k"].getStr() == "fallback":
        fellBack = true
        check node["cause"].getStr() in ["budget_guard", "no_credentials"]
    check guarded
    check fellBack
    check turn.directive.source == dsFallback
    ## The rate guard: 28 requests inside the trailing 60 s window takes the
    ## scout plan with cause `rate_guard` rather than sleeping.
    var rated = initDecisionEngine(initSimServer(config))
    rated.seats[0].isLlm = true
    rated.client.disabled = false
    rated.client.transport = ltAnthropic
    for i in 0 ..< RateGuardMaxRequests:
      rated.requestTimes.add(getMonoTime())
    let rateTurn = rated.turn(sim, 8, 0)
    var sawRateGuard = false
    for record in rateTurn.records:
      if parseJson(record){"cause"}.getStr() == "rate_guard":
        sawRateGuard = true
    check sawRateGuard
    check rateTurn.directive.source == dsFallback

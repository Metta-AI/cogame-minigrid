## Manifest — design note §Tests items 33..34.

import std/[json, os, strutils, tables, unittest]
import minigrid/[sim, tasks]
import helpers

suite "minigrid manifest":

  test "33. manifest pins":
    let m = manifest()
    ## num_agents == 4 in BOTH variants' game_config AND in the cert fixture,
    ## and ABSENT at every variant top level (`CoworldVariant` is
    ## additionalProperties:false — goofspiel-oshi-zumo 0.1.0).
    check m["variants"].len == 2
    for variant in m["variants"]:
      check variant["game_config"]["num_agents"].getInt() == LaneCount
      check variant["game_config"]["minPlayers"].getInt() == LaneCount
      check variant["game_config"]["players"].len == LaneCount
      check not variant.hasKey("num_agents")
      check variant.hasKey("description")
      check variant["description"].getStr().len > 40
      ## No literal `tokens` in any game_config (knights-archers 0.1.0).
      check not variant["game_config"].hasKey("tokens")
      ## Every wallClockBudgetSeconds <= 660, deadlines whole seconds, and
      ## attempt1Ms + retryMs <= turnBudgetMs.
      let config = variant["game_config"]
      check config["wallClockBudgetSeconds"].getInt() <= 660
      check config["attempt1Ms"].getInt() mod 1000 == 0
      check config["retryMs"].getInt() mod 1000 == 0
      check config["attempt1Ms"].getInt() + config["retryMs"].getInt() <=
        config["turnBudgetMs"].getInt()
      check config["maxTurns"].getInt() ==
        config["taskCount"].getInt() * config["taskTurnCap"].getInt()
      check config["maxTicks"].getInt() ==
        config["maxTurns"].getInt() * config["turnTicks"].getInt()
      ## THE GUARD BOUND of §Cadence v2.1, replacing v2's arithmetic bound:
      ## no ladder can both cover the concurrent-batch p90 and multiply out
      ## under the 660 s stop at 30 turns, so the worst case is bounded by the
      ## BUDGET GUARD instead — 578 + 30 + 21 = 629 <= 660.
      let latestStart = config["wallClockBudgetSeconds"].getInt() -
        2 * (config["turnSpacingMs"].getInt() +
             config["turnBudgetMs"].getInt()) div 1000
      check latestStart + config["turnBudgetMs"].getInt() div 1000 + 21 <=
        config["wallClockBudgetSeconds"].getInt()
      ## The steady state cannot trip the 28-request rolling guard.
      check 4 * 60000 div max(1, config["turnSpacingMs"].getInt()) <= 24
      check config["attempt1Ms"].getInt() >= 18000
      check config["retryMs"].getInt() >= 12000
      check config["turnTicks"].getInt() == 24
      check config["taskTurnCap"].getInt() == 6
      check config["maxTurns"].getInt() == 30
      check config["maxTicks"].getInt() == 720
      check config["maxActionsPerTurn"].getInt() == 24
    check m["certification"]["game_config"]["num_agents"].getInt() == LaneCount
    check not m["certification"]["game_config"].hasKey("tokens")
    check m["certification"]["game_config"]["wallClockBudgetSeconds"].getInt() <= 660

    ## EVERY declared player must occupy a certification slot (raid 0.1.2).
    ## With four slots BOTH baselines fit, so both are declared and both are
    ## seated.
    check m["player"].len == 2
    var declared: seq[string]
    for player in m["player"]:
      declared.add(player["id"].getStr())
      ## limits.cpu >= "1" (pistonball 0.1.1).
      check player["resources"]["limits"]["cpu"].getStr() == "1"
    check declared == @["scout", "bumper"]
    check m["certification"]["players"].len == LaneCount
    var seated: seq[string]
    for player in m["certification"]["players"]:
      seated.add(player["player_id"].getStr())
    check seated == @["scout", "bumper", "scout", "bumper"]
    for id in declared:
      check id in seated
    check m["certification"]["game_config"]["players"].len == LaneCount
    ## The four SEAT-COUNT invariants tools/ci/docker_smoke.sh cross-checks.
    check m["certification"]["players"].len ==
      m["certification"]["game_config"]["players"].len
    check m["certification"]["game_config"]["players"].len ==
      m["certification"]["game_config"]["num_agents"].getInt()
    let smoke = readRepo("tools/ci/docker_smoke.sh")
    check "seats_expected=\"${SMOKE_SEATS:-4}\"" in smoke

    ## Every ARRAY property in config_schema carries minItems/maxItems
    ## (tandem 0.1.0).
    for key, prop in m["game"]["config_schema"]["properties"].pairs:
      if prop{"type"}.getStr() == "array":
        check prop.hasKey("minItems")
        check prop.hasKey("maxItems")
    check m["game"]["config_schema"]["additionalProperties"].getBool() == false
    var required: seq[string]
    for item in m["game"]["config_schema"]["required"]:
      required.add(item.getStr())
    check "tokens" in required          ## the runner injects them
    check "players" in required

    ## episode_timeout_minutes is TOP-LEVEL, not under game.
    check m.hasKey("episode_timeout_minutes")
    check not m["game"].hasKey("episode_timeout_minutes")
    ## Both protocols present as {"type","value"} OBJECTS (garble v0.1.0).
    for key in ["player", "global"]:
      check m["game"]["protocols"].hasKey(key)
      check m["game"]["protocols"][key].kind == JObject
      check m["game"]["protocols"][key].hasKey("type")
      check m["game"]["protocols"][key].hasKey("value")
    ## docs.readme + pages.
    check m["game"]["docs"]["readme"].kind == JObject
    check m["game"]["docs"]["pages"].len == 3
    for page in m["game"]["docs"]["pages"]:
      for key in ["id", "title", "content"]:
        check page.hasKey(key)
    ## game.description present, game.tags ABSENT (pistonball 0.1.0), and at
    ## least three top-level tags.
    check m["game"]["description"].getStr().len > 40
    check not m["game"].hasKey("tags")
    check m["tags"].len >= 3
    ## The replay viewer is the STATIC BUNDLE, under `game`.
    check m["game"]["replay_viewer"]["bundle"].getStr() == "static-replay-viewer"
    check not m.hasKey("replay_viewer")
    check m["game"]["runnable"]["type"].getStr() == "game"
    check m["game"]["runnable"]["run"][0].getStr() == "/bin/minigrid"
    ## game.name equals the slug AND the secret URI's namespace (the
    ## commons-family 2026-08-24 scar).
    check m["game"]["name"].getStr() == "minigrid"
    check m["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr() ==
      "secret://coworld/minigrid/anthropic_api_key"
    check not m.hasKey("version")
    check not m["game"].hasKey("display_name")
    check m["game"].hasKey("owner")

    ## EVERY variant's game_config actually constructs a valid GameConfig,
    ## generates all five of its tasks, and produces the ladder, the missions
    ## and the 55-turn schedule this note claims (the collab-cooking 0.1.1
    ## scar: test every variant, not just the fixture).
    var configs: seq[JsonNode]
    for variant in m["variants"]:
      configs.add(variant)
    configs.add(m["certification"])
    for variant in configs:
      var config = defaultGameConfig()
      var node = variant["game_config"].copy()
      node["tokens"] = %["token-0"]
      config.update($node)
      config.validate()
      var sim = initSimServer(config)
      sim.phase = Playing
      check config.maxTurns == 30
      check config.numAgents == LaneCount
      check sim.lanes.len == LaneCount
      check config.taskLadder.len == 5
      for taskIndex in 0 ..< config.taskCount:
        sim.startPhase(taskIndex)
        for slot in 0 ..< sim.lanes.len:
          let lane = sim.lanes[slot]
          check lane.task.mission.len > 0
          check $lane.task.family == config.taskLadder[taskIndex]
          check lane.task.grid.at(lane.task.startX, lane.task.startY).kind ==
            ckEmpty
          ## The lane index is NOT a generator input.
          check lane.task.grid.cells == sim.lanes[0].task.grid.cells
          check lane.task.mission == sim.lanes[0].task.mission
      ## The ladder plays to a real end on the shipped baseline.
      let played = playScripted(config)
      check played.phase == GameOver
      check played.endReason == erComplete

    ## The xland constants are bounded by `validate()` as well as by
    ## config_schema: below four objects or three rules the rule sampler
    ## returns an EMPTY set and `generateXland` indexes it.
    var short = defaultGameConfig()
    short.xlandObjects = 3
    expect ConfigError:
      short.validate()
    var norules = defaultGameConfig()
    norules.xlandRules = 2
    expect ConfigError:
      norules.validate()
    ## num_agents is FOUR: not a range, not configurable.
    var oneSeat = defaultGameConfig()
    oneSeat.numAgents = 1
    expect ConfigError:
      oneSeat.validate()

  test "34. the manifest loads under the installed CLI's own validator":
    ## CI runs `coworld`'s `validate_upload_manifest` / `_load_template_manifest`
    ## for real (the collab-cooking 2026-08-25 scar). Here we assert the shape
    ## those functions require, so a local run fails before a dispatch does.
    let raw = readRepo("coworld_manifest_template.json")
    check "{{MINIGRID_IMAGE}}" in raw
    let m = parseJson(raw)
    check m.hasKey("$schema")
    ## `_load_template_manifest` reads the image off EVERY runnable — the game's
    ## and every role section's — so the placeholder lives INSIDE
    ## `game.runnable`, never beside it (coworld/bundle.py:123-130 raises
    ## KeyError('image') otherwise), and `source_url` goes with it because
    ## `CoworldGame` forbids extra keys.
    check m["game"]["runnable"]["image"].getStr() == "{{MINIGRID_IMAGE}}"
    check not m["game"].hasKey("image")
    check m["game"]["runnable"].hasKey("source_url")
    check not m["game"].hasKey("source_url")
    ## Role-section entries carry a runnable type from the CLI's own enum
    ## {player, commissioner, grader, diagnoser, optimizer} — "policy" is not
    ## one of them.
    for player in m["player"]:
      check player["type"].getStr() == "player"
      check player["image"].getStr() == "{{MINIGRID_IMAGE}}"
    ## The compose service name is what the placeholder is DERIVED from
    ## (lantern 0.1.0).
    let compose = readRepo("compose.yaml")
    check "  minigrid:" in compose
    check "image: coworld-minigrid:latest" in compose
    check "platform: linux/amd64" in compose
    check "network: host" in compose

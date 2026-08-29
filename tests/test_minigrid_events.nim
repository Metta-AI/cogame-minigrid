## Events — design note §Tests item 42, plus the tier-2 analysis stream.

import std/[json, strutils, unittest]
import minigrid/[sim, broadcast, events, baselines, driver]
import helpers

const DeclaredKinds = [
  "taskstart", "turn", "plan", "say", "fallback", "pickup", "drop", "open",
  "close", "unlock", "produce", "subgoal", "lava", "crash", "solved",
  "failed", "budget", "end"]

suite "minigrid events":

  test "42. the emitted set is EXACTLY the closed enum":
    ## Seventeen kinds plus `end`.
    check DeclaredKinds.len == 18
    var declared: seq[string]
    for kind in EventKind:
      declared.add($kind)
    for kind in DeclaredKinds:
      check kind in declared
    for kind in declared:
      check kind in DeclaredKinds

    ## Every kind the appended game block routes is in that set, and the
    ## block routes NOTHING that is not.
    let page = readRepo("client/replay_broadcast.html")
    let split = page.find("MINIGRID additions to the inherited coworld-ctf chrome")
    let block0 = page[split .. ^1]
    for kind in DeclaredKinds:
      check ("case '" & kind & "':") in block0 or ("'" & kind & "'") in block0

    ## The beats are exactly the seven the scrubber draws; nothing per-tick is
    ## a beat, so the feed cannot flood.
    var beats: seq[string]
    for kind in EventKind:
      if kind.isBeat(): beats.add($kind)
    check beats.len == 7
    for kind in ["taskstart", "solved", "failed", "unlock", "produce",
                 "fallback", "end"]:
      check kind in beats
    for kind in ["turn", "plan", "say", "pickup", "drop", "open", "close",
                 "subgoal", "lava", "crash", "budget"]:
      var value = evTurn
      for candidate in EventKind:
        if $candidate == kind: value = candidate
      check not value.isBeat()

  test "a real episode emits only declared kinds, in the documented shape":
    var config = testConfig("xland", 11)
    var sim = initSimServer(config)
    sim.phase = Playing
    var tracker = initBroadcastTracker()
    var seen: seq[string]
    var turns = 0
    while sim.phase == Playing and turns < 400:
      if sim.waitingForPlan():
        sim.beginTurn()
        if sim.phase != Playing: break
        inc turns
        for slot in sim.activeSeats():
          let plan = scriptedPlan(sim.lanes[slot], sim.config, blScout)
          let expansion = expandPlan(sim.lanes[slot].knownMap,
            sim.lanes[slot].agent.x, sim.lanes[slot].agent.y,
            sim.lanes[slot].agent.dir, plan.actions,
            config.macroPrimitiveCap, config.turnTicks)
          sim.installLanePlan(slot, expansion.primitives, expansion.truncated,
            0, expansion.unreachable)
      sim.stepTick()
      let events = newJArray()
      sim.stepEvents(tracker, events)
      for event in events:
        let kind = event["k"].getStr()
        check kind in DeclaredKinds
        check event.hasKey("t")
        ## EVERY event names its lane: a lane-specific kind carries its seat,
        ## an episode-wide kind carries -1.
        check event.hasKey("s")
        if kind in ["taskstart", "turn", "budget", "end"]:
          check event["s"].getInt() == -1
        else:
          check event["s"].getInt() in 0 ..< LaneCount
        if kind notin seen: seen.add(kind)
    if sim.phase == Playing:
      sim.finish(erComplete, edAllLanesComplete)
    let tail = newJArray()
    sim.stepEvents(tracker, tail)
    for event in tail:
      if event["k"].getStr() notin seen: seen.add(event["k"].getStr())
    ## The families this episode really exercises.
    for kind in ["taskstart", "turn", "subgoal", "end"]:
      check kind in seen

  test "the tier-2 analysis stream keeps its summary row":
    var sim = initSimServer(testConfig())
    sim.phase = Playing
    sim.startPhase(0)
    var rows: seq[string]
    rows.add(sim.primitiveRow(2, pForward))
    rows.add(sim.eventRow(SimEvent(kind: evPickup, tick: 3, slot: 1, x: 2,
      y: 9, a: "key", b: "yellow")))
    rows.add(sim.summaryRow(rows.len))
    let stream = eventsJsonl(rows)
    var count = 0
    for line in stream.strip().splitLines():
      let node = parseJson(line)
      check node.hasKey("type")
      inc count
    check count == 3
    let summary = parseJson(stream.strip().splitLines()[^1])
    check summary["type"].getStr() == "summary"
    check summary["gameVersion"].getStr() == GameVersion
    check summary.hasKey("ticks")
    check summary.hasKey("events")
    ## `Primitive` is the per-tick row that makes this a full action trace,
    ## and every row names its lane.
    check parseJson(rows[0])["type"].getStr() == "Primitive"
    check parseJson(rows[0])["slot"].getInt() == 2
    check parseJson(rows[1])["slot"].getInt() == 1
    ## An undeclared kind produces no row rather than an undeclared one.
    check sim.eventRow(SimEvent(kind: evSay, a: "hi")) == ""

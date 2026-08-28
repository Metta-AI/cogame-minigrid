## `stepEvents` (the derived broadcast events), `buildStateJson` (the chrome
## frame) and `rosterJson`. Forked from `coworld-ctf/src/ctf/broadcast.nim`:
## the STRUCTURE is the starter's — the same frame keys, the same
## once-per-viewer lead/beat/lull shipping — with the fields retargeted.
##
## Derived events cost NO replay bytes and are identical live and in replay,
## because both sides derive them from the same sim.

import std/[json, strutils]
import sim

type
  BroadcastTracker* = object
    ## The starter's tracker diffs state to derive events. This game's sim
    ## already emits its own event list per tick (`sim.pending`), so the
    ## tracker only carries the resync hook the shared playback path calls.
    lastTick*: int

proc initBroadcastTracker*(): BroadcastTracker =
  BroadcastTracker(lastTick: -1)

proc resync*(tracker: var BroadcastTracker, sim: SimServer) =
  tracker.lastTick = sim.tickCount

proc eventJson*(sim: SimServer, event: SimEvent): JsonNode =
  ## One derived event, in the documented shape for its kind.
  result = %*{"k": $event.kind, "t": event.tick}
  case event.kind
  of evTaskStart:
    result["i"] = %event.i
    result["family"] = %event.a
    result["mission"] = %event.b
    result["cap"] = %event.m
    result["of"] = %event.n
  of evTurn:
    result["n"] = %event.i
    result["task"] = %event.n
    result["taskTurn"] = %event.m
  of evPlan:
    result["n"] = %event.i
    result["verbs"] = %event.a
    result["truncated"] = %(event.n != 0)
    result["dropped"] = %event.m
  of evSay:
    result["text"] = %event.a
  of evFallback:
    result["cause"] = %event.a
  of evPickup, evDrop:
    result["type"] = %event.a
    result["color"] = %event.b
    result["x"] = %event.x
    result["y"] = %event.y
  of evOpen, evClose:
    result["color"] = %event.a
    result["x"] = %event.x
    result["y"] = %event.y
  of evUnlock:
    result["color"] = %event.a
    result["key"] = %event.b
    result["x"] = %event.x
    result["y"] = %event.y
  of evProduce:
    result["a"] = %event.a
    result["b"] = %event.b
    result["out"] = %event.c
    result["x"] = %event.x
    result["y"] = %event.y
  of evSubgoal:
    result["i"] = %event.i
    result["which"] = %event.n
    result["label"] = %event.a
  of evLava, evCrash:
    result["x"] = %event.x
    result["y"] = %event.y
  of evSolved:
    result["i"] = %event.i
    result["turns"] = %event.n
    result["ticks"] = %event.m
  of evFailed:
    result["i"] = %event.i
    result["why"] = %event.a
  of evBudget:
    result["turn"] = %event.i
    result["remaining_s"] = %event.n
  of evEnd:
    result["reason"] = %event.a
    result["endRule"] = %event.b
    result["solved"] = %event.i
    result["of"] = %event.n
    result["score"] = %event.m

proc stepEvents*(sim: var SimServer, tracker: var BroadcastTracker,
                 events: JsonNode) =
  ## Drains this tick's derived events into `events`. Both the live server and
  ## replay playback call it once per tick, from the same sim state, so the
  ## feed tells the identical story live and in replay.
  tracker.lastTick = sim.tickCount
  if events.isNil:
    sim.pending.setLen(0)
    return
  for event in sim.pending:
    events.add(sim.eventJson(event))
  sim.pending.setLen(0)

proc isBeat*(kind: EventKind): bool =
  ## The scrubber's beat kinds, and the ONLY kinds the appended game block
  ## draws a marker for. `lava` and `crash` arrive one tick before the
  ## `failed` beat they cause, so beating both would draw two markers on one
  ## tick.
  kind in {evTaskStart, evSolved, evFailed, evUnlock, evProduce, evFallback,
           evEnd}

proc rosterJson*(sim: SimServer): JsonNode =
  ## Spectator-side only: this is where the seat's REAL policy name lives. It
  ## never reaches an observation or a prompt.
  result = newJArray()
  for slot in 0 ..< sim.seatCount():
    var name = "Baseline (" & $(slot + 1) & ")"
    var policy = ""
    var kind = "scripted"
    for entry in sim.players:
      if entry.slot != slot:
        continue
      if entry.name.len > 0: name = entry.name
      policy = entry.policy
      if entry.kind.len > 0: kind = entry.kind
    result.add(%*{
      "s": slot,
      "name": name,
      "alias": seatAlias(slot),
      "team": "red",
      "policy": (if policy.len > 0: policy else: name),
      "kind": kind,
      "alive": true,
      "lives": 1,
      "carry": sim.agent.carries()
    })

proc teamStateJson(sim: SimServer): JsonNode =
  ## The single seat's plate state. The key is `red` because there is one cog
  ## and it is red, which is what keeps the starter's plate colour, its
  ## left/right column layout and its CSS utility classes working unchanged.
  ## `lives` carries the CUMULATIVE SUBGOAL CREDITS (0..15) — the series the
  ## progress sparkline plots.
  var credits = sim.progressTotal()
  for earned in sim.subgoals:
    if earned and sim.taskOutcome == toPending: inc credits
  %*{
    "lives": credits,
    "prog": sim.tasksSolved(),
    "held": sim.tasksSolved(),
    "cov": sim.score(),
    "own": false,
    "tags": sim.knownMap.cellsSeen(),
    "cogs": 1,
    "flag": "home",
    "carrier": -1
  }

proc taskStateJson(sim: SimServer): JsonNode =
  ## Everything the appended MINIGRID block draws: the mission ribbon, the
  ## five task pips, the fog wash, the agent-view inset and the endcard rows.
  var pips = newJArray()
  for i in 0 ..< sim.config.taskCount:
    var state = "pending"
    if i < sim.records.len and sim.records[i].outcome != toPending:
      state =
        case sim.records[i].outcome
        of toSolved: "solved"
        of toUnreached: "unreached"
        else: "failed"
    elif sim.taskStarted and i == sim.taskIndex:
      state = "current"
    var family = $sim.familyAt(i)
    var mission = ""
    if i < sim.records.len and sim.records[i].mission.len > 0:
      mission = sim.records[i].mission
    elif sim.taskStarted and i == sim.taskIndex:
      mission = sim.task.mission
    var turns = 0
    var progress = 0
    if i < sim.records.len:
      turns = sim.records[i].turns
      progress = sim.records[i].progress
    if sim.taskStarted and i == sim.taskIndex and
        sim.taskOutcome == toPending:
      turns = sim.taskTurns
      for earned in sim.subgoals:
        if earned: inc progress
    pips.add(%*{"i": i, "state": state, "family": family, "mission": mission,
                "turns": turns, "credits": progress})
  var view = newJArray()
  if sim.taskStarted:
    for row in sim.task.grid.viewRows(sim.agent.x, sim.agent.y, sim.agent.dir):
      view.add(%row)
  var carrying = ""
  if sim.agent.carries():
    carrying = sim.agent.carrying.describe()
  %*{
    "index": sim.taskIndex,
    "count": sim.config.taskCount,
    "family": (if sim.taskStarted: $sim.task.family else: ""),
    "mission": (if sim.taskStarted: sim.task.mission else: ""),
    "turn": sim.taskTurns,
    "cap": sim.config.taskTurnCap,
    "solved": sim.tasksSolved(),
    "score": sim.score(),
    "credits": sim.progressTotal(),
    "seen": sim.knownMap.cellsSeen(),
    "cells": GridCells,
    "dir": (if sim.taskStarted: $sim.agent.dir else: "east"),
    "carrying": carrying,
    "fallbacks": sim.fallbackTurns,
    "deaths": sim.deaths,
    "crashes": sim.crashes,
    "doors": sim.doorsOpened,
    "picked": sim.objectsPickedUp,
    "productions": sim.productionsFired,
    "pips": pips,
    "view": view
  }

proc buildStateJson*(
  sim: SimServer,
  events: JsonNode,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int,
  povSlot: int,
  leadSeries: seq[seq[int]] = @[],
  startTick: int = 0,
  endHoldSeconds: int = 0,
  skipLulls: bool = false,
  fastForwarding: bool = false,
  lullSpans: seq[array[2, int]] = @[],
  beatEvents: JsonNode = nil
): string =
  ## The broadcast chrome frame. Board-derived STATE is always present, so
  ## even a frame reached by a seek hydrates the scorebug and the endcard with
  ## no events at all.
  var teams = newJObject()
  teams["red"] = sim.teamStateJson()

  var state = %*{
    "t": sim.tickCount,
    "mt": sim.effectiveMaxTicks(),
    "ph": ($sim.phase).toLowerAscii,
    "lob": sim.lobbyStartSecondsRemaining(),
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    "bs": 1,
    "pov": povSlot,
    "regime": "gauntlet",
    "game": 1,
    "games": 1,
    "turnTicks": sim.config.turnTicks,
    "teams": teams,
    "roster": sim.rosterJson(),
    "mg": sim.taskStateJson(),
    "events": (if events.isNil: newJArray() else: events)
  }

  ## The commander lines. This is where a spectator SEES the LLM playing: the
  ## `say` each turn carried, live and in replay from one source.
  if sim.feedDirectives.len > 0:
    var records = newJArray()
    for record in sim.feedDirectives:
      try:
        records.add(parseJson(record))
      except CatchableError:
        discard
    state["directives"] = records

  if leadSeries.len > 0:
    var pts = newJArray()
    for point in leadSeries:
      var row = newJArray()
      for value in point:
        row.add(%value)
      pts.add(row)
    state["lead"] = %*{"teams": ["red"], "pts": pts}

  if not beatEvents.isNil and beatEvents.len > 0:
    state["beats"] = beatEvents

  if lullSpans.len > 0:
    var spans = newJArray()
    for span in lullSpans:
      spans.add(%*[span[0], span[1]])
    state["lulls"] = spans

  ## The endcard is STATE, not an event: present on every game-over frame so a
  ## viewer who seeks straight to the end still sees the verdict.
  if sim.phase == GameOver:
    var overTeams = newJObject()
    overTeams["red"] = %*{"lives": sim.progressTotal(),
                          "prog": sim.tasksSolved()}
    state["over"] = %*{
      "winner": (if sim.tasksSolved() >= sim.config.parTasks: "red" else: ""),
      "draw": false,
      "timeLimit": sim.endRule == edTurnCap,
      "teams": overTeams,
      "endRule": $sim.endRule,
      "reason": $sim.endReason,
      "game": 1,
      "games": 1,
      "regime": "gauntlet",
      "solved": sim.tasksSolved(),
      "of": sim.config.taskCount,
      "par": sim.config.parTasks,
      "score": sim.score()
    }
    if endHoldSeconds > 0:
      state["hold"] = %endHoldSeconds

  $state

## `stepEvents` (the derived broadcast events), `buildStateJson` (the chrome
## frame) and `rosterJson`. Forked from `coworld-ctf/src/ctf/broadcast.nim`:
## the STRUCTURE is the starter's — the same frame keys, the same
## once-per-viewer lead/beat/lull shipping — with the fields retargeted to
## FOUR LANES.
##
## Derived events cost NO replay bytes and are identical live and in replay,
## because both sides derive them from the same sim.
##
## EVERY READOUT IN THE FRAME IS A PURE FUNCTION OF THE STATE ON THE CANVAS.
## Nothing here is memoised across a seek: the frame carries the whole board
## state, so a frame reached by a jump hydrates every readout from scratch
## (addendum v2 §Seek and clock).

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
  ## One derived event, in the documented shape for its kind. Every
  ## LANE-SPECIFIC kind carries its `s` (slot); `taskstart`, `turn`, `budget`
  ## and `end` are episode-wide and carry -1.
  result = %*{"k": $event.kind, "t": event.tick, "s": event.slot}
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
  ## Spectator-side only: this is where each seat's REAL policy name lives. It
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
      "team": laneColour(slot),
      "policy": (if policy.len > 0: policy else: name),
      "kind": kind,
      "alive": true,
      "lives": 1,
      "carry": (if slot < sim.lanes.len: sim.lanes[slot].agent.carries()
                else: false)
    })

proc laneCredits(sim: SimServer, slot: int): int =
  ## The lane's cumulative subgoal credits (0..15) — the series the momentum
  ## panel plots.
  let lane = sim.lanes[slot]
  result = lane.progressTotal()
  if lane.taskOutcome == toPending:
    for earned in lane.subgoals:
      if earned: inc result

proc teamStateJson(sim: SimServer, slot: int): JsonNode =
  ## ONE lane's plate state, under its lane colour — which is what keeps the
  ## starter's four-plate ordering, its left/right column layout and its CSS
  ## utility classes working unchanged. `lives` carries the CUMULATIVE
  ## SUBGOAL CREDITS (0..15).
  let lane = sim.lanes[slot]
  %*{
    "lives": sim.laneCredits(slot),
    "prog": lane.tasksSolved(),
    "held": lane.tasksSolved(),
    "cov": sim.score(slot),
    "own": false,
    "tags": lane.knownMap.cellsSeen(),
    "cogs": 1,
    "flag": "home",
    "carrier": -1
  }

proc laneStateJson(sim: SimServer, slot: int): JsonNode =
  ## Everything the appended MINIGRID block draws for ONE lane panel: its
  ## plate, its quadrant frame, its feed colour and — when it holds the POV —
  ## the 7 x 7 agent-view inset.
  let lane = sim.lanes[slot]
  var view = newJArray()
  if lane.taskStarted:
    for row in lane.task.grid.viewRows(lane.agent.x, lane.agent.y,
        lane.agent.dir):
      view.add(%row)
  var carrying = ""
  if lane.agent.carries():
    carrying = lane.agent.carrying.describe()
  %*{
    "s": slot,
    "alias": seatAlias(slot),
    "colour": laneColour(slot),
    "solved": lane.tasksSolved(),
    "score": sim.score(slot),
    "credits": sim.laneCredits(slot),
    "seen": lane.knownMap.cellsSeen(),
    "turn": lane.taskTurns,
    "resolved": lane.laneResolved(),
    "outcome": $lane.taskOutcome,
    "dir": (if lane.taskStarted: $lane.agent.dir else: "east"),
    "carrying": carrying,
    "fallbacks": lane.fallbackTurns,
    "deaths": lane.deaths,
    "crashes": lane.crashes,
    "doors": lane.doorsOpened,
    "picked": lane.objectsPickedUp,
    "productions": lane.productionsFired,
    "view": view
  }

proc povSlotFor(sim: SimServer): int =
  ## The DEFAULT POV: seat 0 at turn 0, and thereafter the lane with the
  ## highest score. Re-evaluated by the viewer only at a phase boundary, so it
  ## cannot flicker mid-phase.
  var best = -1
  for slot in 0 ..< sim.lanes.len:
    if best < 0 or sim.score(slot) > sim.score(best):
      best = slot
  max(0, best)

proc taskStateJson(sim: SimServer): JsonNode =
  ## The SHARED readouts — one mission ribbon, one five-pip stack, one clock —
  ## plus the four lane panels. All four lanes run the identical seeded
  ## ladder, so the ribbon and the pips are shared by construction.
  var pips = newJArray()
  for i in 0 ..< sim.config.taskCount:
    var family = $sim.familyAt(i)
    var mission = ""
    var quads = newJArray()
    var turns = newJArray()
    var credits = newJArray()
    for slot in 0 ..< sim.lanes.len:
      let lane = sim.lanes[slot]
      var state = "pending"
      if i < lane.records.len and lane.records[i].outcome != toPending:
        state =
          case lane.records[i].outcome
          of toSolved: "solved"
          of toUnreached: "unreached"
          else: "failed"
      elif lane.taskStarted and i == sim.taskIndex:
        state =
          case lane.taskOutcome
          of toPending: "current"
          of toSolved: "solved"
          of toUnreached: "unreached"
          else: "failed"
      elif i > sim.taskIndex:
        state = "pending"
      quads.add(%state)
      var laneTurns = 0
      var laneCredits = 0
      if i < lane.records.len:
        laneTurns = lane.records[i].turns
        laneCredits = lane.records[i].progress
      if lane.taskStarted and i == sim.taskIndex and
          i >= lane.records.len:
        laneTurns = lane.taskTurns
        laneCredits = 0
        for earned in lane.subgoals:
          if earned: inc laneCredits
      turns.add(%laneTurns)
      credits.add(%laneCredits)
      if mission.len == 0:
        if i < lane.records.len and lane.records[i].mission.len > 0:
          mission = lane.records[i].mission
          family = $lane.records[i].family
        elif lane.taskStarted and i == sim.taskIndex:
          mission = lane.task.mission
          family = $lane.task.family
    pips.add(%*{"i": i, "family": family, "mission": mission,
                "current": i == sim.taskIndex and sim.phaseStarted,
                "lanes": quads, "turns": turns, "credits": credits})
  var lanes = newJArray()
  for slot in 0 ..< sim.lanes.len:
    lanes.add(sim.laneStateJson(slot))
  let started = sim.lanes.len > 0 and sim.lanes[0].taskStarted
  %*{
    "index": sim.taskIndex,
    "count": sim.config.taskCount,
    "family": (if started: $sim.lanes[0].task.family else: ""),
    "mission": (if started: sim.lanes[0].task.mission else: ""),
    "turn": (if started: sim.lanes[0].taskTurns else: 0),
    "cap": sim.config.taskTurnCap,
    "turnsPlayed": sim.turnsPlayed,
    "maxTurns": sim.config.maxTurns,
    "maxTicks": sim.config.maxTicks,
    "cells": GridCells,
    "grid": GridSize,
    "pips": pips,
    "lanes": lanes,
    "pov": sim.povSlotFor()
  }

proc buildStateJson*(
  sim: SimServer,
  events: JsonNode,
  playing: bool,
  speed: float,
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
  ## even a frame reached by a seek hydrates the scorebug, the ribbon, the
  ## pips, the plates, the POV inset and the endcard with no events at all.
  var teams = newJObject()
  for slot in 0 ..< sim.lanes.len:
    teams[laneColour(slot)] = sim.teamStateJson(slot)

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
    var teamNames = newJArray()
    for slot in 0 ..< sim.lanes.len:
      teamNames.add(%laneColour(slot))
    var pts = newJArray()
    for point in leadSeries:
      var row = newJArray()
      for value in point:
        row.add(%value)
      pts.add(row)
    state["lead"] = %*{"teams": teamNames, "pts": pts}

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
    for slot in 0 ..< sim.lanes.len:
      overTeams[laneColour(slot)] = %*{
        "lives": sim.lanes[slot].progressTotal(),
        "prog": sim.lanes[slot].tasksSolved()}
    let verdict = sim.winner()
    state["over"] = %*{
      "winner": (if verdict.tied or verdict.slot < 0: ""
                 else: laneColour(verdict.slot)),
      "draw": verdict.tied,
      "timeLimit": sim.endRule == edTurnCap,
      "teams": overTeams,
      "endRule": $sim.endRule,
      "reason": $sim.endReason,
      "game": 1,
      "games": 1,
      "regime": "gauntlet",
      "par": sim.config.parTasks,
      "of": sim.config.taskCount
    }
    if endHoldSeconds > 0:
      state["hold"] = %endHoldSeconds

  ## THE FRAME'S WIRE BOUND. The chrome rides a sprite LABEL whose length is a
  ## U16 on the wire, so a frame past 65535 bytes wraps and mis-frames the
  ## whole packet (VERIFY check 8's `Unknown sprite protocol message type: 34`
  ## x22). The optional keys are shed in order of how little they cost the
  ## spectator, and the board-derived state is never shed.
  result = $state
  if result.len > MaxChromeLabelBytes:
    for key in ["directives", "beats", "lulls", "lead", "events"]:
      if not state.hasKey(key):
        continue
      state.delete(key)
      result = $state
      if result.len <= MaxChromeLabelBytes:
        break

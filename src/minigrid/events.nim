## The tier-2 analysis stream written to `COGAME_EVENTS_URI`: the starter's
## JSON-lines `eventsJsonl` with `SimEventKind` reduced to this game's set and
## the mandatory trailing summary row kept.
##
## `Primitive` is the per-tick row that makes this stream a full action trace
## for `cogamer-rl` — up to 720 rows PER LANE an episode, which is what the
## idea's "natural home for LLM-RL experiments" needs and what the replay
## deliberately does not carry. Every row names its `slot`.

import std/[json, strutils]
import sim

type
  SimEventKind* = enum
    TaskStart = "TaskStart"
    TurnStart = "TurnStart"
    Directive = "Directive"
    Fallback = "Fallback"
    PrimitiveStep = "Primitive"
    Pickup = "Pickup"
    Drop = "Drop"
    DoorOpen = "DoorOpen"
    DoorClose = "DoorClose"
    DoorUnlock = "DoorUnlock"
    Produce = "Produce"
    Subgoal = "Subgoal"
    Death = "Death"
    Crash = "Crash"
    Solved = "Solved"
    Failed = "Failed"

proc analysisKind*(kind: EventKind): tuple[ok: bool, kind: SimEventKind] =
  case kind
  of evTaskStart: (true, TaskStart)
  of evTurn: (true, TurnStart)
  of evPlan: (true, Directive)
  of evFallback: (true, Fallback)
  of evPickup: (true, Pickup)
  of evDrop: (true, Drop)
  of evOpen: (true, DoorOpen)
  of evClose: (true, DoorClose)
  of evUnlock: (true, DoorUnlock)
  of evProduce: (true, Produce)
  of evSubgoal: (true, Subgoal)
  of evLava: (true, Death)
  of evCrash: (true, Crash)
  of evSolved: (true, Solved)
  of evFailed: (true, Failed)
  else: (false, TaskStart)

proc primitiveRow*(sim: SimServer, slot: int,
                   primitive: Primitive): string =
  ## The per-tick action trace row for ONE lane.
  let lane = sim.lanes[clamp(slot, 0, sim.lanes.high)]
  $(%*{
    "type": $PrimitiveStep,
    "tick": sim.tickCount,
    "slot": slot,
    "task": sim.taskIndex,
    "taskTick": lane.taskTick,
    "do": $primitive,
    "x": lane.agent.x,
    "y": lane.agent.y,
    "dir": $lane.agent.dir,
    "carrying": lane.agent.carrying.describe()
  })

proc eventRow*(sim: SimServer, event: SimEvent): string =
  let mapped = analysisKind(event.kind)
  if not mapped.ok:
    return ""
  var node = %*{
    "type": $mapped.kind,
    "tick": event.tick,
    "slot": event.slot,
    "task": sim.taskIndex,
    "i": event.i,
    "x": event.x,
    "y": event.y,
    "n": event.n,
    "m": event.m
  }
  if event.a.len > 0: node["a"] = %event.a
  if event.b.len > 0: node["b"] = %event.b
  if event.c.len > 0: node["c"] = %event.c
  $node

proc summaryRow*(sim: SimServer, events: int): string =
  ## The MANDATORY trailing summary row.
  $(%*{
    "type": "summary",
    "ticks": sim.tickCount,
    "events": events,
    "gameVersion": GameVersion
  })

proc eventsJsonl*(rows: seq[string]): string =
  rows.join("\n") & "\n"

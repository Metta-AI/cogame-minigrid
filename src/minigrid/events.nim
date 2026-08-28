## The tier-2 analysis stream written to `COGAME_EVENTS_URI`: the starter's
## JSON-lines `eventsJsonl` with `SimEventKind` reduced to this game's set and
## the mandatory trailing summary row kept.
##
## `Primitive` is the per-tick row that makes this stream a full action trace
## for `cogamer-rl` — 660 rows an episode, which is what the idea's "natural
## home for LLM-RL experiments" needs and what the replay deliberately does
## not carry.

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

proc primitiveRow*(sim: SimServer, primitive: Primitive): string =
  ## The per-tick action trace row.
  $(%*{
    "type": $PrimitiveStep,
    "tick": sim.tickCount,
    "task": sim.taskIndex,
    "taskTick": sim.taskTick,
    "do": $primitive,
    "x": sim.agent.x,
    "y": sim.agent.y,
    "dir": $sim.agent.dir,
    "carrying": sim.agent.carrying.describe()
  })

proc eventRow*(sim: SimServer, event: SimEvent): string =
  let mapped = analysisKind(event.kind)
  if not mapped.ok:
    return ""
  var node = %*{
    "type": $mapped.kind,
    "tick": event.tick,
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

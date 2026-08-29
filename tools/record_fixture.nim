## Records the committed replay fixtures under `tests/replays/`.
##
##   tools/record_fixture.sh                 # re-record every fixture
##   nim c -r --path:src tools/record_fixture.nim tests/replays
##
## A fixture is a REAL four-lane episode of the CURRENT rules, driven exactly
## the way `src/minigrid/server.nim`'s loop drives one: the turn boundary, one
## `directive` record per active seat per turn, the LOAD-BEARING stop record
## one tick past the last simulated tick, then the results record. Every
## fixture is re-recorded in the SAME COMMIT as a `GameVersion` bump —
## `tests/test_minigrid_replay.nim` test 32 fails the build otherwise.

import std/[os, strutils]
import minigrid/[sim, replays, decide, driver, baselines]

const Baselines = [blScout, blBumper, blScout, blBumper]

proc record(path: string, config: GameConfig) =
  var sim = initSimServer(config)
  var writer = openReplayWriter(path, config.resolvedJson())
  for slot in 0 ..< sim.seatCount():
    let label = $Baselines[slot mod Baselines.len]
    writer.writeJoin(tickTime(0), slot, label, slot, "token-" & $slot)
    discard sim.addPlayer(label, slot, "token-" & $slot, trusted = true)
    let entry = registerRecord(slot, seatAlias(slot), label, "scripted", label)
    writer.writeChat(tickTime(0), 0, entry)
    sim.applyControlRecord(entry)
  for entry in sim.players.mitems:
    entry.registered = true
  while sim.phase == Lobby:
    sim.step()
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
  while sim.phase == Playing:
    if sim.waitingForPlan():
      sim.beginTurn()
      if sim.phase != Playing:
        break
      for slot in sim.activeSeats():
        let view = sim.observationJson(slot, includeNotes = false)
        let plan = scriptedPlan(sim.lanes[slot], sim.config,
          Baselines[slot mod Baselines.len])
        writer.writeChat(tickTime(sim.tickCount), 0,
          sim.applyDirective(slot, plan, view))
    sim.stepTick()
    sim.pending.setLen(0)
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
  if sim.phase != GameOver:
    sim.finish(erComplete, edAllLanesComplete)
  writer.writeChat(tickTime(sim.tickCount), 0,
    stopRecord(sim.tickCount, sim.endRule, sim.stopDetail))
  sim.step()
  writer.writeHash(uint32(sim.tickCount), sim.gameHash())
  writer.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
  writer.closeReplayWriter()
  echo "wrote ", path, " — GameVersion ", GameVersion, ", ", sim.turnsPlayed,
    " turns, ", sim.tickCount, " ticks, seats ", sim.seatCount()

when isMainModule:
  let dir = if paramCount() >= 1: paramStr(1) else: "tests/replays"
  createDir(dir)
  var config = defaultGameConfig()
  config.seed = 42
  config.variant = "gauntlet"
  config.lobbyJoinTimeoutTicks = 4
  config.wallClockBudgetSeconds = 240
  record(dir / "gauntlet-seed42.replay", config)

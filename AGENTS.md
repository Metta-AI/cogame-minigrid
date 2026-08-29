# Agent operating guide — cogame-minigrid

Gameplay rules live in [docs/RULES.md](docs/RULES.md); the reply format in
[docs/ACTIONS.md](docs/ACTIONS.md); the wire contract in
[docs/PROTOCOL.md](docs/PROTOCOL.md); what this is and is not a port of in
[docs/PORTING-MINIGRID.md](docs/PORTING-MINIGRID.md). The design note this repo
implements is [docs/plans/2026-08-28-minigrid-design.md](docs/plans/2026-08-28-minigrid-design.md).

## Layout

- `src/minigrid.nim` — the server entrypoint. **Seed randomisation happens
  inside `runServerLoop`, before `config.validate` and before any seed-derived
  draw**, so every generated layout follows the FINAL seed.
- `src/minigrid/` — the sim modules. `sim.nim` imports and RE-EXPORTS all of
  them, so `import minigrid/sim` still sees everything:
  `sim_types.nim` (consts incl. `GameVersion`, `LaneCount`, the flatty wire
  types — **field order is sacred** — and the rune caps), `sim_config.nim` (the
  `GameConfig` lifecycle and its validators), `grid.nim` (the 13 × 13 cell grid,
  the BFS and the 7 × 7 visibility flood), `tasks.nim` (the seven generators),
  `agent.nim` (the seven primitives), `xland.nim` (the hidden rule table),
  `sim_state.nim` (the `Lane` object, `stepLane`, the step loop, `gameHash`,
  per-lane scoring, the lane-local observation and the results document),
  `driver.nim` (macro → primitive expansion),
  `baselines.nim`, `directives.nim`, `llm.nim`, `decide.nim`, `replays.nim`,
  `replay_runtime.nim`, `broadcast.nim`, `global.nim` (the compositor),
  `server.nim`.
- `src/minigrid_player.nim` — the thin seat registrar (`/bin/minigrid-player`).
- `client/` — the broadcast chrome. `chrome_common.js` is the starter's
  **byte-for-byte** and is sha256-pinned by `tests/test_minigrid_viewer.nim`.
  `replay_broadcast.html` is **DERIVED** by `tools/build_broadcast_page.py`,
  never hand-edited; edit `client/minigrid_block.html` and re-run it.
- `replay-viewer/` — the wasm entry, its emscripten link flags and the shell.
  **All four files come from ONE starter (`coworld-ctf`) and are never spliced
  with another lineage's:** paintbot-lineage shells wait for
  `Module.onRuntimeInitialized` and the module is emitted NON-modularized. A
  mixture hangs on "Loading replay…" forever.
- `tests/` — run from the repo ROOT. `ci.yml` runs every `tests/*.nim` in both
  debug and `-d:release`; `tests/shards/` is the local convenience aggregator.

## Rules of the road

- **FOUR ISOLATED LANES.** `stepLane` is a PURE FUNCTION of one lane's own state
  and that lane's own primitive: it takes no `SimServer`, reads no other lane
  and writes no other lane. Every generator draw is
  `mix64(seed, phaseIndex, salt)` and **the lane index is never an input**, so
  the four lanes hold byte-identical layouts. Nothing crosses a lane — not a
  position, not a `say`, not a score, not a scoreboard.
  `tests/test_minigrid_isolation.nim` is what keeps that true; a helper that
  takes the whole `SimServer` where a `Lane` would do is how it stops being
  true.
- **Phase boundaries are SHARED.** A phase ends only when EVERY lane has
  resolved it; a lane that resolves early idles (no batch entry, no ticks) until
  the boundary. `beginTurn` is the ONE place a turn opens, live and on playback.

- **`GameVersion` gates replay compatibility** and carries a PREPEND-ONLY
  changelog comment. Bump it for any rule change and re-record
  `tests/replays/*.replay`; `tools/ci/check_gameversion.sh` diffs the headline,
  not the digits.
- **Truncate every recorded string on RUNE boundaries** (`truncateRunes`), never
  by byte index. A byte-truncated codepoint renders in a browser and then fails
  a strict UTF-8 parser.
- **All sim arithmetic is integer only.** No float, no `sqrt`, no float literal
  in `sim/grid/tasks/agent/xland/driver/baselines` — a test greps for it. That
  is what makes the native ↔ wasm hash chain exact by construction.
- **The load-bearing stop record.** A wall-clock or fault fact cannot be
  re-derived from sim state. It is written once, at the last simulated tick, and
  applied by the SAME proc (`sim.applyStop`) on record and on playback.
  `tests/test_minigrid_replay.nim` runs record → re-derive for **every** end
  reason, not just the healthy one.
- **The task advance runs at the turn boundary in BOTH paths.** `server.nim`
  calls `sim.advanceTasks()` immediately before installing a plan, and
  `replays.nim`'s `directive` branch does the same. Leaving it to `stepTick`'s
  empty-queue guard skips it whenever the record has already refilled the queue,
  and the next task never starts.
- **The lobby always paces in wall clock**, `fastMode` or not: it is a wait for a
  container to dial in, not a simulation.
- Only a genuine SECOND failure may log **`falling back`**; attempt 1 says
  **`will retry`**. Phase 60 greps the game log for both.
- **A fallback cause is set at the POINT OF FAILURE and copied, never
  re-derived.** `transportCause` / `exceptionCause` / `usableReply` in
  `decide.nim` are the only deciders; deriving the cause from a later step is
  what logged two transport timeouts as `parse_error` (VERIFY check 5).
- **The chrome frame rides a sprite LABEL whose length is a U16 on the wire.** A
  frame past 65 535 bytes WRAPS and the client's parser resumes mid-label,
  reporting a nonsense message type (`Unknown sprite protocol message type: 34`,
  VERIFY check 8). `buildStateJson` sheds optional keys to stay inside
  `MaxChromeLabelBytes`; `addChrome` drops a frame that still exceeds it.

## Local development

```bash
nim c -r tests/shards/tests.nim                          # the whole suite
nim r --path:src tests/test_minigrid_sim.nim             # one file
nim c -r --path:src tools/dump_board_preview.nim /tmp/b.png 42 1
tools/record_fixture.sh                                  # re-record tests/replays/
nim c -r --path:src tools/tune_baselines.nim --check     # the baseline sweep
python3 tools/build_broadcast_page.py --starter <ctf> --check
python3 tools/replay_summary.py episode.replay | jq .
```

Dependencies come from nimby (`nimby --global sync nimby.lock`); the Dockerfile
is the canonical build recipe.

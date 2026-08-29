# What this is, and is not, a port of

**No MiniGrid, no BabyAI, no XLand-MiniGrid dependency, and no bit-exactness.**
Decided as a scoping rail before design. Those packages are Python/JAX with
their own RNG streams and their own registries of hundreds of registered
environments; embedding one means a simulator that cannot compile to wasm,
which makes the **static replay viewer** — a non-optional pin — impossible.

No upstream code is vendored, no upstream numbers are claimed as reproduced,
and **no benchmark score from this coworld is comparable to a published
MiniGrid number.** What is reproduced is the *problem*: 7 × 7 partial
observability with the same occlusion rule, the same seven primitives, the same
object vocabulary, and the same three task ideas (keys and doors, lava, a
sentence, hidden rules).

The divergences, each deliberate:

1. **No dependency, no bit-exactness.** As above.
2. **One board size, seven families.** 13 × 13 for everything, and the families
   are re-authored analogues, not registered environments: `multiroom` is a
   four-room quad rather than a chain of procedurally sized rooms,
   `keycorridor` is three side rooms rather than a scaling ladder, and
   **`ObstructedMaze` is not implemented at all**.
3. **The agent gets world coordinates and a remembered map.** MiniGrid hands the
   policy an egocentric image and nothing else. An LLM re-prompted fresh each
   turn has no hidden state, so this game keeps the memory for it and reports
   `(x, y)` so `goto` has a frame. Unobserved cells stay unobserved — the
   partial observability the idea names is fully preserved; only the *memory
   burden* is lifted.
4. **Actions are batched under a driver, not stepped one per call.** The
   "per-tick discrete" interface is preserved as the primitive set; what changed
   is *who calls it*. Twelve primitives per LLM turn under a deterministic
   driver, plus two macros (`goto`, `face`) that expand to primitives. One LLM
   call per primitive would be ~660 calls in a 720 s budget — impossible — and a
   policy that cannot express "walk over there" spends every turn turning.
5. **Reward shape.** MiniGrid's sparse reward is `1 − 0.9 · steps/maxSteps` on
   success, 0 otherwise. The league needs one rankable integer, so tasks-solved
   is the dominant term, subgoal progress the second and speed the third. All
   three underlying quantities are in `results`, so a MiniGrid-style per-task
   success rate is directly readable from `taskFamilies` + `taskSolved` +
   `taskOutcome`.
6. **Dynamic obstacles never kill passively.** An obstacle refuses to move into
   the agent's cell; only a `forward` the policy chose can end the task. That
   matches MiniGrid's own Dynamic-Obstacles termination and removes an
   unavoidable death.
7. **A key is not consumed by unlocking**, doors can be closed again, and a box
   opens into its contents — the MiniGrid semantics, stated because they are the
   ones an implementer guesses wrong.
8. **`maxGames = 1`.** The starter's multi-game episode is not used: a gauntlet
   has no side to swap.

## Divergences from the starter (`coworld-ctf`), and from this repo's own design note

Recorded here so a reviewer does not have to rediscover them.

- **The sim, the server and the compositor are FRESH-WRITTEN in the starter's
  shape rather than edited in place.** Paintbot's `sim.nim` / `server.nim` /
  `global.nim` are ~14 000 lines of pixel arena, raycast fog, paint grid, hills,
  hearts, flags, grenades and four-team play — every one of which this game
  deletes. What is genuinely inherited is inherited *verbatim*: the replay codec
  (`bitworld/replays`), the sprite protocol, the mummy server shape and its
  `/healthz` + `/client/*` + Ping→Pong contract, the LLM transport, the
  directive parsing, the per-turn batch and its deadlines, the whole `client/`
  chrome, and the build wiring.
- **`client/replay_broadcast.html` is DERIVED, not authored.**
  `tools/build_broadcast_page.py` takes the starter's page bytes and applies an
  enumerated edit list — the removed elements, the vocabulary re-map, the dead
  beat CSS — then appends `client/minigrid_block.html`. Run it with `--check` to
  re-derive and diff. The wiring for the removed elements is left byte-identical
  and pointed at **detached nodes**, because excising it would be the rewrite the
  chrome pin forbids.
- **Inherited scorebug selectors survive.** `.hillchip`, `#lives-red` and
  `.lives-line` remain because the starter's own `renderScorebug` writes through
  them. Their **visible text** is re-mapped (carrying chip, `SOLVED n/5`), which
  is what `tests/test_minigrid_endcard_labels.nim` measures. Removing the
  selectors would mean rewriting the starter's renderer.
- **`window.CTF_WIRE` is kept as an ALIAS of `window.MINIGRID_WIRE`.**
  `chrome_common.js` is byte-for-byte the starter's and reads `CTF_WIRE`;
  `tools/gen_wire_constants.nim` therefore emits both names.
- **The replay is larger than the design note's 18 KB estimate** (~60 KB for a
  300-tick episode) because the `directive` record carries the seat's whole
  observation, as §Record vocabulary specifies. Still trivial next to a video.
- **`spinTurns` is design-pinned at 12, not swept.** It only fires when the
  whole reachable region is mapped and the target is not in it — a terminal
  state a sweep cannot rank. `frontierAdjacencyWeight` and the tie-break rule
  ARE swept (`tools/tune_baselines.nim`, recorded in
  `tools/ci/baseline_tuning.json`).
- **The Bedrock ladder keeps the design note's two candidates**
  (haiku-4-5, then sonnet-4-5) even though the starter's own comment records
  sonnet-4-5 timing out on every sidecar call in paintball 0.1.2. Rotation only
  happens on a 403 "Model access is denied" or a 429, so haiku is what actually
  answers; `BEDROCK_MODEL` pins one if the ladder ever needs shortening.
- **The four cog facings are rotations of ONE nano-banana render**, not four
  generations — a strict top-down sprite rotated 90° IS the same character
  facing the next direction, and one render keeps the style identical across all
  four. Source sheet and split script are committed under `scripts/art/`.

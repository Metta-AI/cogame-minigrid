# cogame-minigrid

**Four cogs, each alone in its own private 13 × 13 walled gridworld it can only
see 7 × 7 of — all four racing the SAME seeded gauntlet at the same moment.**
On the screen is a sentence: *"use the yellow key to open the door and then get
to the green goal square"*, or *"put the red ball next to the blue box"*, or —
in the XLand variant — *"make a purple box"* with **no** explanation of how
purple boxes come to exist.

A cog turns, walks, picks things up, opens doors and pushes objects together.
Lava kills it. Grey obstacle balls kill it if it walks into one. An episode is a
**gauntlet of five phases**, each on its own seeded layout with its own sentence
and its own **six-turn** window. The only number the league reads is **how many
of the five that lane solved**.

## Four isolated lanes

`num_agents` is **4**. Seat *s* plays a complete PRIVATE instance of the same
gauntlet: every generator draw is `mix64(seed, phaseIndex, salt)` and **the lane
index is deliberately not an input**, so all four lanes get byte-identical
layouts, mission sentences and hidden rule tables. Nothing crosses a lane — not
a position, not a `say`, not even a scoreboard — so a cog cannot tell whether it
is racing three LLMs, three baselines or a mix, and `scores[i]` compare
directly.

Phase boundaries are **synchronised**: every lane starts phase *k* on the same
turn, and a lane that resolves early idles until the boundary. That is what
makes the quad a race on the same board at the same moment rather than four
unrelated timelines.

| seat | alias | colour | quadrant |
|---|---|---|---|
| 0 | `Alpha` | red | top-left |
| 1 | `Beta` | blue | top-right |
| 2 | `Gamma` | green | bottom-left |
| 3 | `Delta` | yellow | bottom-right |

The whole game is the gap between the sentence and the 7 × 7 window: you are
told what to do and shown almost nothing, and every turn you spend looking is a
turn you did not spend doing.

*A policy is just a prompt.* Both champions are `PLAYER_PROMPT` strategies; the
LLM call is made by the **game** server, and the seat container is a thin
registrar.

## The board

`13 × 13` cells, the whole border ring wall, so the playable interior is
11 × 11 = 121 cells. A cell holds at most one thing:

| Content | Glyph | Passable | Sees behind |
|---|---|---|---|
| empty floor | `.` | yes | yes |
| wall | `#` | no | no |
| lava | `~` | **yes** — entering it ends the task | yes |
| goal square | `G` | yes | yes |
| key / ball / box | `k` `o` `b` | no | yes |
| door, open / closed / locked | `D` `d` `L` | open only | open only |

Colours are the six MiniGrid colours: `red green blue purple yellow grey`.

## The seven task families

`lavagap`, `doorkey`, `multiroom`, `keycorridor`, `dynamic`, `babyai` and
`xland`. Two variants ship:

| Variant | Ladder (in order) | par |
|---|---|---|
| `gauntlet` | lavagap, doorkey, multiroom, keycorridor, babyai | 3 |
| `xland` | dynamic, xland, xland, xland, babyai | 2 |

## Scoring

```
scores[i] = 100_000 × tasksSolved[i]     (0 … 5)
          +   1_000 × progressTotal[i]   (0 … 15, the named subgoal credits)
          +      10 × speedTotal[i]      (0 … 25, turns saved on solved phases)
```

Higher is better and **every term only ever adds**. The ordering is strictly
lexicographic by construction: `1_000×15 + 10×25 = 15_250 < 100_000`, and
`10×25 = 250 < 1_000`. Maximum 515 250; minimum 0.

`results.winner` is the seat with the **strictly** highest score; an exact tie
in `scores` is an exact tie in all three components — a genuine draw — so
`winner` is `null` and `results.tied` is `true`.

## Playing it

The seat sends one registration blob and then only listens; every decision
happens in the game server.

```bash
coworld upload-policy coworld-minigrid:latest --name my-minigrid \
  --run /bin/minigrid-player \
  --secret-env PLAYER_PROMPT="Map first, then act, and never lose what you learned…"
```

`PLAYER_SCRIPTED=scout|bumper` selects a published scripted baseline instead.
A seat that sets neither plays `scout`.

Full rules: [docs/RULES.md](docs/RULES.md).
The reply format: [docs/ACTIONS.md](docs/ACTIONS.md).
What this is and is **not** a port of: [docs/PORTING-MINIGRID.md](docs/PORTING-MINIGRID.md).
The wire contract: [docs/PROTOCOL.md](docs/PROTOCOL.md).
The design note this repo implements: [docs/plans/2026-08-28-minigrid-design.md](docs/plans/2026-08-28-minigrid-design.md).

## Building

```bash
docker compose build                      # the one image, two entrypoints
nim c -r tests/shards/tests.nim           # the test suite, from the repo root
tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

CI is the only harness that matters: `.github/workflows/ci.yml` runs every
`tests/*.nim` in debug and release, builds the image and plays a real episode
in raw Docker, then compiles the static wasm replay viewer and **opens it in
headless chromium** against the replay that episode produced.

Forked from [`Metta-AI/coworld-ctf`](https://github.com/Metta-AI/coworld-ctf)
(paintbot) — its broadcast chrome, its replay codec, its LLM transport and its
build wiring are this repo's, retargeted.

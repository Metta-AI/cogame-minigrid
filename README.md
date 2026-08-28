# cogame-minigrid

**One cog, alone, in a 13 × 13 walled gridworld it can only see 7 × 7 of.**
On the screen is a sentence: *"use the yellow key to open the door and then get
to the green goal square"*, or *"put the red ball next to the blue box"*, or —
in the XLand variant — *"make a purple box"* with **no** explanation of how
purple boxes come to exist.

The cog turns, walks, picks things up, opens doors and pushes objects together.
Lava kills it. Grey obstacle balls kill it if it walks into one. An episode is a
**gauntlet of five tasks**, each on its own seeded layout with its own sentence
and its own eleven-turn window. The only number the league reads is **how many
of the five it solved**.

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
scores[0] = 100_000 × tasksSolved     (0 … 5)
          +   1_000 × progressTotal   (0 … 15, the named subgoal credits)
          +      10 × speedTotal      (0 … 50, turns saved on solved tasks)
```

Higher is better and **every term only ever adds**. The ordering is strictly
lexicographic by construction: `1_000×15 + 10×50 = 15_500 < 100_000`, and
`10×50 = 500 < 1_000`. Maximum 515 500; minimum 0.

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

# Rules

## Four isolated lanes

`num_agents` is **4**, and seat *s* plays a complete PRIVATE instance of the
same seeded gauntlet. Every generator draw is `mix64(seed, phaseIndex, salt)`
and **the lane index is not an input**, so all four lanes hold byte-identical
layouts, missions and rule tables. `stepLane` is a pure function of one lane's
own state and that lane's own primitive: nothing crosses a lane — no position,
no `say`, no score, no scoreboard.

## The gauntlet and the clock

- **Tick** — one primitive action by one lane's agent.
- **`turnTicks` = 24** — every command turn executes at most twenty-four
  primitives per lane.
- **`taskTurnCap` = 6** turns per phase ⇒ at most 144 ticks per phase per lane.
- **`taskCount` = 5** phases per episode ⇒ **`maxTurns` = 30**,
  **`maxTicks` = 720**.
- Phases run **strictly in the variant's declared order**, one at a time, and
  **their boundaries are synchronised across all four lanes**: every lane starts
  phase *k* on the same turn. The seat is told the family and the mission of the
  **current** phase only.
- A lane whose phase finishes (solved, died, crashed) **stops stepping for the
  rest of the turn** and idles — no LLM call, no ticks — until every lane has
  resolved the phase. Turns saved this way are **not** transferable, but
  finishing early still pays: `speed` is scored per lane.

The ladder of families is public (below). The **layouts are seeded and never
disclosed**: the episode `seed` never appears in any observation or prompt, and
the seat never sees an unobserved cell, a future task, an `xland` rule table, or
any layout parameter.

## Turn resolution order

1. If every lane has resolved the current phase, record it and advance ALL FOUR
   lanes to the next together. If there is no next phase, end the episode.
2. For each lane in ascending seat index, recompute its 7 × 7 visible set and
   merge it into that lane's known map.
3. Issue **ONE batch** carrying one request per **active** seat — an active seat
   is one whose lane has not resolved the phase (attempt-1 deadline
   `attempt1Ms` = 18 s). Seats are never queried sequentially.
4. Every seat that timed out, errored, returned non-JSON or returned no usable
   `actions` is retried **once**, again as a single batch (`retryMs` = 12 s).
   The ladder is sized off the CONCURRENT-BATCH p90 — a batch of three measured
   p90 8.6–10.1 s against a single call's 6.0 s — never off a right-censored
   maximum. The worst case is bounded by the **budget guard**, not by
   arithmetic: it lets no turn start after 578 s, so 578 + 30 + 21 = 629 s sits
   inside the 660 s stop.
5. Still nothing → the **`scout`** scripted plan is computed server-side **for
   that lane** and a `fallback` record is written with the TRUE cause.
6. Validate and expand each seat's plan against **its own lane's** known map, in
   the order the reply lists it: entries past `maxActionsPerTurn` = 24 are
   dropped and counted; an entry that does not validate is **dropped, never
   rewritten**; macros expand against the **known map as of turn start**, each
   yielding at most `macroPrimitiveCap` = 40 primitives; the whole queue is
   truncated to 24.
7. Each seat's `say` (≤ 140 runes) and `notes` (≤ 300 runes) are sanitised **on
   rune boundaries** and written as that seat's `directive` replay record.
8. `turnSpacingMs` = 11 s is a floor on the wall clock between BATCH starts.

## Tick resolution order

1. `tick += 1`; `taskTick += 1`.
2. Pop the next primitive. **An empty queue is a real `wait`** — the tick is spent.
3. Apply the primitive:
   - `left` — `dir = (dir + 3) mod 4`; `right` — `dir = (dir + 1) mod 4`.
   - `forward` — an **obstacle** ahead ends the task `crashed` and no move
     happens; otherwise the agent moves into the cell if it is passable.
   - `pickup` — empty-handed, and the cell ahead holds a non-obstacle
     key/ball/box.
   - `drop` — carrying something, and the cell ahead is **empty floor**.
   - `toggle` — a closed door opens; an open door closes; a locked door opens
     **iff** a key of the same colour is carried (**the key is not consumed**);
     a box is replaced by its contents.
   - `wait` — nothing happens.
4. **Obstacles move** (`dynamic` only). An obstacle NEVER moves into the agent's
   cell: a cog is only ever killed by a `forward` it chose.
5. **Production rules fire** (`xland` only), at most **one per tick**, scanning
   cells in ascending `(y, x)` and neighbours east/south/west/north.
6. **Task termination**, in this order: on lava → `died`; success → `solved`;
   `taskTick == 132` → `timeout`.
7. Recompute visibility, merge, then evaluate the three subgoal predicates. A
   predicate that first becomes true awards its credit **permanently**.
8. Mix the tick into `gameHash`.
9. If the task finished at step 6, break out of the tick loop.

## Visibility

`viewSize = 7`. The view box is the 7 × 7 square with the agent at view
coordinate `(3, 6)` looking toward decreasing `j`. A cell is visible iff the
restated MiniGrid occlusion flood marks it; `seesBehind` is false for **wall**,
**closed door** and **locked door**. A cell never in `vis` stays `?`. A cell
observed and later left behind keeps its **last observed content** — so a
remembered obstacle position goes stale, and the seat is told how stale
(`seen_tick`).

## The seven task families

1. **`lavagap`** — *"get to the green goal square"*. A lava column at
   `gapX ∈ 4…8` with one gap at `gapY ∈ 1…11`.
   Subgoals: the gap has entered the view; `agent.x > gapX`; success.
2. **`doorkey`** — *"use the yellow key to open the door and then get to the
   green goal square"*. A full-height wall with one **locked yellow door**; the
   yellow key is west of it, the goal east.
   Subgoals: carried the key; the door became open; success.
3. **`multiroom`** — *"get to the green goal square"*. Walls at `x = 6` and
   `y = 6`; three **closed** doors on the 0→1, 1→2 and 2→3 boundaries only, so
   the only route is 0 → 1 → 2 → 3.
   Subgoals: entered room 1; entered room 2; success.
4. **`keycorridor`** — *"pick up the blue ball"*. Three side rooms; one has a
   **locked red door** and the blue ball, the red key is in another.
   Subgoals: carried the key; the door became open; success.
5. **`dynamic`** — *"get to the green goal square without touching a grey
   ball"*. Six moving grey balls.
   Subgoals: Manhattan distance to the goal has been ≤ 12; ≤ 6; success.
6. **`babyai`** — six uniquely-identified objects and one of three instructions:
   *go to the …*, *pick up the …*, *put the … next to the …*. "Next to" requires
   both objects **uncarried** on 4-adjacent cells.
7. **`xland`** — *"make a `<colour>` `<type>`"*, with a hidden table of three
   chained production rules `(A)+(B) → P0`, `(C)+(D) → P1`, `(P0)+(P1) → GOAL`.
   **The table is never shown.** The only way to learn it is to push things
   together and read `productions` in the next observation.

## Scoring

```
solved[i]     = 1 if taskOutcome[i] == "solved" else 0
progress[i]   = subgoal credits earned on task i          (0…3; 3 if solved)
speed[i]      = (6 - taskTurns[i]) if solved[i] else 0    (0…5)

scores[s] = 100_000 × Σ solved + 1_000 × Σ progress + 10 × Σ speed
```

Every term is computed PER LANE. `results.win[s]` is
`tasksSolved[s] >= parTasks`; `results.winner` is the seat with the STRICTLY
highest `scores`, and on an exact tie it is `null` with `results.tied` true. `deaths`, `crashes`, `taskCellsSeen`,
`doorsOpened`, `objectsPickedUp`, `productionsFired`, `primitivesExecuted`,
`actionsDropped`, `macrosUnreachable` and `repliesRepaired` are **measured and
never scored**.

## End conditions

`results.reason` is a closed enum of exactly three values:

- **`complete`** — every lane finished the gauntlet
  (`endRule: allLanesComplete`) or the turn cap fired (`turnCap`).
- **`deadline`** — the engine's `wallClockBudgetSeconds` (660 s) stop
  (`endRule: wallClock`). Settles with the **real** phases solved so far in
  every lane and marks every unstarted phase `unreached`.
- **`fault`** — an unexpected exception (`endRule: fault`). Artifacts are still
  written and the process exits 0.

`results.endRule` is the closed enum
`allLanesComplete | turnCap | wallClock | fault`, and `results.laneEndRule[s]`
— what ended THAT lane — is `gauntletComplete | turnCap | wallClock`.

**A silent seat does not end the episode.** A seat that never connects,
disconnects mid-episode, or fails every decision has ITS LANE driven by `scout`
to that lane's natural end, with `deadSeats[s] = true`. The other three lanes
are untouched — that is what isolation buys.

## The scripted baselines

- **`scout`** — a deterministic frontier explorer with a goal check: finish if
  you can, else go to the known target, else walk to the known floor cell
  adjacent to the most `?` cells and cross into the unknown, else spin. It never
  plans a path through lava and never `forward`s into a known obstacle. It is
  also the server-side fallback.
- **`bumper`** — the reactive control: twenty-four actions a turn, each
  `forward` if
  the cell ahead is traversable in the known map, else `right`. No memory, no
  BFS, no mission parsing.

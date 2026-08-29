# Rules

## The gauntlet and the clock

- **Tick** — one primitive action by the agent.
- **`turnTicks` = 12** — every command turn executes at most twelve primitives.
- **`taskTurnCap` = 11** turns per task ⇒ at most 132 ticks per task.
- **`taskCount` = 5** tasks per episode ⇒ **`maxTurns` = 55**, **`maxTicks` = 660**.
- Tasks run **strictly in the variant's declared order**, one at a time. The seat
  is told the family and the mission of the **current** task only.
- A task that finishes (solved, died, crashed) **ends its turn immediately**;
  the remaining ticks of that turn are skipped and the next task begins on the
  next turn. Turns saved this way are **not** transferable.

The ladder of families is public (below). The **layouts are seeded and never
disclosed**: the episode `seed` never appears in any observation or prompt, and
the seat never sees an unobserved cell, a future task, an `xland` rule table, or
any layout parameter.

## Turn resolution order

1. If the current task has finished, record its result and start the next. If
   there is no next task, end the episode.
2. Recompute the 7 × 7 visible set and merge it into the known map.
3. Issue the seat's request (attempt-1 deadline `attempt1Ms` = 6 s).
4. On timeout / error / non-JSON / no usable `actions`, retry **once**
   (`retryMs` = 3 s).
5. Still nothing → the **`scout`** scripted plan is computed server-side and a
   `fallback` record is written.
6. Validate and expand the plan, in the order the reply lists it:
   entries past `maxActionsPerTurn` = 12 are dropped and counted; an entry that
   does not validate is **dropped, never rewritten**; macros expand against the
   **known map as of turn start**, each yielding at most
   `macroPrimitiveCap` = 40 primitives; the whole queue is truncated to 12.
7. `say` (≤ 140 runes) and `notes` (≤ 300 runes) are sanitised **on rune
   boundaries** and written as the turn's `directive` replay record.
8. `turnSpacingMs` = 2.6 s is a floor on the wall clock between request starts.

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
speed[i]      = (11 - taskTurns[i]) if solved[i] else 0   (0…10)

scores[0] = 100_000 × Σ solved + 1_000 × Σ progress + 10 × Σ speed
```

`results.win[0]` is `tasksSolved >= parTasks`; `results.winner` is `0` when
`win[0]` and `null` otherwise. `deaths`, `crashes`, `taskCellsSeen`,
`doorsOpened`, `objectsPickedUp`, `productionsFired`, `primitivesExecuted`,
`actionsDropped`, `macrosUnreachable` and `repliesRepaired` are **measured and
never scored**.

## End conditions

`results.reason` is a closed enum of exactly three values:

- **`complete`** — the gauntlet ran out of tasks (`endRule: gauntletComplete`)
  or the turn cap fired (`turnCap`).
- **`deadline`** — the engine's `wallClockBudgetSeconds` (660 s) stop
  (`endRule: wallClock`). Settles with the **real** tasks solved so far and
  marks every unstarted task `unreached`.
- **`fault`** — an unexpected exception (`endRule: fault`). Artifacts are still
  written and the process exits 0.

**A silent seat does not end the episode.** A seat that never connects,
disconnects mid-episode, or fails every decision is driven by `scout` and the
gauntlet runs to its natural end with `deadSeats[0] = true`.

## The scripted baselines

- **`scout`** — a deterministic frontier explorer with a goal check: finish if
  you can, else go to the known target, else walk to the known floor cell
  adjacent to the most `?` cells and cross into the unknown, else spin. It never
  plans a path through lava and never `forward`s into a known obstacle. It is
  also the server-side fallback.
- **`bumper`** — the reactive control: twelve actions a turn, each `forward` if
  the cell ahead is traversable in the known map, else `right`. No memory, no
  BFS, no mission parsing.

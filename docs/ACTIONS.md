# Actions and the reply format

Reply with **one JSON object and nothing else**. Your reply MUST begin with `{`
and end with `}` — no prose, no markdown, no code fences. A reply that is not a
JSON object is a parse failure; a reply with a valid `say` and no `actions` is
**usable** (the turn is spent waiting and the narration is delivered).

```json
{"actions": [{"do": "goto", "x": 6, "y": 3},
             {"do": "toggle"},
             {"do": "forward"}],
 "say": "I have the yellow key; opening the door at (6,3) and heading east",
 "notes": "goal not seen yet. after the door, sweep east wall first."}
```

| Field | Type | Cap / domain |
|---|---|---|
| `actions` | array | **≤ 12 entries**. Entries past the cap are dropped and counted in `actionsDropped`. Absent or empty = twelve `wait` ticks, and the reply is still usable |
| `actions[].do` | string | **≤ 8 runes**; `left` \| `right` \| `forward` \| `pickup` \| `drop` \| `toggle` \| `wait` \| `goto` \| `face`, lower-cased before matching |
| `actions[].x`, `.y` | integer | required iff `do == "goto"`; **clamped to 0…12**; a non-integer or absent value **drops the entry** |
| `actions[].dir` | string | required iff `do == "face"`; **≤ 5 runes**; matched case-insensitively against `N E S W north east south west`; anything else drops the entry |
| `say` | string | **≤ 140 runes** — drawn in the spectator feed and in the replay, never fed back to you |
| `notes` | string | **≤ 300 runes** — your private scratchpad, echoed back to you only, next turn |
| whole reply | bytes | **≤ 4096** read from the provider before parsing |
| `PLAYER_PROMPT` | string | **≤ 4000 runes** at registration |

Unknown top-level and per-action keys are ignored. **Invalid actions are
dropped, never rewritten**: a mis-specified movement has no meaningful repair —
turning an invalid `goto` into a `forward` would walk the cog into lava on the
game's own initiative — so the entry is removed, counted, and reported back as
`dropped` next turn.

Every string that lands in the replay is truncated on **rune boundaries**,
never by byte index.

## The two macros

| Action | Expands to |
|---|---|
| `left` `right` `forward` `pickup` `drop` `toggle` `wait` | itself, one primitive |
| `face D` | 0, 1 or 2 turn primitives — the shorter rotation; a 180° turn is `right, right` (never `left, left`), pinned for determinism |
| `goto x y` | the turn/step primitives that walk the BFS path below |

**The `goto` BFS**, run against the **known map as of turn start**:

- Edges are 4-adjacency in the fixed order east, south, west, north.
- A cell is **traversable** iff its known glyph is `.`, `G` or `D`. `?`, `~`,
  `#`, `d`, `L`, `k`, `o`, `b` and any cell known to hold an obstacle are not.
- Ties break on the neighbour order above, so the path is **unique** for a given
  known map.
- If the target is traversable the path ends **on** it; if it is 4-adjacent to a
  reached cell the path ends on the nearest such cell and a final `face` toward
  the target is appended; otherwise the macro yields **zero** primitives and
  counts as `unreachable`.
- Bounded by 40 primitives; the whole turn's queue is then truncated to 12.

`goto` refuses to path through `?` cells and through lava. That is why walking
into the unknown costs an explicit `forward` from you.

## What you get each turn

```json
{
  "you": "Alpha",
  "task": {"index": 2, "of": 5, "family": "doorkey",
           "mission": "use the yellow key to open the door and then get to the green goal square",
           "turns_left": 8, "ticks_left": 105},
  "turn": 14, "tick": 159,
  "world": {"size": 13, "view": 7, "legend": {"…": "…"}},
  "agent": {"x": 4, "y": 4, "dir": "east",
            "carrying": {"type": "key", "color": "yellow"},
            "ahead": {"glyph": ".", "object": null}},
  "view":  ["???????", "???????", "???????", "???????",
            "##L####", ".......", "...A..."],
  "known": ["#############", "…twelve more rows…"],
  "objects": [{"type": "door", "color": "yellow", "x": 6, "y": 3,
               "state": "locked", "seen_tick": 152}],
  "productions": [],
  "last_plan": {"executed": ["right", "forward", "…"],
                "truncated": true, "dropped": 0, "unreachable": 0},
  "subgoals": [{"name": "has_key", "earned": true},
               {"name": "door_open", "earned": false},
               {"name": "on_goal", "earned": false}],
  "tasks_solved": 0,
  "notes": "yellow key was at (2,9), got it. locked door at (6,3)."
}
```

`view` is always **7 strings of 7 characters**, **agent-up**: row `j = 0` is the
far row, row `j = 6` is the agent's own row, column `i = 0` is to the agent's
left, and the agent's own cell reads `A`. `known` is always **13 strings of 13
characters** in world orientation. `objects` is sorted ascending by `(y, x)` and
lists only **uncarried** objects — a carried object is out of the world.
`last_plan.executed` lists the **primitives that actually ran**, so you can see
a `goto` get cut off rather than guess.

**Hidden from you:** the episode seed; every cell never observed; every layout
parameter; the contents of an unopened box; the `xland` production rule table
and any rule you have not fired yourself; future obstacle motion; the missions
and layouts of tasks not yet started; your own score; and your real
policy/player name. Nothing about identity ever reaches a prompt — in-game you
are `Alpha` and nothing else.

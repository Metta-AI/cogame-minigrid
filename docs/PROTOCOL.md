# Protocol

The Coworld contract, unchanged in shape from the starter.

## Environment

| Variable | Direction | Meaning |
|---|---|---|
| `COGAME_CONFIG_URI` | in | the resolved `game_config` JSON |
| `COGAME_RESULTS_URI` | out | the results document (closed schema — see below) |
| `COGAME_SAVE_REPLAY_URI` | out | the binary `COWLDMGD` replay |
| `COGAME_PLAYER_FAILURE_URI` | out | exactly `{"message", "failed_policy_index"}` |
| `COGAME_EVENTS_URI` | out | the tier-2 JSON-lines analysis stream |
| `COGAME_LOAD_REPLAY_URI` | in | local replay mode |
| `HOST` / `PORT` (or `COGAME_HOST` / `COGAME_PORT`) | in | the listener |
| `ANTHROPIC_API_KEY` / `ANTHROPIC_API_KEY_URI` | in | injected into the **game** pod |

## Routes

| Route | Purpose |
|---|---|
| `GET /healthz` | liveness; keeps answering for the shutdown grace after artifacts are written |
| `GET /player?slot=&token=` (websocket) | the seat. **Closes unless the token matches the seat** |
| `GET /client/player?slot=&token=` | a real page for the certifier's probe. Token-checked, and it does **not** open the player socket |
| `GET /global`, `GET /replay` (websocket) | spectator streams; they take no player credentials |
| `GET /client/global`, `GET /client/replay` | the served broadcast pages |
| `GET /font.ttf`, `/art/walls/*`, `/art/lockerroom/*` | the chrome's static assets |

A `Ping` is answered with a `Pong` and **nothing else is guarded**: the seat
registers over a `BinaryMessage`, so a `kind != TextMessage` guard would drop it.
Global broadcasts are fire-and-forget, so a slow viewer can never stall the
episode.

## Registration

The seat sends ONE Sprite v1 chat message and then only listens:

```json
{"policy": "<label>", "prompt": "<PLAYER_PROMPT or empty>",
 "scripted": "scout" | "bumper" | null}
```

`prompt` is rune-truncated at 4000 and `policy` at 64. The message is consumed
as **registration**: it is never applied as a shout and never written to the
replay chat stream. The server writes a **redacted** `register` record instead
(policy label and kind, never the prompt), and **refuses to start the game** if
the joined seat produced no register record.

The registration is **re-sent** for the first ~10 s of received frames, because
a first registration can land before the seat has an index.

## The replay

Binary `COWLDMGD`: magic + format version + game name/version, the **resolved
config JSON** (seed, variant, every rule constant, the task ladder, the real
player names), then the record stream — the join record, the per-turn
`directive` records (this game's **entire input log**), the
`register` / `fallback` / `budget_guard` / `stop` / `result` control records, and
**one `gameHash` per tick**.

The **stop** record is load-bearing: a wall-clock or fault fact cannot be
re-derived from sim state, so it is written once and applied by the SAME proc on
record and on playback.

`tools/replay_summary.py` prints one strict-UTF-8 JSON object describing a
replay, using only the Python 3 standard library:

```bash
python3 tools/replay_summary.py episode.replay | jq -r '.protocol, .results.reason'
```

## Results

A closed schema; `game.results_schema` in the manifest lists exactly these keys.
`reason ∈ {complete, deadline, fault}`,
`endRule ∈ {gauntletComplete, turnCap, wallClock, fault}`,
`taskOutcome[i] ∈ {solved, timeout, died, crashed, unreached}`.

Four identities hold in every results document:
`Σ taskTurns == turnsPlayed`; `Σ taskTicks == finalTick`;
`taskSolved[i] == (taskOutcome[i] == "solved")` and `taskSolved[i]` implies
`taskProgress[i] == 3`; and
`scores[0] == 100_000×tasksSolved + 1_000×progressTotal + 10×speedTotal`.

## Two name spaces

In-game the seat is **`Alpha`** — the only name that appears in an observation,
in a prompt, in a `say`, or on the board. The seat's **real policy name** lives
only in `results.names`, in the replay's join record, and spectator-side in the
viewer. `showPlayerLabels` is false.

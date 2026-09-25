# Train on MiniGrid

The headless bridge runs the shipped simulator and accepts the same JSON plans
as hosted players. It emits each active lane's exact player-visible
`observationJson` and uses the shipped `scout` baseline for teacher actions.
All four lanes receive decisions before the simulator advances a turn. The
bridge supports both `gauntlet` and `xland`.
Its `semantic_view` is the same player-visible JSON used in the prompt, so
collectors and Observatory can inspect the observation without parsing text.

Build from this repository root:

```bash
nimby sync nimby.lock
nim c -d:release --path:src --out:/tmp/minigrid-training-bridge \
  src/minigrid/training_bridge.nim
python3 tests/test_training_bridge.py
```

From a Metta checkout containing the generic Coworld bridge, collect and
export seed-separated teacher trajectories:

```bash
uv run --package metta-posttrain metta-posttrain collect-teacher \
  --bridge /tmp/minigrid-training-bridge \
  --bridge-command /tmp/minigrid-training-bridge \
  --output train_dir/minigrid/gauntlet.jsonl \
  --source-revision "$(git -C /path/to/cogame-minigrid rev-parse HEAD)" \
  --episodes 16 --max-decisions 128 --players 4 \
  --game minigrid --action-schema-revision minigrid-actions-v1 \
  --teacher-policy minigrid-scout
uv run --package metta-posttrain metta-posttrain export \
  --trajectory train_dir/minigrid/gauntlet.jsonl \
  --output train_dir/minigrid/gauntlet-dataset
```

For `xland`, add another `--bridge-command xland` and use separate trajectory
and dataset paths. Keep `--max-decisions` at least 120: a full game can have
30 turns with four active seats. `scout` is a deterministic protocol baseline;
these labels do not establish strong play.

# Numeric training

`numeric_bridge.nim` exposes the same hosted lane observation as a fixed
1,295-feature encoding. Its 180 action candidates include seven single
primitives, four facing commands, and `goto`
for each grid cell. Unknown, walled, and lava cells are masked from `goto`.
The chosen candidate is converted into a plan through the game's production
parser and driver. The teacher projects the first action of the `scout` plan
into this same catalog. Every candidate is a plan the ordinary player socket
can submit from its seat-private observation; the catalog does not represent
every possible 24-action sequence. Existing 182-choice pilot checkpoints need
retraining against this 180-choice catalog.

To serve a numeric policy, run an HTTP inference service that accepts
`{"session": "episode token", "seat": integer, "decision_id": integer,
"values": [1295 numbers], "action_mask": [180 booleans]}` and returns
`{"choice": integer}`. The player generates a new session token per episode;
the service uses it to isolate and reset recurrent state and can return the
cached choice for a repeated decision ID. Set `PLAYER_NUMERIC_URL` in the player
container. Set `PLAYER_NUMERIC_KEY` if the service needs a bearer token. The
player encodes
each seat-private observation, checks the returned choice against the same
mask used in training, and sends its decoded plan through the normal `/player`
socket. The game owns parsing, legality, results, and replay. The local
`tests/numeric_stub.py` fixture returns `forward`; it verifies the serving
protocol, not a trained checkpoint or gameplay strength.

Metta's `metta-choice-serve /path/to/frozen-bundle --port 18888` implements
this request for a single player episode. Point `PLAYER_NUMERIC_URL` at
`http://127.0.0.1:18888/choice` when the service runs beside the player.
Start a fresh service process for each episode. A locally initialized
1,295-feature, 180-choice frozen bundle completed a four-seat native game
through this path with 30 accepted external plans and no fallback. Its weights
were not trained, so this proves checkpoint loading and protocol compatibility,
not training quality.

```bash
nim c -d:release --path:src --out:/tmp/minigrid-numeric-bridge \
  src/minigrid/numeric_bridge.nim
python3 tests/test_numeric_bridge.py /tmp/minigrid-numeric-bridge
```

From a Metta checkout containing the generic Coworld bridge, call
`recipes.external.coworld_metta_rl.train` for Metta RL or
`recipes.external.coworld.train` for native PufferLib. Pass
`[/tmp/minigrid-numeric-bridge, gauntlet]` or append `xland`, set `players=4`,
and choose a finite timestep limit. Local full teacher and random games
completed for both variants with a constant 1,295-feature observation.
The following pilots used the superseded 182-choice catalog and require
retraining before a checkpoint can be served through `PLAYER_NUMERIC_URL`.
Metta RL completed 512 steps and evaluation per variant. Native PufferLib
completed 4,096 CUDA steps and evaluation over four episodes each on seeds 101
and 102. Gauntlet evaluation scores were 1,500 and 2,000; XLand scores were
0 and 250. These pilots validate the training and checkpoint paths, not
competitive play. The 180-choice catalog passed full teacher and random bridge
games plus an ordinary-player episode using the numeric inference fixture.

Using the current Metta post-training collector, ten seeded games produced
856 train and 80 validation examples for `gauntlet`, and 880 train and 100
validation examples for `xland`. All fit a 4,096-token context. One CPU
optimizer step reduced four-example validation loss from 1.7306 to 1.7247
and from 1.7293 to 1.7237, respectively. These checks verify the training
path, not stronger league play.

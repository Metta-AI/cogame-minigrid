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
1,295-feature encoding. Its 182 action candidates include the two published
scripted planners, seven single primitives, four facing commands, and `goto`
for each grid cell. Unknown, walled, and lava cells are masked from `goto`.
The chosen candidate is converted into a plan through the game's production
parser and driver. The `scout` candidate is the teacher. This action catalog
can train a policy that selects a scripted plan or overrides it with a direct
command; it does not represent every possible 24-action sequence.

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

Using the current Metta post-training collector, ten seeded games produced
856 train and 80 validation examples for `gauntlet`, and 880 train and 100
validation examples for `xland`. All fit a 4,096-token context. One CPU
optimizer step reduced four-example validation loss from 1.7306 to 1.7247
and from 1.7293 to 1.7237, respectively. These checks verify the training
path, not stronger league play.

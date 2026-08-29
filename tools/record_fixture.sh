#!/usr/bin/env bash
# Re-record every committed replay fixture under tests/replays/.
#
# A GameVersion bump and its re-recorded fixtures land in the SAME COMMIT:
# tests/test_minigrid_replay.nim test 32 sweeps tests/ and fails the build on a
# fixture recorded against older rules, because such a fixture still LOADS (the
# version string is only compared, not the rules) and then re-simulates wrong.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"

out="${1:-tests/replays}"
nim c -r -d:release --hints:off --path:src tools/record_fixture.nim "${out}"

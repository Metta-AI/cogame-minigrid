"""Exercise complete headless games through the public JSONL training protocol."""

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def request(process: subprocess.Popen[str], command: dict) -> dict:
    assert process.stdin is not None and process.stdout is not None
    process.stdin.write(json.dumps(command) + "\n")
    process.stdin.flush()
    return json.loads(process.stdout.readline())


with tempfile.TemporaryDirectory() as directory:
    binary = Path(directory) / "minigrid-training-bridge"
    subprocess.run(
        ["nim", "c", "--hints:off", "--path:src", f"--out:{binary}",
         "src/minigrid/training_bridge.nim"],
        cwd=ROOT,
        check=True,
    )
    for variant in ("gauntlet", "xland"):
        for seed in ("7", "19"):
            with subprocess.Popen(
                [str(binary), variant], cwd=ROOT, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, text=True,
            ) as process:
                observation = request(process, {"kind": "reset", "seed": seed, "players": 4})
                decisions = 0
                while observation["kind"] == "decision":
                    assert 0 <= observation["seat"] < 4
                    assert observation["decision_id"] == decisions
                    visible = json.loads(observation["messages"][1]["content"])
                    assert visible["lane"] == observation["seat"]
                    assert "seed" not in visible and "scores" not in visible
                    stale = request(process, {"kind": "step", "decision_id": -1,
                                              "response": "{}"})
                    assert stale["kind"] == "rejected"
                    invalid = request(process, {"kind": "step", "decision_id": decisions,
                                                "response": "not JSON"})
                    assert invalid["kind"] == "rejected"
                    teacher = request(process, {"kind": "teacher"})["response"]
                    assert isinstance(json.loads(teacher)["actions"], list)
                    result = request(process, {"kind": "step",
                                               "decision_id": decisions,
                                               "response": teacher})
                    assert result["kind"] == "accepted"
                    assert result["action"]["actions"] == json.loads(teacher)["actions"]
                    observation = result["observation"]
                    decisions += 1
                    assert decisions <= 120
                assert observation["kind"] == "terminal"
                assert set(observation["scores"]) == {"0", "1", "2", "3"}
                assert len(set(observation["scores"].values())) == 1
                assert 0 < decisions <= 120
            assert process.returncode == 0
            print(variant, seed, decisions, observation["scores"]["0"])

"""Exercise both MiniGrid ladders through the numeric candidate protocol."""

import json
import random
import subprocess
import sys
from pathlib import Path


BINARY = Path(sys.argv[1]).resolve()


def play(variant: str, teacher: bool) -> None:
    process = subprocess.Popen(
        [str(BINARY), variant], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True, bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(17)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": f"mini-{variant}-{teacher}", "players": 4})
        widths = set()
        decisions = 0
        tasks = set()
        while observation["kind"] == "decision":
            encoding = request({"kind": "encode"})
            assert encoding["decision_id"] == observation["decision_id"]
            widths.add(len(encoding["values"]))
            assert len(encoding["actions"]) == 182
            assert encoding["actions"][0] == {"choice": 0}
            view = observation["semantic_view"]
            assert "seed" not in view and "scores" not in view
            assert view["lane"] == observation["seat"]
            assert json.loads(observation["messages"][1]["content"]) == view
            tasks.add(view["task"]["index"])
            if teacher:
                action = json.loads(request({"kind": "teacher"})["response"])
            else:
                action = rng.choice([choice for choice in encoding["actions"] if choice is not None])
            result = request({"kind": "step", "decision_id": observation["decision_id"],
                              "response": json.dumps(action)})
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions <= 120
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == {str(i) for i in range(4)}
        assert widths == {1295} and tasks == {1, 2, 3, 4, 5}
        print(variant, "teacher" if teacher else "random", decisions, observation["scores"])
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


def check_simultaneous_views() -> None:
    views = []
    for choice in (0, 3):
        process = subprocess.Popen(
            [str(BINARY)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1,
        )
        assert process.stdin is not None and process.stdout is not None

        def request(payload: dict) -> dict:
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        request({"kind": "reset", "seed": "mini-simultaneous", "players": 4})
        views.append(request({"kind": "step", "decision_id": 0,
                              "response": json.dumps({"choice": choice})})["observation"]["semantic_view"])
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0
    assert views[0] == views[1]


if __name__ == "__main__":
    check_simultaneous_views()
    for variant in ("gauntlet", "xland"):
        for teacher in (True, False):
            play(variant, teacher)

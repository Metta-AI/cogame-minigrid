## Every shard, run from the repo ROOT: `nim c -r tests/shards/tests.nim`.
## ci.yml runs each tests/*.nim file individually instead, in BOTH debug and
## release; the shards are the local convenience entry point.
import shard_1, shard_2, shard_3, shard_4

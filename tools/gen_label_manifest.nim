## Emits tests/label_manifest.txt — the board-label vocabulary contract.
##   nim c -r --path:src tools/gen_label_manifest.nim > tests/label_manifest.txt
import minigrid/labels
stdout.write(labelManifest())

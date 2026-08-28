## The board-label vocabulary contract. `tests/label_manifest.txt` pins the
## exact set of strings this game may draw on the board, and
## `tests/test_minigrid_labels.nim` regenerates it — a label change and its
## manifest update land in the same commit.
##
## Scoped, like the starter's, to the POLICY contract: the words a cog can see
## or that name a cog. Spectator chrome strings live in the viewer and are
## covered by `tests/test_minigrid_endcard_labels.nim` instead.

import std/[algorithm, sequtils, strutils]
import sim

proc boardLabels*(): seq[string] =
  ## Every string the board may draw, in sorted order.
  for family in TaskFamily:
    result.add(toUpperAscii($family))
  for colour in Colours:
    result.add($colour)
  for kind in [ckKey, ckBall, ckBox, ckDoor, ckGoal, ckLava, ckWall]:
    result.add($kind)
  for dir in Dirs:
    result.add(toUpperAscii($dir))
  for primitive in Primitive:
    result.add($primitive)
  result.add(seatAlias(0))
  result.sort()
  result = deduplicate(result)

proc labelManifest*(): string =
  boardLabels().join("\n") & "\n"

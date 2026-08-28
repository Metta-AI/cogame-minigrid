## Endcard and chrome label re-mapping — design note §Tests item 40.
##
## A forked ctf endcard silently ships paintbot's vocabulary: nothing in the
## starter's tests, in `viewer_smoke.mjs` or in the label manifest covers
## SPECTATOR chrome strings, because `labels.nim` deliberately scopes itself to
## the POLICY contract. The re-labelings are therefore enumerated in the design
## note and enforced here.
##
## SCOPE. This test greps the strings a SPECTATOR READS — element text, CSS
## `content:` values and `title` / `aria-label` attributes — not class names or
## JS identifiers. `.hillchip` and `#lives-red` survive as INHERITED SELECTORS
## because the starter's own `renderScorebug` writes through them; removing
## them would mean rewriting the starter's renderer, which is exactly the
## rewrite the "chrome verbatim" pin forbids. Their VISIBLE TEXT is re-mapped,
## and that is what this test measures. The surviving selectors are listed
## below so the divergence is explicit rather than incidental.

import std/[strutils, unittest]
import helpers

const
  ## Spectator-facing paintbot vocabulary that must not survive.
  Forbidden = ["Lives left", "Hill time", "LIVES LEAD", ">Lives<", ">Hill<",
               ">Clstr<", ">Cap<", ">Tags<", ">Paint<", ">K<", ">D<",
               "Filling hoppers", "In the locker room", ">EYES<",
               "showing recorded inputs", "kills / flag story"]
  ## Each re-mapped string, present exactly once.
  Remapped = [
    "<span>Task</span><span>Mission</span><span>Result</span><span>Turns</span><span>Credits</span>",
    "<span>Cog</span><span>Solved</span><span>Seen</span><span>Score</span>",
    "<span class=\"fl-cap\">Tasks solved</span>",
    "<span class=\"fl-cap\">Cells seen</span>",
    "<span class=\"momentum-label\">PROGRESS</span>",
    "<span class=\"solved-label pb-lbl\">Carrying</span>",
    "<span class=\"solved-label\">Solved</span>",
    "Reading the mission…",
    "Waiting for the cog",
    "showing recorded actions",
    "<div class=\"fpv-cap\" id=\"fpv-cap\">AGENT VIEW 7×7</div>",
    "Spoilers: solved / failed tasks on the timeline ahead of the playhead (o)"]
  ## Inherited SELECTORS the starter's own renderers write through. Documented
  ## divergence: the names stay, the visible text is re-mapped.
  InheritedSelectors = ["hillchip", "lives-num", "lives-line", "pb-lbl"]

suite "minigrid endcard labels":

  test "40. no spectator-facing paintbot vocabulary survives":
    let page = readRepo("client/replay_broadcast.html")
    for phrase in Forbidden:
      if phrase in page:
        checkpoint("forbidden spectator string still in the page: " & phrase)
      check phrase notin page
    for phrase in Remapped:
      var count = 0
      var cursor = 0
      while true:
        let hit = page.find(phrase, cursor)
        if hit < 0: break
        inc count
        cursor = hit + 1
      if count != 1:
        checkpoint("re-mapped string appears " & $count & " times: " & phrase)
      check count == 1
    ## The documented divergence is real and bounded: these selectors survive,
    ## and nothing else paintbot-shaped does.
    for selector in InheritedSelectors:
      check selector in page

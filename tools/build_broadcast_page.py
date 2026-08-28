#!/usr/bin/env python3
"""Derive `client/replay_broadcast.html` from the coworld-ctf starter page.

The pin is "the starter's page PLUS an appended game block" — never a
from-scratch page that reuses the starter's ids (cogame-gridlock, 2026-08-23).
So the committed page is DERIVED, not authored: this script takes the
starter's bytes, applies an EXPLICIT, ENUMERATED edit list (the elements the
design note lists as removed and the vocabulary re-mapping table), and appends
`client/minigrid_block.html` under the banner comment.

Every edit is an exact-substring replacement that must match exactly once, so
a starter change that invalidates an edit fails loudly here instead of
silently shipping a half-edited page.

    python3 tools/build_broadcast_page.py --starter /workspace/starters/coworld-ctf
    python3 tools/build_broadcast_page.py --starter <path> --check

`--check` re-derives the page and diffs it against the committed one. CI runs
it only when the starter mount is present; `tests/test_minigrid_viewer.nim`
asserts the committed artifact's structure unconditionally.
"""
import argparse
import difflib
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --- the elements the design note lists as removed -------------------------
# Markup blocks, matched exactly. `#viewpanel` goes entirely: the board is a
# fixed 13x13 grid with no off-frame area, so per the pin a fixed arena drops
# the zoom bar and the minimap.
MARKUP_REMOVALS = [
    # #viewpanel: minimap + zoom bar, with its explanatory comment
    ("""    <!-- View controls: zoom the board with buttons/slider/keys/pinch (never a
         plain scroll — that belongs to the page), and once zoomed, a minimap
         with a white view box says which part of the board you are holding.
         Click or drag the minimap to jump the view there. -->
    <div id="viewpanel">
      <div id="minimap" title="Click or drag to move the view">
        <canvas id="minimap-canvas"></canvas>
        <span class="mm-cap">View</span>
      </div>
      <div id="zoombar" role="group" aria-label="Board zoom">
        <button class="zbtn" id="zoom-out" title="Zoom out (x)" aria-label="Zoom out">&minus;</button>
        <input id="zoom-slider" type="range" min="0" max="1000" step="1" value="0"
               aria-label="Board zoom" aria-valuetext="Fitted">
        <button class="zbtn" id="zoom-in" title="Zoom in (z)" aria-label="Zoom in">+</button>
        <span id="zoom-read" aria-live="off">FIT</span>
      </div>
    </div>
""", """    <!-- MINIGRID: the view-controls panel is REMOVED. The board is a fixed
         13x13 cell grid with no off-frame area — relayout() letterboxes it
         whole at every width — so there is nothing to zoom into and nothing
         for a minimap to locate. -->
"""),
    # #povBadge: with one seat there is nothing to select
    ("""    <div id="povBadge">👁 POV lens — click to clear</div>
""", """    <!-- MINIGRID: the POV badge is REMOVED — one seat, nothing to select. -->
"""),
    # inside the KEPT #fpv: the cog has no hit points and no gear
    ("""        <span class="fpv-hp" id="fpv-hp"></span>
        <span class="fpv-gear" id="fpv-gear"></span>
""", """        <!-- MINIGRID: hit-point pips and the gear line are REMOVED. -->
"""),
    # the un-fogged tactical inset is redundant when the main board IS it
    ("""      <!-- Un-fogged tactical minimap: arena walls + all units + hearts + the
           POV seat's vision wedge. Full context, no fog of war. -->
      <div class="fpv-map" id="fpv-map">
        <canvas id="fpv-map-canvas"></canvas>
      </div>
""", """      <!-- MINIGRID: the un-fogged tactical inset is REMOVED — the main
           board already IS the un-fogged view; this panel now draws the
           agent's own 7x7 window instead. -->
"""),
]

# --- JS re-pointing --------------------------------------------------------
# The starter's wiring for the removed elements is LEFT INTACT and pointed at
# DETACHED nodes. That keeps every code path alive and byte-identical in
# behaviour while no removed id survives in the document — the alternative,
# excising the wiring, is the rewrite the pin forbids.
JS_REWRITES = [
    ("""    var badge = $('povBadge');""",
     """    var badge = mgDetached('div');   // MINIGRID: POV badge removed"""),
    ("""  // pov clear (togglePov lives in the shared chrome, driven via ctx.sendPov)
  $('povBadge').addEventListener('click', function () { send('v:-1'); });""",
     """  // MINIGRID: the POV-clear click target is removed with its badge."""),
    ("""    var hpEl = $('fpv-hp'), hpHtml = '';""",
     """    var hpEl = mgDetached('span'), hpHtml = '';   // MINIGRID: no hit points"""),
    ("""    var gearEl = $('fpv-gear'), bits = [];""",
     """    var gearEl = mgDetached('span'), bits = [];   // MINIGRID: no gear"""),
    ("""  var fpvMapEl = $('fpv-map'), fpvMapCanvas = $('fpv-map-canvas'), fpvMapCtx = null;""",
     """  var fpvMapEl = mgDetached('div'), fpvMapCanvas = mgDetached('canvas'),
      fpvMapCtx = null;   // MINIGRID: the tactical inset is removed"""),
    ("""  var minimapBox = $('minimap');
  var zoomSlider = $('zoom-slider');
  var zoomRead = $('zoom-read');
  var btnZoomIn = $('zoom-in');
  var btnZoomOut = $('zoom-out');""",
     """  // MINIGRID: the view-controls panel is removed, so its wiring — kept
  // verbatim below — drives detached nodes and touches nothing on the page.
  var minimapBox = mgDetached('div');
  var zoomSlider = mgDetached('input');
  var zoomRead = mgDetached('span');
  var btnZoomIn = mgDetached('button');
  var btnZoomOut = mgDetached('button');"""),
    ("""  // ?viewpanel=0 hides the #viewpanel overlay (zoom bar + minimap). This is an
  // explicit opt-OUT only — the default (param absent) is unchanged for every
  // existing embed, so the League Replayer still shows zoom + minimap. See the
  // #271/#272 lesson: hiding the panel for ALL embeds broke the Replayer shell.
  // Billboards (Lobby hero) and thumbnail capture append &viewpanel=0.
  try {
    if (new URLSearchParams(location.search).get('viewpanel') === '0')
      document.body.setAttribute('data-noviewpanel', '1');
  } catch (e) {}
""",
     """  // MINIGRID: the opt-out param goes with the panel it hid.
"""),
    ("""  core.attachMinimap($('minimap-canvas'));""",
     """  // MINIGRID: nothing to attach — broadcast_core.js tolerates never being
  // attached (its surface stays null and its draw returns on the first guard)."""),
]

# The detached-node helper, injected right after the page's own `$` alias.
DETACHED_HELPER = ("""  var $ = C.$;""", """  var $ = C.$;
  // MINIGRID: a DETACHED stand-in for an element this game removed. The
  // starter's wiring for those elements is kept verbatim and pointed here, so
  // it runs harmlessly and no removed id exists in the document.
  function mgDetached(tag) { return document.createElement(tag); }""")

# --- the vocabulary re-mapping table (design note, §Viewer) -----------------
VOCABULARY = [
    ("""<div class="ec-thead"><span>Player</span><span>K</span><span>D</span><span>Clstr</span><span>Cap</span></div>""",
     """<div class="ec-thead"><span>Task</span><span>Mission</span><span>Result</span><span>Turns</span><span>Credits</span></div>"""),
    ("""<div class="ec-thead"><span>Cog</span><span>Tags</span><span>Out</span><span>Paint</span></div>""",
     """<div class="ec-thead"><span>Cog</span><span>Solved</span><span>Seen</span><span>Score</span></div>"""),
    ("""<span class="fl-cap">Lives left</span>""",
     """<span class="fl-cap">Tasks solved</span>"""),
    ("""<span class="fl-cap">Hill time</span>""",
     """<span class="fl-cap">Cells seen</span>"""),
    ("""<span class="momentum-label">LIVES LEAD</span>""",
     """<span class="momentum-label">PROGRESS</span>"""),
    ("""<span class="lives-label pb-lbl">Hill</span>""",
     """<span class="solved-label pb-lbl">Carrying</span>"""),
    ("""<span class="lives-label">Lives</span>""",
     """<span class="solved-label">Solved</span>"""),
    # The locker-room loading scene: the plate is the starter's, the
    # prep-talk lines are re-written for a cog reading a mission sentence.
    ("""Filling hoppers with fresh paint&hellip;""",
     """Reading the mission&hellip;"""),
    ("""      'Filling hoppers with fresh paint…',
      'Pump check: one, two. One, two…',
      'Polishing visors to a mirror shine…',
      'Shaking the paint pods awake…',
      'Squats. Even robots warm up…',
      'Topping off the CO₂…',
      'Chalking up the wheels…',
      'Reviewing the game plan…'""",
     """      'Reading the mission…',
      'Counting the cells you can see…',
      'Colour-checking the keys…',
      'Listening for the door…',
      'Mapping the dark from memory…',
      'Measuring the gap in the lava…',
      'Turning to face the unknown…',
      'Five tasks. Eleven turns each…'"""),
    ("""In the locker room""", """Waiting for the cog"""),
    ("""Replay hash mismatch — showing recorded inputs""",
     """Replay hash mismatch — showing recorded actions"""),
    ("""<div class="fpv-cap" id="fpv-cap">EYES</div>""",
     """<div class="fpv-cap" id="fpv-cap">AGENT VIEW 7×7</div>"""),
    ("""title="Spoilers: kills / flag story / winner on the timeline ahead of the playhead (o)\"""",
     """title="Spoilers: solved / failed tasks on the timeline ahead of the playhead (o)\""""),
]

# --- CSS rules for kinds this game never emits -----------------------------
# tests/test_minigrid_viewer.nim asserts the set of `.beat-marker.<kind>`
# rules equals exactly the kinds the sim emits.
DEAD_BEAT_KINDS = ["kill", "steal", "return", "capture",
                   "gamestart", "hillflip", "tagout", "gameover"]
# Every id/class the design note removes; a surviving mention fails the check.
REMOVED_NAMES = ["viewpanel", "minimap", "zoombar", "zoom-in", "zoom-out",
                 "zoom-slider", "zoom-read", "povBadge", "fpv-hp", "fpv-gear",
                 "fpv-map", "noviewpanel", "mm-cap", "zbtn"]

BANNER = "MINIGRID additions to the inherited coworld-ctf chrome"


def strip_css_comments(text, predicate):
    """Delete CSS comments that mention a name this game removed."""
    out = []
    i = 0
    while True:
        start = text.find("/*", i)
        if start < 0:
            out.append(text[i:])
            break
        end = text.find("*/", start)
        if end < 0:
            out.append(text[i:])
            break
        body = text[start:end + 2]
        out.append(text[i:start])
        if not predicate(body):
            out.append(body)
        i = end + 2
    return "".join(out)


def strip_css_rules(text, predicate):
    """Delete top-level CSS rules whose selector matches `predicate`."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        brace = text.find("{", i)
        if brace < 0:
            out.append(text[i:])
            break
        # A rule's selector starts after the previous '}' or ';'. When neither
        # is in range the selector starts at the cursor — NOT at 0, which
        # would drag the whole preceding file into the selector text and make
        # the at-rule guard below reject every rule after the first @media.
        last = max(text.rfind("}", i, brace), text.rfind(";", i, brace))
        start = i if last < 0 else last + 1
        selector = text[start:brace]
        depth = 0
        j = brace
        while j < n:
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        end = j + 1
        # At-rules wrap nested rules, so they are never removed wholesale;
        # their contents are scanned on the next pass through this function.
        bare = re.sub(r"/\*.*?\*/", " ", selector, flags=re.S)
        if predicate(selector) and "@" not in bare:
            out.append(text[i:start])
            i = end
            while i < n and text[i] == "\n":
                i += 1
            continue
        out.append(text[i:end])
        i = end
    return "".join(out)


def apply_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            "::error::edit %r matched %d times (expected exactly 1) — the "
            "starter page changed; update tools/build_broadcast_page.py"
            % (label, count))
    return text.replace(old, new)


def build(starter_page, block):
    text = starter_page

    for old, new in MARKUP_REMOVALS:
        text = apply_once(text, old, new, old[:60])
    text = apply_once(text, *DETACHED_HELPER, label="detached helper")
    for old, new in JS_REWRITES:
        text = apply_once(text, old, new, old[:60])
    for old, new in VOCABULARY:
        text = apply_once(text, old, new, old[:60])

    # Drop the CSS for beat kinds this game never emits and for the removed
    # elements.
    def dead(sel):
        s = sel.strip()
        for kind in DEAD_BEAT_KINDS:
            if ".beat-marker." + kind in s:
                return True
        for name in REMOVED_NAMES:
            if "#" + name in s or "." + name in s:
                return True
        return False

    def dead_comment(body):
        for name in REMOVED_NAMES:
            if name in body:
                return True
        for kind in DEAD_BEAT_KINDS:
            if ".beat-marker." + kind in body:
                return True
        return False

    # Only the <style> sections are CSS; running the rule scanner over the
    # whole document would desync its brace matching on the inline scripts.
    def edit_styles(page, fn):
        pieces = []
        cursor = 0
        while True:
            open_tag = page.find("<style>", cursor)
            if open_tag < 0:
                pieces.append(page[cursor:])
                break
            close_tag = page.find("</style>", open_tag)
            if close_tag < 0:
                pieces.append(page[cursor:])
                break
            body_start = open_tag + len("<style>")
            pieces.append(page[cursor:body_start])
            pieces.append(fn(page[body_start:close_tag]))
            cursor = close_tag
        return "".join(pieces)

    text = edit_styles(text, lambda css: strip_css_rules(css, dead))
    text = edit_styles(text, lambda css: strip_css_comments(css, dead_comment))

    # Cut the starter's own game block (everything from its banner comment)
    # and append this game's.
    marker = text.find("<!-- ============================================================\n     PAINTBALL additions")
    if marker < 0:
        raise SystemExit("::error::the starter's game-block banner is missing")
    prefix = text[:marker]
    text = prefix + block

    # The splice hook keeps its signatures; only the namespace is renamed.
    text = text.replace("window.PaintballChrome", "window.MinigridChrome")

    leftovers = sorted({n for n in REMOVED_NAMES
                        if re.search(r"[#'\"\.]" + re.escape(n) + r"\b", text)})
    if leftovers:
        raise SystemExit("::error::removed element names survive: %s"
                         % ", ".join(leftovers))
    return text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--starter", default="/workspace/starters/coworld-ctf")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    starter_path = os.path.join(args.starter, "client", "replay_broadcast.html")
    if not os.path.exists(starter_path):
        print("starter page not present at %s; nothing to re-derive"
              % starter_path)
        return 0
    with open(starter_path, encoding="utf-8") as handle:
        starter_page = handle.read()
    with open(os.path.join(REPO, "client", "minigrid_block.html"),
              encoding="utf-8") as handle:
        block = handle.read()

    built = build(starter_page, block)
    target = os.path.join(REPO, "client", "replay_broadcast.html")
    if args.check:
        with open(target, encoding="utf-8") as handle:
            current = handle.read()
        if current != built:
            diff = difflib.unified_diff(current.splitlines(),
                                        built.splitlines(),
                                        "committed", "re-derived", lineterm="")
            print("\n".join(list(diff)[:200]))
            raise SystemExit(
                "::error::client/replay_broadcast.html is not the derived page")
        print("client/replay_broadcast.html matches the derivation")
        return 0
    with open(target, "w", encoding="utf-8") as handle:
        handle.write(built)
    print("wrote client/replay_broadcast.html (%d bytes)" % len(built))
    return 0


if __name__ == "__main__":
    sys.exit(main())

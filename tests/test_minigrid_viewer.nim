## Viewer — design note §Tests items 35..39 and 41.

import std/[algorithm, os, sequtils, strutils, unittest]
import minigrid/[sim, labels, broadcast]
import minigrid/global as board
import helpers

const
  ## The starter's chrome, byte-for-byte. Not edited, not reformatted.
  ChromeCommonSha256 =
    "7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c"
  ## The exact ids the design note lists as REMOVED, and the exact ids it
  ## lists as KEPT.
  RemovedIds = ["viewpanel", "minimap", "zoombar", "zoom-in", "zoom-out",
                "zoom-slider", "zoom-read", "fpv-hp", "fpv-gear",
                "fpv-map", "fpv-map-canvas"]
  KeptIds = ["viewport", "stage", "board", "lightpool", "grain", "lockerroom",
             "lk-bg", "lk-art", "lk-sprites", "lk-cap", "chrome", "scorebug",
             "plates-l", "plates-r", "clock", "clock-time", "clock-caption",
             "ffwd-mini", "fpv", "fpv-canvas", "fpv-hud", "fpv-name",
             "fpv-cap", "fpv-grip", "bannerlane", "killfeed", "mmwarn",
             "transport", "btn-restart", "btn-back", "btn-play", "btn-fwd",
             "btn-end", "btn-loop", "btn-skip", "btn-spoilers", "ffwd-chip",
             "win-chip", "tick-clock", "speedchips", "scrub", "momentum",
             "scrub-fill", "lulls", "scrub-win", "scrub-head", "endcard",
             "ec-headline", "ec-wincond", "ec-how", "ec-teams", "ec-replay",
             "status", "povBadge"]
             ## `povBadge` is RESTORED with the four lanes: there IS something
             ## to select now.
  ## The beat kinds this sim emits, and no others.
  BeatKinds = ["taskstart", "solved", "failed", "unlock", "produce",
               "fallback", "end"]
  ## The kinds that carry a LANE, and the lane classes they carry.
  LaneBeatKinds = ["solved", "failed", "unlock", "produce", "fallback"]
  LaneClasses = ["lane0", "lane1", "lane2", "lane3"]
  ## Every kind the feed table draws a row for.
  FedKinds = ["taskstart", "say", "plan", "pickup", "drop", "open", "close",
              "unlock", "produce", "subgoal", "lava", "crash", "solved",
              "failed", "fallback", "budget"]

proc sha256Hex(data: string): string =
  ## The repo has no sha256 in std, so the pin is checked with a portable
  ## implementation over the exact bytes.
  const K = [
    0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
    0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
    0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
    0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
    0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
    0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
    0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
    0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
    0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
    0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
    0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
    0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
    0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
    0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
    0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
    0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]
  var h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
           0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  var message = data
  let bitLen = uint64(data.len) * 8
  message.add('\x80')
  while message.len mod 64 != 56:
    message.add('\x00')
  for shift in countdown(56, 0, 8):
    message.add(char((bitLen shr uint64(shift)) and 0xff'u64))
  proc rotr(x: uint32, n: int): uint32 = (x shr n) or (x shl (32 - n))
  var w: array[64, uint32]
  for block0 in countup(0, message.len - 1, 64):
    for i in 0 ..< 16:
      w[i] = (uint32(uint8(message[block0 + i * 4])) shl 24) or
             (uint32(uint8(message[block0 + i * 4 + 1])) shl 16) or
             (uint32(uint8(message[block0 + i * 4 + 2])) shl 8) or
              uint32(uint8(message[block0 + i * 4 + 3]))
    for i in 16 ..< 64:
      let s0 = rotr(w[i - 15], 7) xor rotr(w[i - 15], 18) xor (w[i - 15] shr 3)
      let s1 = rotr(w[i - 2], 17) xor rotr(w[i - 2], 19) xor (w[i - 2] shr 10)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
    var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5],
                                     h[6], h[7])
    for i in 0 ..< 64:
      let s1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
      let ch = (e and f) xor ((not e) and g)
      let t1 = hh + s1 + ch + K[i] + w[i]
      let s0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
      let maj = (a and b) xor (a and c) xor (b and c)
      let t2 = s0 + maj
      hh = g; g = f; f = e; e = d + t1
      d = c; c = b; b = a; a = t1 + t2
    h[0] += a; h[1] += b; h[2] += c; h[3] += d
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh
  for value in h:
    result.add(toHex(int(value), 8).toLowerAscii())

suite "minigrid viewer":
  let page = readRepo("client/replay_broadcast.html")
  let core = readRepo("client/broadcast_core.js")

  test "35. chrome_common.js is BYTE-IDENTICAL to the starter's":
    let chrome = readRepo("client/chrome_common.js")
    check chrome.len == 40022
    check sha256Hex(chrome) == ChromeCommonSha256

  test "36. the broadcast page is the starter's plus an appended block":
    ## The page is DERIVED from the starter by tools/build_broadcast_page.py:
    ## the starter's chrome, the enumerated element removals and vocabulary
    ## re-map, then the game block under its banner. A from-scratch page that
    ## reuses the starter's ids is a rewrite and fails review.
    let banner = "MINIGRID additions to the inherited coworld-ctf chrome"
    check banner in page
    let split = page.find(banner)
    ## Everything the block adds comes AFTER the banner.
    check "window.MinigridChrome" in page[split .. ^1]
    check "function mgBeat" in page[split .. ^1]
    ## The starter's own splice hook, with the same entry points and
    ## signatures.
    check "MinigridChrome.install(PB_CTX)" in page
    check "install: function (ctx)" in page[split .. ^1]
    check "frame: mgFrame" in page[split .. ^1]
    check "event: mgEvent" in page[split .. ^1]
    ## The inherited chrome, untouched, sits BEFORE the banner.
    let prefix = page[0 ..< split]
    for marker in ["function relayout()", "window.ChromeCommon", "renderTransport",
                   "ingestBeats", "renderMomentum", "function pushFeed(row)",
                   "core.start()", "embed=1"]:
      check marker in prefix
    ## broadcast_core.js keeps the starter's procs and pushFeed's signature
    ## (the cogball 0.1.4 latch scar).
    for proc0 in ["function BroadcastCore(config)", "function composite()",
                  "function parse(bytes)", "function attachMinimap(surface)",
                  "function setViewportFit()", "function getTransform()",
                  "function sendCommand(text)", "function drawObject(targetCtx, obj)",
                  "function blitObject(layer, obj)", "function draw()"]:
      check proc0 in core
    check "function pushFeed(row)" in page
    ## The page is DERIVED, and the block region must still BE
    ## client/minigrid_block.html — the file the AGENTS guide says to edit.
    ## Nothing in CI can re-derive the page (the runner has no starter
    ## checkout), so this is what catches a hand-edit of the derived artifact
    ## that never went back into its source.
    let blockFile = readRepo("client/minigrid_block.html")
    check page.endsWith(blockFile.replace("window.PaintballChrome",
                                          "window.MinigridChrome"))
    ## The ONLY edit to the starter's compositor is the wire namespace.
    check "window.MINIGRID_WIRE" in core
    check "window.CTF_WIRE &&" notin core

  test "37. no shadowed chrome aliases":
    ## The chrome alias block declares the shared beat builder with a hoisted
    ## `var markBeat`; a game-block function of that name would be silently
    ## swallowed and the scrubber would end up with unlabelled div markers
    ## that never seek (cogame-tandem, 2026-08-23).
    let split = page.find("MINIGRID additions to the inherited coworld-ctf chrome")
    let block0 = page[split .. ^1]
    var aliases: seq[string]
    for line in page[0 ..< split].splitLines():
      let trimmed = line.strip()
      if not trimmed.startsWith("var ") or " = C." notin trimmed:
        continue
      for part in trimmed[4 .. ^1].split(","):
        let name = part.split("=")[0].strip()
        if name.len > 0 and name.allCharsInSet({'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}):
          aliases.add(name)
    check aliases.len > 10
    check "markBeat" in aliases
    for alias in aliases:
      check ("function " & alias & "(") notin block0
      check ("var " & alias & " =") notin block0
    check "function mgBeat" in block0

  test "38. beat CSS matches EXACTLY the emitted kinds x lanes (22 rules)":
    var css: seq[string]
    var cursor = 0
    while true:
      let hit = page.find(".beat-marker.", cursor)
      if hit < 0: break
      var name = ""
      var i = hit + len(".beat-marker.")
      while i < page.len and page[i] in {'a' .. 'z'}:
        name.add(page[i])
        inc i
      if name.len > 0 and name notin css:
        css.add(name)
      cursor = hit + 1
    css.sort()
    var expected = @BeatKinds
    expected.sort()
    check css == expected
    ## Every kind is emitted by the sim, and the game block never calls the
    ## shared markBeat (so an unlabelled div marker cannot appear).
    for kind in BeatKinds:
      var found = false
      for value in EventKind:
        if $value == kind and value.isBeat():
          found = true
      check found
    ## EXACTLY 22 kind rules: the five LANE-SPECIFIC kinds x four lane
    ## classes, plus bare `taskstart` and bare `end`. No more and no fewer.
    var rules: seq[string]
    var scan = 0
    while true:
      let hit = page.find(".beat-marker.", scan)
      if hit < 0: break
      var selector = ""
      var i = hit + len(".beat-marker.")
      while i < page.len and page[i] in {'a' .. 'z', '0' .. '9', '.'}:
        selector.add(page[i])
        inc i
      if selector.len > 0 and selector notin rules:
        rules.add(selector)
      scan = hit + 1
    rules.sort()
    var expectedRules: seq[string]
    for kind in LaneBeatKinds:
      for lane in LaneClasses:
        expectedRules.add(kind & "." & lane)
    expectedRules.add("taskstart")
    expectedRules.add("end")
    expectedRules.sort()
    check rules.len == 22
    check rules == expectedRules

  test "39. transport, endcard, the gutters and the 360 px rules":
    ## relayout() owns --band / --topband / --hudscale on :root.
    check "setProperty('--hudscale'" in page
    check "setProperty('--band'" in page
    check "setProperty('--topband'" in page
    ## The endcard stops at the band and every seek dismisses it.
    check "bottom: var(--band, 0px)" in page
    check "$('endcard').classList.remove('on')" in page
    let split = page.find("MINIGRID additions to the inherited coworld-ctf chrome")
    let block0 = page[split .. ^1]
    ## NOTHING this game adds is positioned inside the transport band, and
    ## nothing is drawn over the board: the added readouts live in the
    ## LETTERBOX GUTTERS, measured every frame from the stage rect and clamped
    ## between --topband and --band.
    check "--topband" in block0
    check "--band" in block0
    check "getBoundingClientRect" in block0
    check "id = 'mg-gut-l'" in block0
    check "id = 'mg-gut-r'" in block0
    check "position: fixed" notin block0
    ## The POV inset and the feed are the STARTER'S OWN elements, MOVED into
    ## the gutter — never re-implemented.
    check "mgEl('mg-pov').appendChild(fpv)" in block0
    check "mgEl('mg-feed').appendChild(feed)" in block0
    ## The .tiny rules this game adds.
    check ".plate-name {" in block0
    check "flex: 1 1 auto;" in block0
    check "min-width: 3.2em;" in block0
    for rule in ["#stage.tiny .plate .mg-alias", "#stage.tiny .plate .mg-carry",
                 "#stage.tiny #mg-ribbon .mg-mission", "#stage.tiny #mg-pips",
                 "#stage.tiny #fpv-grip"]:
      check rule in block0
    ## The starter's own 360 px engineering, kept verbatim.
    check "Math.max(0.5, Math.min(1.6, boardW / 760))" in page
    check "stage.classList.toggle('tiny', boardW <= 620)" in page
    ## Removed ids appear NOWHERE; kept ids are all present.
    for name in RemovedIds:
      check ("id=\"" & name & "\"") notin page
      check ("#" & name) notin page
      check ("'" & name & "'") notin page
    for name in KeptIds:
      check ("id=\"" & name & "\"") in page

  test "52. ONE axis: scrubAxis() has EXACTLY five consumers":
    ## v1's click at 100 % landed at tick 158 of 315 because the click
    ## handler, the fill, the head, the beats and the lull shading each did
    ## their own arithmetic. There is now ONE function and nothing computes
    ## its own denominator.
    let split = page.find("MINIGRID additions to the inherited coworld-ctf chrome")
    let block0 = page[split .. ^1]
    var definitions = 0
    var calls = 0
    var cursor = 0
    while true:
      let hit = block0.find("mgScrubAxis(", cursor)
      if hit < 0: break
      if block0[max(0, hit - 9) ..< hit] == "function ": inc definitions
      else: inc calls
      cursor = hit + 1
    check definitions == 1
    check calls == 5
    ## The five, each named at its call site.
    for consumer in ["consumer 1 of 5", "consumer 2 of 5", "consumer 3 of 5",
                     "consumer 4 of 5", "consumer 5 of 5"]:
      check consumer in block0
    ## f = 1.0 lands on `last`: first + round(f * span), and NOTHING else maps
    ## a fraction to a tick.
    check "axis.first + Math.round(f * axis.span)" in block0
    ## The page's own click handler DELEGATES to it, so a click and the
    ## rendered playhead cannot disagree.
    check "window.MinigridChrome.seekFraction(frac)" in page
    check "seekFraction: mgSeekFraction" in block0
    ## Every readout is recomputed on EVERY frame, jumped included: the frame
    ## entry point takes `jumped` and does not return early on it.
    check "function mgFrame(s, ctx, jumped)" in block0
    check "if (jumped) return" notin block0
    ## and the clock caption carries the playhead tick, so a stale caption is
    ## visible (v1 read TICK 299 after a seek back to 158).
    check "'tick ' + s.t + '/' + mg.maxTicks" in block0

  test "54. the feed is a TABLE, and `say` rows are never dropped":
    let split = page.find("MINIGRID additions to the inherited coworld-ctf chrome")
    let block0 = page[split .. ^1]
    ## One table, one push path: every row goes through the starter's own
    ## ctx.pushFeed.
    check "function mgRow(e)" in block0
    check "CTX.pushFeed(el)" in block0
    for kind in FedKinds:
      check ("case '" & kind & "':") in block0
    ## `turn` and `end` are NOT fed — the clock and the endcard carry them.
    check "// ONE table" in block0
    ## `say` is never dropped on overflow.
    check "r.kind === 'say'" in block0
    check "kept.concat(" in block0
    ## Phase 1's taskstart row is pushed on the FIRST DRAWN FRAME, so
    ## feed_lines >= 1 at load — the verifier measured 0.
    check "function mgSeedFeed(s, mg)" in block0
    check "mgSeedFeed(s, mg);" in block0
    ## and the feed is FINDABLE by the shared viewer smoke, which looks for
    ## `#feed, .feed, #log, [id$="-feed"]`: `#killfeed` matches none of them.
    check "id=\"mg-feed\"" in page or "id = 'mg-feed'" in page or
      "'<div id=\"mg-feed\"></div>'" in page
    check "mg-feed" in block0
    ## No row ever carries a real policy name: the rows are built from
    ## aliases only.
    check "mgAlias(" in block0
    check "rosterName" notin block0.split("function mgRow(e)")[1].split(
      "function mgQueue")[0]

  test "55e. every image URL the page constructs is SHIPPED":
    ## Zero 404s, statically: v1 asked for `soldier_red_front_gun.png`,
    ## `soldier_blue_front_gun.png` and `soldier_green_front.png` and shipped
    ## none of them (VERIFY check 8). The `_front_gun` REQUEST SITE is deleted
    ## and all four `_front` masters ship.
    let shipped = readRepo("Dockerfile.replay-viewer")
    check "_front_gun.png" notin page
    check "_front_gun.png" notin core
    check "_crown.png" notin page
    check "_crown.png" notin core
    check "COG_ART_GUN[team].src" notin page
    for colour in ["red", "blue", "green", "yellow"]:
      ## requested by the FPV billboard loader...
      check ("soldier_' + team + '_front.png") in page
      ## ...and shipped by the bundle.
      check ("soldier_" & colour & "_front.png") in shipped
      check fileExists(repoRoot() / "data" / ("soldier_" & colour & "_front.png"))
      check fileExists(repoRoot() / "data" / ("soldier_" & colour & ".png"))
      for frame in ["1", "2", "3", "5", "6"]:
        check fileExists(repoRoot() / "client" / "art" / "lockerroom" /
          (colour & "_" & frame & ".webp"))
    ## the locker-room loader asks for all four colours again.
    check "['green', 'blue', 'yellow', 'red'].forEach(function (bot) {" in page

  test "57. the board is a 2 x 2 quad on a 27 x 27 surface":
    ## 13 + 1 separator + 13 in each axis, aspect 1.000 — which is what keeps
    ## relayout()'s letterboxing unchanged and the side gutters alive.
    check SurfaceCells == 27
    check BoardPx == SurfaceCells * CellPx
    check LaneOriginX == [0, 14, 0, 14]
    check LaneOriginY == [0, 0, 14, 14]
    ## the four lane colours, in seat order
    check LaneColours == ["red", "blue", "green", "yellow"]
    for slot in 0 ..< LaneCount:
      check laneColour(slot) == LaneColours[slot]
    check seatAlias(0) == "Alpha"
    check seatAlias(1) == "Beta"
    check seatAlias(2) == "Gamma"
    check seatAlias(3) == "Delta"
    ## The panels do not overlap, and the separator cross sits between them.
    for a in 0 ..< LaneCount:
      for b in 0 ..< LaneCount:
        if a == b: continue
        let apart =
          LaneOriginX[a] + GridSize <= LaneOriginX[b] or
          LaneOriginX[b] + GridSize <= LaneOriginX[a] or
          LaneOriginY[a] + GridSize <= LaneOriginY[b] or
          LaneOriginY[b] + GridSize <= LaneOriginY[a]
        check apart
    ## The compositor really places each lane in its own quadrant, in its own
    ## colour, with the alias plate on the frame's top edge.
    let source = readRepo("src/minigrid/global.nim")
    check "SidLaneWall + clamp(slot, 0, LaneCount - 1)" in source
    check "SidCog + slot * 4 + ord(lane.agent.dir)" in source
    check "OidPlate + slot" in source
    check "SidLanePlate + slot" in source
    check "SidSeparator" in source

  test "41. the label manifest is regenerated with any label change":
    let committed = readRepo("tests/label_manifest.txt")
    check committed == labelManifest()
    for alias in ["Alpha", "Beta", "Gamma", "Delta"]:
      check alias in boardLabels()
    check "LAVAGAP" in boardLabels()

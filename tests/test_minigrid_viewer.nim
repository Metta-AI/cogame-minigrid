## Viewer — design note §Tests items 35..39 and 41.

import std/[algorithm, os, sequtils, strutils, unittest]
import minigrid/[sim, labels, broadcast]
import helpers

const
  ## The starter's chrome, byte-for-byte. Not edited, not reformatted.
  ChromeCommonSha256 =
    "7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c"
  ## The exact ids the design note lists as REMOVED, and the exact ids it
  ## lists as KEPT.
  RemovedIds = ["viewpanel", "minimap", "zoombar", "zoom-in", "zoom-out",
                "zoom-slider", "zoom-read", "povBadge", "fpv-hp", "fpv-gear",
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
             "status"]
  ## The beat kinds this sim emits, and no others.
  BeatKinds = ["taskstart", "solved", "failed", "unlock", "produce",
               "fallback", "end"]

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

  test "38. beat CSS matches EXACTLY the emitted kinds":
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

  test "39. transport, endcard and 360 px rules":
    ## relayout() owns --band / --topband / --hudscale on :root.
    check "setProperty('--hudscale'" in page
    check "setProperty('--band'" in page
    check "setProperty('--topband'" in page
    ## The endcard stops at the band and every seek dismisses it.
    check "bottom: var(--band, 0px)" in page
    check "$('endcard').classList.remove('on')" in page
    ## Nothing this game adds is positioned inside the transport band: every
    ## added overlay is anchored from --topband, downward from the TOP.
    let split = page.find("MINIGRID additions to the inherited coworld-ctf chrome")
    let block0 = page[split .. ^1]
    check "top: calc(var(--topband, 0px)" in block0
    check "bottom: var(--band" notin block0
    check "position: fixed" notin block0
    ## The five .tiny rules this game adds.
    check ".plate-name {" in block0
    check "flex: 1 1 auto;" in block0
    check "min-width: 3.2em;" in block0
    for rule in ["#stage.tiny .plate .mg-alias", "#stage.tiny #mg-ribbon",
                 "#stage.tiny #mg-pips", "#stage.tiny #fpv",
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

  test "41. the label manifest is regenerated with any label change":
    let committed = readRepo("tests/label_manifest.txt")
    check committed == labelManifest()
    check "Alpha" in boardLabels()
    check "LAVAGAP" in boardLabels()

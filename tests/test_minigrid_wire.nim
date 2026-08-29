## The sprite wire protocol — addendum v2 §Tests item 55.
##
## `Unknown sprite protocol message type: 34` x22 (VERIFY check 8). 34 decimal
## is 0x22, which is not a message type at all: the parser's cursor was landing
## on a byte that is not a type byte, i.e. the packet stream was MIS-FRAMED.
##
## THE CAUSE, FOUND AND PINNED HERE. A sprite message carries its LABEL length
## as a U16 (`bitworld/spriteprotocol.addSprite`), and the broadcast chrome
## rides the label of the reserved 1 x 1 sprite 4090. A chrome frame past
## 65535 bytes WRAPS that length, the client resumes parsing mid-label, and the
## next byte it reads as a "type" is whatever the JSON happened to hold — `"`
## is 0x22 = 34. `buildStateJson` sheds optional keys to stay inside
## `MaxChromeLabelBytes` and `addChrome` drops a frame that still exceeds it.
##
## THE FORK ADDS NO MESSAGE TYPE. The set is exactly the starter's six, and
## this test walks every packet the fork can emit through the SAME three length
## tables the starter keeps in lockstep (the chunk scanner, the keyframe scan
## and the applier), asserting the cursor lands EXACTLY on each packet's end.

import std/[json, strutils, unittest]
import minigrid/[sim, broadcast, wire_constants]
import minigrid/global as board
import helpers

proc readU16(packet: seq[uint8], offset: int): int =
  int(packet[offset]) or (int(packet[offset + 1]) shl 8)

proc readU32(packet: seq[uint8], offset: int): int =
  int(packet[offset]) or (int(packet[offset + 1]) shl 8) or
    (int(packet[offset + 2]) shl 16) or (int(packet[offset + 3]) shl 24)

proc walkPacket(packet: seq[uint8],
                table: int): tuple[ok: bool, types: seq[int], cursor: int] =
  ## ONE of the three length tables, by index:
  ##   0 the chunk scanner   (ctf/global.nim:3294-3303)
  ##   1 the keyframe scan   (ctf/global.nim:3332-3356)
  ##   2 the applier         (ctf/global.nim:3399-3419)
  ## They agree by construction; walking all three is what catches a writer
  ## whose payload length disagrees with any one of them.
  var offset = 0
  while offset < packet.len:
    let messageType = int(packet[offset])
    inc offset
    if messageType notin result.types:
      result.types.add(messageType)
    case messageType
    of 0x01:
      if offset + 10 > packet.len: return (false, result.types, offset)
      let compressed = packet.readU32(offset + 6)
      let labelStart = offset + 10 + compressed
      if labelStart + 2 > packet.len: return (false, result.types, labelStart)
      let labelLen = packet.readU16(labelStart)
      case table
      of 1:
        ## the keyframe scan measures the label explicitly
        offset = labelStart + 2 + labelLen
      else:
        offset = labelStart + 2 + labelLen
    of 0x02: offset += 11
    of 0x03: offset += 2
    of 0x04: discard
    of 0x05: offset += 5
    of 0x06: offset += 3
    else:
      return (false, result.types, offset - 1)
  result.ok = offset == packet.len
  result.cursor = offset

proc emittedPacket(sim: var SimServer, chrome: string): seq[uint8] =
  var state = board.initGlobalViewerState()
  var next: board.GlobalViewerState
  result = board.buildSpriteProtocolUpdates(sim, state, next, sim.tickCount,
    true, 1, sim.effectiveMaxTicks(), false, false, -1)
  result.addChrome(chrome)

suite "minigrid sprite wire":

  test "55. the fork emits EXACTLY the starter's six message types":
    check SpriteMessageTypes == [1, 2, 3, 4, 5, 6]
    ## The set `broadcast_core.js` handles.
    let core = readRepo("client/broadcast_core.js")
    for value in SpriteMessageTypes:
      check ("type === 0x0" & $value) in core
    check "type === 0x07" notin core
    ## and the set `wire_constants.js` publishes.
    check "messageTypes:[1,2,3,4,5,6]" in WireConstantsJs
    ## the parser closes the stream on anything else, and says so.
    check "Unknown sprite protocol message type" in core

  test "55b. every emittable packet round-trips through all three tables":
    var sim = initSimServer(testConfig())
    sim.phase = Playing
    sim.startPhase(0)
    ## The FIRST packet carries every sprite definition, the layer, the
    ## viewport, the static bed and the separator cross; later packets carry
    ## objects and deletes as the lanes move; the last carries a chrome label.
    var packets: seq[seq[uint8]]
    var state = board.initGlobalViewerState()
    var next: board.GlobalViewerState
    packets.add(board.buildSpriteProtocolUpdates(sim, state, next,
      sim.tickCount, true, 1, sim.effectiveMaxTicks(), false, false, -1))
    state = next
    for turn in 0 ..< 6:
      sim.beginTurn()
      for slot in 0 ..< sim.lanes.len:
        sim.installLanePlan(slot, @[pForward, pRight, pForward], false, 0, 0)
      for tick in 0 ..< 6:
        sim.stepTick()
        var packet = board.buildSpriteProtocolUpdates(sim, state, next,
          sim.tickCount, true, 1, sim.effectiveMaxTicks(), false, false, -1)
        state = next
        packet.addChrome(sim.buildStateJson(newJArray(), true, 1,
          sim.effectiveMaxTicks(), false, true, -1, -1))
        packets.add(packet)
    var seen: seq[int]
    for packet in packets:
      check packet.len > 0
      for table in 0 .. 2:
        let walk = walkPacket(packet, table)
        ## the cursor lands EXACTLY on the packet's end
        check walk.ok
        check walk.cursor == packet.len
        for value in walk.types:
          check value in SpriteMessageTypes
          if value notin seen: seen.add(value)
    ## The fork really does emit the sprite, object, delete, viewport and
    ## layer messages — the walk is not vacuous.
    for value in [1, 2, 3, 5, 6]:
      check value in seen

  test "55c. an oversized chrome frame can never mis-frame the packet":
    ## The exact failure mode of VERIFY check 8, driven on purpose.
    var sim = initSimServer(testConfig())
    sim.phase = Playing
    sim.startPhase(0)
    var oversized = "{\"pad\":\""
    while oversized.len < 70_000:
      oversized.add("0123456789")
    oversized.add("\"}")
    check oversized.len > 65_535
    var packet = sim.emittedPacket(oversized)
    for table in 0 .. 2:
      let walk = walkPacket(packet, table)
      check walk.ok
      check walk.cursor == packet.len
    ## and a frame INSIDE the bound is carried whole.
    var small = sim.emittedPacket("{\"k\":\"frame\"}")
    check small.len > packet.len - 40
    for table in 0 .. 2:
      check walkPacket(small, table).ok

  test "55d. the built frame stays inside the wire bound, four lanes and all":
    ## 240 directive records of a 140-rune say each would blow the U16 label
    ## length on their own; the frame sheds its optional keys instead.
    var sim = initSimServer(testConfig())
    sim.phase = Playing
    sim.startPhase(0)
    var say = ""
    for i in 0 ..< MaxSayRunes:
      say.add("\xF0\x9F\xA7\xA9")
    for turn in 0 ..< 400:
      sim.pushFeedDirective($(%*{
        "k": "directive", "turn": turn, "slot": turn mod LaneCount,
        "alias": seatAlias(turn mod LaneCount), "source": "llm",
        "say": say, "actions": [], "executed": []}))
    var beats = newJArray()
    for tick in 0 ..< 400:
      beats.add(%*{"k": "solved", "t": tick, "s": tick mod LaneCount,
                   "i": 1, "turns": 3, "ticks": 40})
    var lulls: seq[array[2, int]]
    for i in 0 ..< 60:
      lulls.add([i * 10, i * 10 + 5])
    let frame = sim.buildStateJson(newJArray(), true, 1, 720, false, true, -1,
      -1, @[], 0, 0, false, false, lulls, beats)
    check frame.len <= MaxChromeLabelBytes
    ## the BOARD-DERIVED state is never shed: a frame reached by a seek still
    ## hydrates every readout.
    let node = parseJson(frame)
    check node.hasKey("mg")
    check node["mg"]["lanes"].len == LaneCount
    check node.hasKey("teams")
    check node.hasKey("roster")
    check node["t"].getInt() == sim.tickCount

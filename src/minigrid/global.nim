## The board compositor: the sprite pools, the install-time bakes and the
## sprite-protocol packet the viewer's `broadcast_core.js` composites.
##
## Forked from `coworld-ctf/src/ctf/global.nim` with its three named edits:
##
## 1. THE BOARD IS A 2 x 2 QUAD OF 13 x 13 CELL GRIDS ON A 27 x 27 CELL
##    SURFACE (13 + 1 separator + 13 in each axis), NOT A PIXEL ARENA. The
##    surface keeps ASPECT 1.000, identical to v1, so `relayout()`'s
##    letterboxing is unchanged and the two side gutters — where the mission
##    ribbon, the pip stack, the POV inset and the feed live — survive at
##    every width. Placements are
##    emitted in cell space multiplied by `CellPx`; the starter's raycast fov
##    cache and shadowcasting are DELETED and replaced by the exact visibility
##    flood's boolean mask, which the viewer draws as the fog wash.
## 2. OBJECT, DOOR AND OBSTACLE POOLS. Cells, objects, doors and obstacles are
##    filled in ascending (y, x) and emitted incrementally like the starter's
##    other object families: an unchanged placement is never re-sent (the
##    protocol is retained-mode).
## 3. BAKED ROOM BED. `arena_floor.png` is tiled and darkened at install with
##    pixie, exactly the way the starter bakes endzone paint, and the floor
##    grain, the cell gridlines and the wall bevels are baked onto it once —
##    one static bake per board size, so the per-frame cost is the agent,
##    <= 12 objects, <= 8 doors, <= 6 obstacles, the fog mask and the overlays.
##
## Every asset is `staticRead` at compile time rather than read off disk, so
## the wasm module carries its own art and a missing preload can never leave
## the hosted viewer with a blank board.

import std/[strutils, tables]
import pixie, chroma, vmath
import bitworld/spriteprotocol
import sim

const
  BroadcastChromeSpriteId* = 4090
    ## Reserved sprite id whose LABEL carries the broadcast chrome JSON on the
    ## binary channel. Kept off the drawable sprite map by the client and fed
    ## straight to `onText`.
  CellPx* = 48
  SurfaceCells* = GridSize * 2 + 1
    ## 13 + 1 separator + 13. The one-cell separator cross runs down column 13
    ## and across row 13.
  BoardPx* = SurfaceCells * CellPx
  SurfacePx* = BoardPx
  MapLayerId* = 0

  LaneOriginX*: array[LaneCount, int] = [0, GridSize + 1, 0, GridSize + 1]
  LaneOriginY*: array[LaneCount, int] = [0, 0, GridSize + 1, GridSize + 1]
    ## seat 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right — the seat
    ## table of the addendum, in cell space.

  FloorArt = staticRead("../../data/arena_floor.png")
  WallArtH = staticRead("../../client/art/walls/wall_h.jpg")
  WallArtV = staticRead("../../client/art/walls/wall_v.jpg")
  ## THE BOARD CHARACTER IS A NANO-BANANA RENDER OF THE SOFTMAX COG, one
  ## sprite per facing, not a procedural rig: `scripts/art/source/cog_topdown.png`
  ## is a `gemini-2.5-flash-image` render anchored on the shipped
  ## `data/soldier_red.png` master, keyed and split by
  ## `scripts/art/split_cog_sheet.py`. The four facings are rotations of the
  ## one render, so the style is identical across all four and the visor and
  ## the indicator lamp make the heading readable at board scale WITHOUT a
  ## label — which is the whole point of the kit.
  BoardFont = staticRead("../../data/font.ttf")
    ## The alias burned into each panel's frame. `staticRead`, like every
    ## other asset, so the wasm module carries its own art.
  CogArt: array[Dir, string] = [
    staticRead("../../data/art/cog_east.png"),
    staticRead("../../data/art/cog_south.png"),
    staticRead("../../data/art/cog_west.png"),
    staticRead("../../data/art/cog_north.png")]

  ## Sprite ids. Doors are 6 colours x 3 states = 18 chips; keys, balls and
  ## boxes are 6 colours each = 18 chips; the cog is 4 facings.
  SidFloor = 1
  SidWall = 2
  SidLavaA = 3
  SidLavaB = 4
  SidGoal = 5
  SidFogUnseen = 6
  SidFogDim = 7
  SidObstacle = 8
  SidSeparator = 9
  SidKey = 10
  SidBall = 20
  SidBox = 30
  SidDoor = 40
  SidCog = 70
    ## 4 lane colours x 4 facings = 16 chips, `SidCog + lane * 4 + dir`.
  SidLaneWall = 90
    ## the panel's one-cell frame, baked in the lane's colour.
  SidLanePlate = 100
    ## the alias burned into the frame's top edge, in `data/font.ttf`.
  SidFogRun = 200
    ## THE FOG RUN FAMILY: 13 run lengths x 2 wash levels = 26 chips,
    ## `SidFogRun + level * GridSize + (length - 1)`. One 0x02 object per RUN
    ## of unseen cells in a row instead of one per cell, which is what caps
    ## the per-frame dynamic object count at roughly 150 for all four lanes.

  ## Object id bands. Cells are the static bed; everything else layers over.
  OidCell = 1000
    ## the floor bed, one per SURFACE cell (27 x 27).
  OidContent = 2000
    ## a lane cell's content, `OidContent + lane * GridCells + slot`.
  OidFog = 3000
    ## a fog RUN, `OidFog + lane * GridCells + row * GridSize + runIndex`.
  OidAgent = 4000
  OidPlate = 4100
  OidSeparator = 4200

type
  GlobalViewerState* = object
    initialized*: bool
    spritesSent*: bool
    objectIds*: seq[int]
    mouseX*, mouseY*, mouseLayer*: int
    mouseDown*: bool
    selectedJoinOrder*: int
    clickPending*: bool
    scrubbingReplay*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]
    momentumSent*: bool
    sentCell*: seq[int]        ## per lane cell, the sprite id this viewer holds
    sentFog*: seq[int]         ## per lane row, the runs this viewer holds
    sentPhase*: int            ## the phase whose static bed this viewer holds

  PlayerViewerState* = ref object
    initialized*: bool
    objectIds*: seq[int]

proc initGlobalViewerState*(): GlobalViewerState =
  GlobalViewerState(
    selectedJoinOrder: -1,
    replaySeekTick: -1,
    sentPhase: -1,
    sentCell: newSeq[int](LaneCount * GridCells),
    sentFog: newSeq[int](LaneCount * GridCells)
  )

# ---------------------------------------------------------------------------
#  Install-time bakes
# ---------------------------------------------------------------------------

proc colourOf(colour: Colour): ColorRGBA =
  ## The six MiniGrid colours, in the starter palette's warmth so a chip reads
  ## against the baked flagstone bed rather than glowing off it.
  case colour
  of coRed: rgba(214, 74, 62, 255)
  of coGreen: rgba(86, 186, 106, 255)
  of coBlue: rgba(74, 128, 224, 255)
  of coPurple: rgba(160, 96, 208, 255)
  of coYellow: rgba(232, 190, 68, 255)
  of coGrey: rgba(158, 158, 158, 255)
  of coNone: rgba(210, 200, 184, 255)

proc laneRgba(slot: int): ColorRGBA =
  ## The four lane colours, in the same warmth as the board palette.
  case clamp(slot, 0, LaneCount - 1)
  of 0: rgba(214, 74, 62, 255)
  of 1: rgba(74, 128, 224, 255)
  of 2: rgba(86, 186, 106, 255)
  else: rgba(232, 190, 68, 255)

proc tintedTo(source: Image, colour: ColorRGBA, strength: int): Image =
  ## One chip pushed toward a lane colour, keeping the source's shading — the
  ## cog rig and the panel frame are the SAME art in four colours, never four
  ## different drawings.
  result = newImage(source.width, source.height)
  for i in 0 ..< source.width * source.height:
    let pixel = source.data[i].rgba()
    if pixel.a == 0:
      result.data[i] = pixel.rgbx()
      continue
    result.data[i] = rgba(
      uint8((int(pixel.r) * (100 - strength) + int(colour.r) * strength) div 100),
      uint8((int(pixel.g) * (100 - strength) + int(colour.g) * strength) div 100),
      uint8((int(pixel.b) * (100 - strength) + int(colour.b) * strength) div 100),
      pixel.a).rgbx()

proc tileFrom(source: Image, size: int, darken: uint8): Image =
  ## One cell-sized tile cut from a source texture and darkened, the way the
  ## starter bakes endzone paint.
  result = newImage(size, size)
  let scaled = source.resize(max(size, source.width div 4),
                             max(size, source.height div 4))
  for y in 0 ..< size:
    for x in 0 ..< size:
      let pixel = scaled.unsafe[(x * 7) mod scaled.width,
                                (y * 11) mod scaled.height].rgba()
      result.unsafe[x, y] = rgba(
        uint8(int(pixel.r) * int(darken) div 255),
        uint8(int(pixel.g) * int(darken) div 255),
        uint8(int(pixel.b) * int(darken) div 255), 255).rgbx()

proc gridlines(image: Image) =
  ## The baked cell gridline — one static bake, not a per-frame stroke.
  for i in 0 ..< image.width:
    image.unsafe[i, 0] = rgba(24, 20, 16, 120).rgbx()
    image.unsafe[0, i] = rgba(24, 20, 16, 120).rgbx()

proc bevel(image: Image) =
  ## Wall masonry bevel: a lit top-left edge and a shadowed bottom-right one,
  ## so a wall run reads as masonry rather than a black bar.
  let size = image.width
  for i in 0 ..< size:
    image.unsafe[i, 0] = rgba(196, 180, 156, 255).rgbx()
    image.unsafe[0, i] = rgba(178, 162, 140, 255).rgbx()
    image.unsafe[i, size - 1] = rgba(38, 32, 26, 255).rgbx()
    image.unsafe[size - 1, i] = rgba(38, 32, 26, 255).rgbx()

proc solid(size: int, colour: ColorRGBA): Image =
  result = newImage(size, size)
  result.fill(colour)

proc discChip(size: int, colour: ColorRGBA, ring: bool): Image =
  ## A ball: a filled disc with a specular highlight, and optionally a menace
  ## ring (the grey obstacle balls that kill).
  result = newImage(size, size)
  let
    centre = size div 2
    radius = size * 7 div 20
  for y in 0 ..< size:
    for x in 0 ..< size:
      let d2 = (x - centre) * (x - centre) + (y - centre) * (y - centre)
      if d2 <= radius * radius:
        var shade = 255 - (x + y) * 40 div (2 * size)
        result.unsafe[x, y] = rgba(
          uint8(int(colour.r) * shade div 255),
          uint8(int(colour.g) * shade div 255),
          uint8(int(colour.b) * shade div 255), 255).rgbx()
      elif ring and d2 <= (radius + 3) * (radius + 3):
        result.unsafe[x, y] = rgba(240, 226, 200, 210).rgbx()
  ## specular
  for y in centre - radius div 2 .. centre - radius div 4:
    for x in centre - radius div 2 .. centre - radius div 4:
      if x >= 0 and y >= 0 and x < size and y < size:
        result.unsafe[x, y] = rgba(255, 250, 240, 190).rgbx()

proc keyChip(size: int, colour: ColorRGBA): Image =
  ## A key: a ringed bow with a shaft and two wards.
  result = newImage(size, size)
  let
    cx = size div 3
    cy = size div 2
    radius = size div 6
  for y in 0 ..< size:
    for x in 0 ..< size:
      let d2 = (x - cx) * (x - cx) + (y - cy) * (y - cy)
      if d2 <= radius * radius and d2 >= (radius - 3) * (radius - 3):
        result.unsafe[x, y] = colour.rgbx()
  for x in cx + radius .. size - size div 6:
    for y in cy - 2 .. cy + 1:
      result.unsafe[x, y] = colour.rgbx()
  for y in cy + 1 .. cy + size div 8:
    result.unsafe[size - size div 6 - 1, y] = colour.rgbx()
    result.unsafe[size - size div 6 - 6, y] = colour.rgbx()

proc boxChip(size: int, colour: ColorRGBA, crate: Image): Image =
  ## A box: a crate tinted from the wall texture, with a lid seam.
  result = newImage(size, size)
  let inset = size div 6
  for y in inset ..< size - inset:
    for x in inset ..< size - inset:
      let grain = crate.unsafe[x mod crate.width, y mod crate.height].rgba()
      result.unsafe[x, y] = rgba(
        uint8((int(colour.r) * 3 + int(grain.r)) div 4),
        uint8((int(colour.g) * 3 + int(grain.g)) div 4),
        uint8((int(colour.b) * 3 + int(grain.b)) div 4), 255).rgbx()
  for x in inset ..< size - inset:
    result.unsafe[x, size div 2] = rgba(28, 24, 20, 220).rgbx()
    result.unsafe[x, inset] = rgba(250, 244, 230, 160).rgbx()

proc doorChip(size: int, colour: ColorRGBA, state: DoorState,
              panel: Image): Image =
  ## A coloured door panel: a keyhole when locked, swung into the jamb when
  ## open, a plain panel when closed.
  result = newImage(size, size)
  let jamb = size div 8
  for y in 0 ..< size:
    for x in 0 ..< size:
      if x < jamb or x >= size - jamb:
        let grain = panel.unsafe[x mod panel.width, y mod panel.height].rgba()
        result.unsafe[x, y] = rgba(grain.r div 2, grain.g div 2,
                                   grain.b div 2, 255).rgbx()
  let
    leafX0 = if state == dsOpen: jamb else: jamb
    leafX1 = if state == dsOpen: jamb + size div 5 else: size - jamb
  for y in 2 ..< size - 2:
    for x in leafX0 ..< leafX1:
      var shade = 255 - (x - leafX0) * 60 div max(1, leafX1 - leafX0)
      result.unsafe[x, y] = rgba(
        uint8(int(colour.r) * shade div 255),
        uint8(int(colour.g) * shade div 255),
        uint8(int(colour.b) * shade div 255), 255).rgbx()
  if state == dsLocked:
    let
      kx = (leafX0 + leafX1) div 2
      ky = size div 2
    for y in ky - 4 .. ky + 5:
      for x in kx - 3 .. kx + 3:
        if x >= 0 and y >= 0 and x < size and y < size:
          result.unsafe[x, y] = rgba(24, 20, 16, 255).rgbx()

proc lavaChip(size: int, frame: int): Image =
  ## A two-frame procedural bake in the palette's reds and oranges with a
  ## crust pattern, cycled at 4 Hz.
  result = newImage(size, size)
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        wave = ((x * 5 + y * 3 + frame * 7) mod 32)
        heat = 150 + wave * 3
      var crust = ((x div 6 + y div 5 + frame) mod 5) == 0
      if crust:
        result.unsafe[x, y] = rgba(70, 26, 18, 255).rgbx()
      else:
        result.unsafe[x, y] = rgba(uint8(min(255, heat + 60)),
                                   uint8(min(200, heat div 3)),
                                   30, 255).rgbx()

proc goalChip(size: int, floorTile: Image): Image =
  ## The goal square: a green tile with the starter's endzone hatch.
  result = newImage(size, size)
  for y in 0 ..< size:
    for x in 0 ..< size:
      let grain = floorTile.unsafe[x, y].rgba()
      var hatch = ((x + y) mod 8) < 3
      let base = if hatch: 200 else: 150
      result.unsafe[x, y] = rgba(
        uint8((int(grain.r) + 40) div 3),
        uint8(min(255, (int(grain.g) + base * 2) div 2)),
        uint8((int(grain.b) + 60) div 3), 255).rgbx()

proc cogChip(size: int, dir: Dir, source: Image): Image =
  ## The cog at one of its four facings — the nano-banana render for that
  ## facing — with a small procedural direction wedge baked on the leading
  ## edge, so the heading reads even at the 9.2 px cells of a 360 px embed.
  result = newImage(size, size)
  let body = source.resize(size * 7 div 8, size * 7 div 8)
  result.draw(body, translate(vec2(float32(size div 16), float32(size div 16))))
  ## The wedge: a triangle on the facing edge.
  let
    half = size div 2
    depth = size div 10
  for step in 0 ..< depth:
    let span = half - step * half div max(1, depth)
    for offset in -span .. span:
      var x, y: int
      case dir
      of dirEast:
        x = size - 1 - step
        y = half + offset
      of dirWest:
        x = step
        y = half + offset
      of dirSouth:
        x = half + offset
        y = size - 1 - step
      of dirNorth:
        x = half + offset
        y = step
      if x >= 0 and y >= 0 and x < size and y < size:
        result.unsafe[x, y] = rgba(240, 208, 96, 235).rgbx()

proc fogRunChip(length: int, colour: ColorRGBA): Image =
  ## One horizontal RUN of fog: `length` cells wide, one cell tall. Drawing a
  ## run as ONE sprite is what keeps the per-frame object count down.
  result = newImage(length * CellPx, CellPx)
  result.fill(colour)

proc aliasPlate(width: int, slot: int, font: Font): Image =
  ## The lane's alias burned into the frame's TOP EDGE, in `data/font.ttf`.
  result = newImage(width, CellPx)
  result.fill(rgba(16, 14, 12, 235))
  let colour = laneRgba(slot)
  for x in 0 ..< width:
    result.unsafe[x, 0] = colour.rgbx()
    result.unsafe[x, CellPx - 1] = colour.rgbx()
  font.size = 30
  font.paint.color = color(float32(colour.r) / 255, float32(colour.g) / 255,
                           float32(colour.b) / 255, 1)
  result.fillText(font, seatAlias(slot).toUpperAscii(),
    translate(vec2(float32(width div 2 - 60), 6.0)),
    bounds = vec2(120, float32(CellPx)), hAlign = CenterAlign)

proc rgbaBytes(image: Image): seq[uint8] =
  ## Straight (un-premultiplied) RGBA, which is what the sprite protocol's
  ## client-side compositor expects.
  result = newSeq[uint8](image.width * image.height * 4)
  for i in 0 ..< image.width * image.height:
    let pixel = image.data[i].rgba()
    result[i * 4] = pixel.r
    result[i * 4 + 1] = pixel.g
    result[i * 4 + 2] = pixel.b
    result[i * 4 + 3] = pixel.a

var
  bakedSprites: seq[tuple[id, width, height: int, pixels: seq[uint8]]]
  bakedReady = false
  chipImages: Table[int, Image]
  chipReady = false

proc bakeSprites() =
  ## ONE static bake per process. Everything the board draws is here.
  if bakedReady:
    return
  bakedReady = true
  let
    floorSource = decodeImage(FloorArt)
    wallSource = decodeImage(WallArtH)
    crateSource = decodeImage(WallArtV)
    cogSources = [decodeImage(CogArt[dirEast]), decodeImage(CogArt[dirSouth]),
                  decodeImage(CogArt[dirWest]), decodeImage(CogArt[dirNorth])]
  var floorTile = tileFrom(floorSource, CellPx, 178)
  floorTile.gridlines()
  var wallTile = tileFrom(wallSource, CellPx, 120)
  wallTile.bevel()
  let crateTile = tileFrom(crateSource, CellPx, 210)

  bakedSprites.add((SidFloor, CellPx, CellPx, floorTile.rgbaBytes()))
  bakedSprites.add((SidWall, CellPx, CellPx, wallTile.rgbaBytes()))
  bakedSprites.add((SidLavaA, CellPx, CellPx, lavaChip(CellPx, 0).rgbaBytes()))
  bakedSprites.add((SidLavaB, CellPx, CellPx, lavaChip(CellPx, 3).rgbaBytes()))
  bakedSprites.add((SidGoal, CellPx, CellPx,
    goalChip(CellPx, floorTile).rgbaBytes()))
  bakedSprites.add((SidFogUnseen, CellPx, CellPx,
    solid(CellPx, rgba(6, 6, 10, 205)).rgbaBytes()))
  bakedSprites.add((SidFogDim, CellPx, CellPx,
    solid(CellPx, rgba(10, 12, 20, 120)).rgbaBytes()))
  bakedSprites.add((SidObstacle, CellPx, CellPx,
    discChip(CellPx, colourOf(coGrey), true).rgbaBytes()))
  ## The one-cell separator cross between the four panels.
  bakedSprites.add((SidSeparator, CellPx, CellPx, solid(CellPx, rgba(9, 8, 7, 255)).rgbaBytes()))
  ## THE FOUR LANE FRAMES: the SAME masonry tile pushed toward each lane
  ## colour, so a panel reads as that lane's at a glance.
  for slot in 0 ..< LaneCount:
    bakedSprites.add((SidLaneWall + slot, CellPx, CellPx,
      wallTile.tintedTo(laneRgba(slot), 55).rgbaBytes()))
  ## THE FOG RUN FAMILY: 13 lengths x 2 wash levels.
  for level in 0 .. 1:
    let wash = if level == 0: rgba(6, 6, 10, 205) else: rgba(10, 12, 20, 120)
    for length in 1 .. GridSize:
      bakedSprites.add((SidFogRun + level * GridSize + length - 1,
        length * CellPx, CellPx, fogRunChip(length, wash).rgbaBytes()))
  for i, colour in Colours:
    bakedSprites.add((SidKey + i, CellPx, CellPx,
      keyChip(CellPx, colourOf(colour)).rgbaBytes()))
    bakedSprites.add((SidBall + i, CellPx, CellPx,
      discChip(CellPx, colourOf(colour), false).rgbaBytes()))
    bakedSprites.add((SidBox + i, CellPx, CellPx,
      boxChip(CellPx, colourOf(colour), crateTile).rgbaBytes()))
    for s, state in [dsClosed, dsLocked, dsOpen]:
      bakedSprites.add((SidDoor + i * 3 + s, CellPx, CellPx,
        doorChip(CellPx, colourOf(colour), state, wallTile).rgbaBytes()))
  ## THE COG IN FOUR LANE COLOURS: 4 facings x 4 colours = 16 chips, all from
  ## the ONE nano-banana render, so the style is identical across the quad.
  for slot in 0 ..< LaneCount:
    for d, dir in Dirs:
      bakedSprites.add((SidCog + slot * 4 + d, CellPx, CellPx,
        cogChip(CellPx, dir, cogSources[d]).tintedTo(laneRgba(slot), 38)
          .rgbaBytes()))
  ## The alias plates, one per lane, sized to the panel's top edge.
  let font = newFont(parseTtf(BoardFont))
  for slot in 0 ..< LaneCount:
    bakedSprites.add((SidLanePlate + slot, GridSize * CellPx, CellPx,
      aliasPlate(GridSize * CellPx, slot, font).rgbaBytes()))

proc bakeChipImages() =
  ## The same chips as `Image`s, for the offline board preview.
  if chipReady:
    return
  chipReady = true
  bakeSprites()
  for sprite in bakedSprites:
    ## Only the CELL-SIZED chips: the fog runs and the alias plates are wider
    ## than a cell and the offline preview draws neither.
    if sprite.pixels.len != CellPx * CellPx * 4:
      continue
    var image = newImage(CellPx, CellPx)
    for i in 0 ..< CellPx * CellPx:
      image.data[i] = rgba(sprite.pixels[i * 4], sprite.pixels[i * 4 + 1],
                           sprite.pixels[i * 4 + 2],
                           sprite.pixels[i * 4 + 3]).rgbx()
    chipImages[sprite.id] = image

proc spriteFor(cell: Cell, tick: int): int =
  ## The sprite a cell's CONTENT draws as, or 0 for bare floor.
  if cell.obstacle:
    return SidObstacle
  case cell.kind
  of ckEmpty: 0
  of ckWall: SidWall
  of ckLava: (if (tick div 6) mod 2 == 0: SidLavaA else: SidLavaB)
  of ckGoal: SidGoal
  of ckKey: SidKey + ord(cell.colour) - 1
  of ckBall: SidBall + ord(cell.colour) - 1
  of ckBox: SidBox + ord(cell.colour) - 1
  of ckDoor:
    let state = case cell.door
      of dsClosed: 0
      of dsLocked: 1
      else: 2
    SidDoor + (ord(cell.colour) - 1) * 3 + state

# ---------------------------------------------------------------------------
#  Viewer input
# ---------------------------------------------------------------------------

proc applyGlobalViewerMessage*(state: var GlobalViewerState, message: string) =
  ## Applies one or more global protocol client messages. Whole-string
  ## commands are intercepted BEFORE the legacy char-by-char transport path,
  ## so a multi-digit tick is never mangled into speed keystrokes.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientMouseMoveMessage:
      state.mouseX = item.x
      state.mouseY = item.y
      state.mouseLayer = (if item.hasLayer: item.layer else: MapLayerId)
    of SpriteClientMouseButtonMessage:
      if item.button == 0x01'u8:
        state.mouseDown = item.down
        if state.mouseDown:
          state.clickPending = true
        else:
          state.scrubbingReplay = false
    of SpriteClientChatMessage:
      if item.text.startsWith("s:"):
        let tick = try: parseInt(item.text[2 .. ^1]) except ValueError: -1
        if tick >= 0:
          state.replaySeekTick = tick
      elif item.text.startsWith("v:"):
        ## POV selection: four lanes, so there IS something to select. -1
        ## clears it and hands the choice back to the score leader.
        let slot = try: parseInt(item.text[2 .. ^1]) except ValueError: -1
        state.selectedJoinOrder = clamp(slot, -1, LaneCount - 1)
      else:
        for ch in item.text:
          state.replayCommands.add(ch)
    of SpriteClientInputMessage:
      discard
    of SpriteClientReadyMessage, SpriteClientDebugSpriteMessage:
      discard

proc applyPlayerViewerMessage*(state: var PlayerViewerState, message: string,
                               inputMask: var uint8, pressedMask: var uint8,
                               chatText: var string) =
  ## The seat's own socket. Its Sprite v1 chat message is where the
  ## REGISTRATION blob arrives; `server.nim` intercepts it.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      chatText.add(item.text)
    of SpriteClientInputMessage:
      pressedMask = pressedMask or (item.mask and not inputMask)
      inputMask = item.mask
    else:
      discard

# ---------------------------------------------------------------------------
#  The packet
# ---------------------------------------------------------------------------

proc laneCellSprite(lane: Lane, slot, x, y, tick: int): int =
  ## The sprite ONE lane cell draws as. The panel's border ring is the lane's
  ## own coloured frame; everything inside is the shared cell vocabulary.
  let cell = lane.task.grid.cells[idx(x, y)]
  if cell.kind == ckWall and
      (x == 0 or y == 0 or x == GridSize - 1 or y == GridSize - 1):
    return SidLaneWall + clamp(slot, 0, LaneCount - 1)
  spriteFor(cell, tick)

proc liveMask(lane: Lane): array[GridCells, bool] =
  ## The cells inside the lane agent's CURRENT 7 x 7 visible set.
  let visible = lane.task.grid.visibleMask(lane.agent.x, lane.agent.y,
    lane.agent.dir)
  for j in 0 ..< ViewSize:
    for i in 0 ..< ViewSize:
      if not visible[j * ViewSize + i]:
        continue
      let w = viewToWorld(lane.agent.x, lane.agent.y, lane.agent.dir, i, j)
      if inBounds(w.x, w.y):
        result[idx(w.x, w.y)] = true

proc renderBoardImage*(sim: SimServer): Image =
  ## The 2 x 2 quad as one image, from the SAME baked chips the sprite packet
  ## places. `tools/dump_board_preview.nim` writes it to a PNG so the
  ## install-time art is reviewable without a browser.
  bakeSprites()
  bakeChipImages()
  result = newImage(BoardPx, BoardPx)
  result.fill(rgba(12, 11, 10, 255))
  for slot in 0 ..< sim.lanes.len:
    let lane = sim.lanes[slot]
    if not lane.taskStarted:
      continue
    let
      ox = LaneOriginX[slot] * CellPx
      oy = LaneOriginY[slot] * CellPx
    for y in 0 ..< GridSize:
      for x in 0 ..< GridSize:
        let at = translate(vec2(float32(ox + x * CellPx),
                                float32(oy + y * CellPx)))
        result.draw(chipImages[SidFloor], at)
        let sprite = laneCellSprite(lane, slot, x, y, sim.tickCount)
        if sprite != 0 and chipImages.hasKey(sprite):
          result.draw(chipImages[sprite], at)
    result.draw(chipImages[SidCog + slot * 4 + ord(lane.agent.dir)],
      translate(vec2(float32(ox + lane.agent.x * CellPx),
                     float32(oy + lane.agent.y * CellPx))))
    let live = lane.liveMask()
    for cell in 0 ..< GridCells:
      if live[cell]:
        continue
      let wash =
        if lane.knownMap.cells[cell].seen: SidFogDim else: SidFogUnseen
      result.draw(chipImages[wash],
        translate(vec2(float32(ox + (cell mod GridSize) * CellPx),
                       float32(oy + (cell div GridSize) * CellPx))))

proc addChrome*(packet: var seq[uint8], json: string) =
  ## The chrome frame rides the LABEL of a reserved 1 x 1 sprite. The label
  ## length is a U16 ON THE WIRE, so a frame past 65535 bytes would WRAP and
  ## the client's parser would resume mid-label and report a nonsense message
  ## type (`Unknown sprite protocol message type: 34`, VERIFY check 8). The
  ## frame is bounded in `buildStateJson`; this is the last guard, and it
  ## drops the frame rather than corrupting the stream.
  if json.len > MaxChromeLabelBytes:
    echo "minigrid: chrome frame of ", json.len,
      " bytes exceeds the ", MaxChromeLabelBytes,
      "-byte wire bound; dropping it rather than mis-framing the packet"
    return
  packet.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0], json)

proc buildSpriteProtocolUpdates*(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  replayTick = -1,
  replayPlaying = false,
  replaySpeed = 1,
  replayMaxTick = -1,
  replayLooping = false,
  replayEnabled = false,
  replayMismatchTick = -1
): seq[uint8] =
  ## Builds the board updates for one viewer. The protocol is RETAINED-MODE —
  ## a client keeps a placement until it is replaced — so an unchanged cell
  ## costs no bytes, and the fog is emitted as horizontal RUNS so the per-frame
  ## dynamic object count stays around 150 for all four lanes.
  bakeSprites()
  nextState = state
  nextState.replayCommands.setLen(0)
  nextState.replaySeekTick = -1
  nextState.clickPending = false
  if nextState.sentCell.len != LaneCount * GridCells:
    nextState.sentCell = newSeq[int](LaneCount * GridCells)
    nextState.sentFog = newSeq[int](LaneCount * GridCells)

  if not nextState.initialized:
    nextState.initialized = true
    result.addLayer(MapLayerId, SpriteLayerMap, SpriteLayerZoomableFlag)
    result.addViewport(MapLayerId, BoardPx, BoardPx)
  if not nextState.spritesSent:
    nextState.spritesSent = true
    for sprite in bakedSprites:
      result.addSprite(sprite.id, sprite.width, sprite.height, sprite.pixels)
    ## The floor bed under the whole 27 x 27 surface, and the one-cell
    ## separator cross between the four panels. Both are static for the whole
    ## episode: emitted once, never re-sent.
    for y in 0 ..< SurfaceCells:
      for x in 0 ..< SurfaceCells:
        result.addObject(OidCell + y * SurfaceCells + x, x * CellPx,
          y * CellPx, -100, MapLayerId, SidFloor)
    var separator = 0
    for i in 0 ..< SurfaceCells:
      result.addObject(OidSeparator + separator, GridSize * CellPx,
        i * CellPx, -90, MapLayerId, SidSeparator)
      inc separator
      if i != GridSize:
        result.addObject(OidSeparator + separator, i * CellPx,
          GridSize * CellPx, -90, MapLayerId, SidSeparator)
        inc separator

  let phaseChanged = nextState.sentPhase != sim.taskIndex
  nextState.sentPhase = sim.taskIndex

  for slot in 0 ..< sim.lanes.len:
    let lane = sim.lanes[slot]
    if not lane.taskStarted:
      continue
    let
      ox = LaneOriginX[slot] * CellPx
      oy = LaneOriginY[slot] * CellPx
      base = slot * GridCells

    ## 2. The lane's cells, in ascending (y, x). Bare floor is the baked bed,
    ## and an unchanged cell is never re-sent.
    for y in 0 ..< GridSize:
      for x in 0 ..< GridSize:
        let cell = idx(x, y)
        let sprite = laneCellSprite(lane, slot, x, y, sim.tickCount)
        if not phaseChanged and nextState.sentCell[base + cell] == sprite + 1:
          continue
        nextState.sentCell[base + cell] = sprite + 1
        let objectId = OidContent + base + cell
        if sprite != 0:
          result.addObject(objectId, ox + x * CellPx, oy + y * CellPx,
            y * 4, MapLayerId, sprite)
        else:
          result.addDeleteObject(objectId)

    ## The alias burned into the panel's top edge.
    if phaseChanged or not state.spritesSent:
      result.addObject(OidPlate + slot, ox, oy, 950, MapLayerId,
        SidLanePlate + slot)

    ## 3. The fog wash — the single most important readout in this game — as
    ## horizontal RUNS. A cell the agent has never seen is under a heavy dark
    ## wash; a cell seen but not currently visible is under a light one; a
    ## cell in the current 7 x 7 visible set is drawn clean and bright.
    let live = lane.liveMask()
    for y in 0 ..< GridSize:
      var runs: seq[tuple[x, length, level: int]]
      var x = 0
      while x < GridSize:
        let cell = idx(x, y)
        let level =
          if live[cell]: -1
          elif lane.knownMap.cells[cell].seen: 1
          else: 0
        if level < 0:
          inc x
          continue
        var length = 1
        while x + length < GridSize:
          let next = idx(x + length, y)
          let nextLevel =
            if live[next]: -1
            elif lane.knownMap.cells[next].seen: 1
            else: 0
          if nextLevel != level:
            break
          inc length
        runs.add((x, length, level))
        x += length
      for index in 0 ..< GridSize:
        let objectId = OidFog + base + y * GridSize + index
        let held = nextState.sentFog[base + y * GridSize + index]
        if index < runs.len:
          let run = runs[index]
          let sprite = SidFogRun + run.level * GridSize + run.length - 1
          let token = 1 + run.x * 64 + sprite
          if held == token and not phaseChanged:
            continue
          nextState.sentFog[base + y * GridSize + index] = token
          result.addObject(objectId, ox + run.x * CellPx, oy + y * CellPx,
            900, MapLayerId, sprite)
        else:
          if held == 0 and not phaseChanged:
            continue
          nextState.sentFog[base + y * GridSize + index] = 0
          result.addDeleteObject(objectId)

    ## 4. The cog, in ITS LANE'S COLOUR, above the board and under the fog it
    ## is standing in.
    result.addObject(OidAgent + slot, ox + lane.agent.x * CellPx,
      oy + lane.agent.y * CellPx, 500 + lane.agent.y * 4, MapLayerId,
      SidCog + slot * 4 + ord(lane.agent.dir))

  ## The chrome sprite is added by the CALLER (the live server and
  ## `buildReplayViewerPacket`), exactly as the starter does it, so the board
  ## packet and the HUD frame stay separable.

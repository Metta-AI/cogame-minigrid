## Consts, wire types and the closed enums the whole game is written against.
##
## Forked from `coworld-ctf/src/ctf/sim_types.nim`, keeping its discipline:
## `GameVersion` gates replay compatibility and carries a PREPEND-ONLY
## changelog comment (`tools/ci/check_gameversion.sh` diffs the headline, not
## the digits); `TargetFps` is the one tick rate; the flatty wire types'
## FIELD ORDER IS SACRED — a reordered field silently re-interprets every
## recorded keyframe.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES (Unicode codepoints).
## `MaxSayRunes` and `MaxNoteRunes` are RE-PINNED in this fork (the starter's
## 10-rune shout and 160-rune note are a paintball shout and a paintball
## note): a cog narrating a gridworld needs a sentence, and a cog carrying its
## own map between turns needs more than 160 runes. `ShoutMaxChars` is deleted
## with the shout mechanic.

import std/[strutils, unicode]

const
  GameName* = "minigrid"

  GameVersion* = "1"
    ## GV1 (first rules): ONE COG, FIVE PARTIALLY OBSERVED 13x13 TASKS.
    ## The gauntlet, the seven task families, the 7x7 visibility flood, the
    ## seven primitives, the two macros, the three-term score. Nothing is
    ## obsoleted — this is the first version of these rules.

  TargetFps* = 24
    ## The one tick rate. Replay times are derived from it, the lobby
    ## countdown counts in it, and the static viewer plays back against it.
  ReplayFps* = TargetFps
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]

  GridSize* = 13
    ## Every task in every variant is played on a 13 x 13 cell grid whose
    ## whole border ring is wall. One board size forever: it is what lets the
    ## viewer letterbox a square board at any width and what makes
    ## `goto x y` a stable contract in the reply schema.
  GridCells* = GridSize * GridSize
  ViewSize* = 7
    ## The egocentric window, agent-up, agent at view coordinate (3, 6).

  MaxSayRunes* = 140            ## the cog thinking out loud, in RUNES.
  MaxNoteRunes* = 300           ## the private scratchpad, in RUNES.
  MaxPolicyLabelRunes* = 64     ## `register.policy` cap, in RUNES.
  MaxFallbackDetailRunes* = 200 ## `fallback.detail` cap, in RUNES.
  MaxDirectiveRunes* = 4000     ## whole serialized `directive` record cap.
  MaxPromptRunes* = 4000        ## PLAYER_PROMPT transport cap.
  MaxStopDetailRunes* = 200     ## `results.stopDetail` cap, in RUNES.
  MaxReplyBytes* = 4096         ## bytes read from the provider before parsing.

  MaxPlayers* = 1
    ## num_agents is fixed at 1 in every variant and in the cert fixture.
    ## MiniGrid / BabyAI / XLand are single-agent benchmarks and a second seat
    ## would have nothing to do.

type
  CellKind* = enum
    ## The closed enum of cell contents. A cell holds at most one thing.
    ckEmpty = "empty"
    ckWall = "wall"
    ckLava = "lava"
    ckGoal = "goal"
    ckKey = "key"
    ckBall = "ball"
    ckBox = "box"
    ckDoor = "door"

  DoorState* = enum
    dsNone = ""
    dsOpen = "open"
    dsClosed = "closed"
    dsLocked = "locked"

  Colour* = enum
    ## The six MiniGrid colours and nothing else (plus the empty colour that
    ## floor, wall, lava and the goal square carry).
    coNone = ""
    coRed = "red"
    coGreen = "green"
    coBlue = "blue"
    coPurple = "purple"
    coYellow = "yellow"
    coGrey = "grey"

  Dir* = enum
    ## The MiniGrid order, so "turn right" is `(dir + 1) mod 4`.
    dirEast = "east"
    dirSouth = "south"
    dirWest = "west"
    dirNorth = "north"

  Primitive* = enum
    ## The seven primitives. One primitive is one tick.
    pLeft = "left"
    pRight = "right"
    pForward = "forward"
    pPickup = "pickup"
    pDrop = "drop"
    pToggle = "toggle"
    pWait = "wait"

  TaskFamily* = enum
    tfLavagap = "lavagap"
    tfDoorkey = "doorkey"
    tfMultiroom = "multiroom"
    tfKeycorridor = "keycorridor"
    tfDynamic = "dynamic"
    tfBabyai = "babyai"
    tfXland = "xland"

  TaskOutcome* = enum
    ## Closed enum; `toPending` never reaches a results document.
    toPending = "pending"
    toSolved = "solved"
    toTimeout = "timeout"
    toDied = "died"
    toCrashed = "crashed"
    toUnreached = "unreached"

  EndReason* = enum
    ## `results.reason` — exactly these three values are legal.
    erComplete = "complete"
    erDeadline = "deadline"
    erFault = "fault"

  EndRule* = enum
    ## `results.endRule` — which of the end conditions fired.
    edNone = ""
    edGauntletComplete = "gauntletComplete"
    edTurnCap = "turnCap"
    edWallClock = "wallClock"
    edFault = "fault"

  Phase* = enum
    Lobby
    Playing
    GameOver

  Cell* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    kind*: CellKind
    colour*: Colour
    door*: DoorState
    obstacle*: bool
      ## a grey ball that moves and ends the task on a `forward` into it.
    contents*: uint8
      ## a box's contents, encoded `kind * 8 + colour + 1`, or 0 for "empty".
      ## Never shown to the seat: opening the box is the only way to learn it.

  ObjectRef* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    kind*: CellKind
    colour*: Colour

  Obstacle* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    x*, y*: int

  ProductionRule* = object
    ## FLATTY WIRE TYPE — field order is sacred.
    a*, b*, output*: ObjectRef

  Production* = object
    ## One firing the agent caused; the ONLY channel through which the hidden
    ## `xland` rule table can be learned.
    a*, b*, output*: ObjectRef
    x*, y*, tick*: int

  Subgoal* = object
    name*: string
    earned*: bool

const
  CellGlyphs*: array[CellKind, char] = ['.', '#', '~', 'G', 'k', 'o', 'b', 'D']
    ## The door glyph here is the OPEN door; a closed door reads 'd' and a
    ## locked one 'L' (see `glyphOf`).
  Colours* = [coRed, coGreen, coBlue, coPurple, coYellow, coGrey]
  Dirs* = [dirEast, dirSouth, dirWest, dirNorth]
  DirDx*: array[Dir, int] = [1, 0, -1, 0]
  DirDy*: array[Dir, int] = [0, 1, 0, -1]

proc glyphOf*(cell: Cell): char =
  ## The one glyph a cell reads as. Doors are the only kind whose glyph
  ## depends on state, and that is the whole of the keys-and-doors game.
  case cell.kind
  of ckDoor:
    case cell.door
    of dsOpen: 'D'
    of dsClosed: 'd'
    else: 'L'
  else: CellGlyphs[cell.kind]

proc passable*(cell: Cell): bool =
  ## Can the agent step into it? Lava IS passable — entering it is how a task
  ## is lost, not something the physics prevents.
  case cell.kind
  of ckEmpty, ckLava, ckGoal: true
  of ckDoor: cell.door == dsOpen
  else: false

proc seesBehind*(cell: Cell): bool =
  ## The "Sees behind" column of the cell table: false for wall, closed door
  ## and locked door; true for everything else.
  case cell.kind
  of ckWall: false
  of ckDoor: cell.door == dsOpen
  else: true

proc pickupable*(cell: Cell): bool =
  cell.kind in {ckKey, ckBall, ckBox} and not cell.obstacle

proc encodeObject*(obj: ObjectRef): uint8 =
  ## The byte a box carries for its contents. 0 means "nothing inside".
  if obj.kind notin {ckKey, ckBall, ckBox}:
    return 0
  uint8(ord(obj.kind) * 8 + ord(obj.colour) + 1)

proc decodeObject*(code: uint8): ObjectRef =
  if code == 0:
    return ObjectRef(kind: ckEmpty, colour: coNone)
  let value = int(code) - 1
  ObjectRef(kind: CellKind(value div 8), colour: Colour(value mod 8))

proc `$`*(obj: ObjectRef): string =
  if obj.kind == ckEmpty: "" else: $obj.colour & " " & $obj.kind

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened. A byte slice can cut a codepoint
  ## in half; a replay written that way renders in a browser and then fails a
  ## strict UTF-8 parser.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeSay*(text: string): string =
  ## What the cog says out loud: newlines collapsed so one record stays one
  ## line, then capped at MaxSayRunes on a RUNE boundary.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxSayRunes)

proc sanitizeNote*(text: string): string =
  ## The cog's private scratchpad, echoed back to this seat only next turn.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc mix64*(a, b, c, d: int): uint64 =
  ## splitmix64 over the four mixed words. THE ONLY source of randomness in
  ## this game, and it is a pure hash, not a consumed stream: task k's layout
  ## is identical no matter what happened in task k-1, which is the strongest
  ## form of the idea's "task seeds held out".
  var x = 0x9E3779B97F4A7C15'u64
  for value in [a, b, c, d]:
    x = x xor cast[uint64](int64(value))
    x = x * 0xBF58476D1CE4E5B9'u64
    x = x xor (x shr 30)
    x = x * 0x94D049BB133111EB'u64
    x = x xor (x shr 27)
  x = x xor (x shr 31)
  x

proc mix64*(a, b, c: int): uint64 = mix64(a, b, c, 0)

proc draw*(seed, taskIndex, salt, bound: int): int =
  ## One seeded draw in `0 ..< bound`, evaluated independently of every other
  ## draw. Integer only.
  if bound <= 1:
    return 0
  int(mix64(seed, taskIndex, salt) mod uint64(bound))

proc parseDir*(text: string): tuple[ok: bool, dir: Dir] =
  ## Case-insensitive, accepting both the letter and the word.
  case text.strip().toLowerAscii()
  of "e", "east": (true, dirEast)
  of "s", "south": (true, dirSouth)
  of "w", "west": (true, dirWest)
  of "n", "north": (true, dirNorth)
  else: (false, dirEast)

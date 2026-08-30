# Snake Challenge QUADRO — wire protocol specification

Reverse-engineered from the `M3wPSnakeChallenge` sources (branch `main` — note: the repo
has **no `master` branch**; `master` URLs redirect to `main`). Authoritative files:

- `src/SnakeClasses.pas` — frame codec (`TBaseMessage.Encode/Decode`), category/method map
- `src/SnakeServer.pas` (11,008 lines) — all game logic, every message handler and sender
- `src/TCPServer.pas` — socket layer (no extra framing of its own)
- `SnakeQuadroCLIServer.lpr` — main loop (keepalive pump, limbo expiry, port 19763)
- `src/M65/snake_game.s`, `src/M65/framework/fw_ctrls_net.s` — the real MEGA65 client
- `tools/ghost_client.py` — a Python dev client (written for the chess-era server, port
  19762, but the framing/handshake code is identical and current)

**The `src/LUA/*.lua` files are NOT protocol references.** They are the *original*
ComputerCraft (Minecraft) snake game this is a port of — `client1.lua` polls redstone
inputs, `server.lua` is the original single-machine game logic. Nothing in them speaks
this TCP protocol. They matter only as the source of game-rule semantics (tile types,
food effects), which the Pascal server re-implements.

---

## 1. Transport and framing

- **TCP, port 19763**, IPv4, server binds `0.0.0.0` (`TCPListener:= TTCPListener.Create('19763')`
  in the `.lpr`). `TCP_NODELAY` is set server-side. Default `MaxConnections = 64`
  (`FMaxConnects:= 64` in `TTCPServer.Create`; `-m <n>` overrides; `0` = unlimited).
- **No TLS, no WebSocket.** A browser client needs a TCP↔WebSocket proxy; the protocol
  itself is a plain byte stream.
- **Frame format** (`TBaseMessage.Encode`, SnakeClasses.pas:313):

  ```
  byte 0        LEN     = 1 + length(payload)      (counts the catg/method byte + payload,
                                                    NOT itself)
  byte 1        CM      = (category << 4) | (method & $0F)
  byte 2..LEN   payload = 0..254 bytes
  ```

  Total frame size = LEN + 1 bytes. Minimum valid frame is 2 bytes (`01 CM`).
  Maximum payload is **254 bytes** (LEN is a byte, max 255). The MEGA65 client's network
  stack additionally caps payloads at **235 bytes**, and the server respects that cap in
  its own senders (see TileDelta chunking) — a JS client only needs to *parse* up to 254.
- **Byte order:** everything is single bytes except the level-clock seconds in GameStatus,
  which is **little-endian 16-bit** (`m.Data[1]:= secs and $FF; m.Data[2]:= (secs shr 8)`).
- **Text encoding:** ASCII (`AnsiString`, one byte per char). No PETSCII on the wire —
  the MEGA65 client converts locally. Server name comparisons are case-insensitive
  (`CompareText`). Text-style payloads are **space-joined parameter lists**: params are
  concatenated with `$20` separators (`DataFromParams`) and split on every `$20`
  (`ExtractParams`) — so an individual parameter can never contain a space.
- **Stream reassembly** (`.lpr` `DoReadData`): the server accumulates bytes per connection
  and peels frames off by the LEN byte; partial frames wait for more data, multiple frames
  per TCP segment are fine. Your client must do the same (see `ghost_client.py::_drain`:
  `total = buf[0] + 1`).
- **Malformed frames are fatal.** `TBaseMessage.Decode` requires
  `Length(frame) = LEN + 1` and `Length(frame) > 1`; a bad length maps the message to
  `mcSystem/$0F` and an out-of-range category (>6) to `mcSystem/$0E` — and the
  SystemZone handler **disconnects the sender for any inbound `mcSystem` message**
  (SnakeServer.pas:2953: `else if (AMessage.Category = mcSystem) then ... DisconnectByIdent`).
  Sending `00`, or a frame whose LEN doesn't match, kills your connection. (Also true of a
  *deliberate* `mcSystem/$00` "hang up" — that is the official way to disconnect.)
- **Server send path:** outbound messages are queued per connection and flushed by a worker
  thread on a 20 ms loop; the dispatcher processes inbound on its own 20 ms loop; zone
  housekeeping (limbo promotion, keepalive, text lists) runs on the 100 ms main loop; the
  game simulation ticks every **83 ms** (`TICK_MS = 83`, ~12 Hz).

### Category nibble values

`TMsgCategory = (mcSystem, mcText, mcLobby, mcConnect, mcClient, mcServer, mcPlay)` —
ordinals 0..6, so the high nibble of byte 1 is:

| nibble | category | name string (`ARR_LIT_NAM_CATEGORY`) |
|---|---|---|
| 0 | mcSystem | `system` |
| 1 | mcText | `text` |
| 2 | mcLobby | `lobby` |
| 3 | mcConnect | `connect` |
| 4 | mcClient | `client` |
| 5 | mcServer | `server` |
| 6 | mcPlay | `play` |

---

## 2. Complete message reference

Notation: `[a, b, …]` = raw payload bytes; `"a b …"` = space-joined ASCII params.
CM = the combined byte.

### mcSystem (0x0_)

| CM | dir | meaning |
|---|---|---|
| `$00` | C→S | Hang up. Any inbound mcSystem message (any method) makes the server disconnect you. Never sent by the server. |
| `$0E`/`$0F` | — | internal markers for invalid-category / invalid-length frames (also handled as mcSystem ⇒ disconnect). |

### mcText (0x1_) — the "list" streaming machinery

Used for the system-info banner/MOTD and for lobby/play list results. A "list" is
identified by a short name derived from your username plus one digit `0`–`9`
(e.g. name `WEB` → list `WEB0`; the digit lands at position `min(len+1, 8)`, so an
8-char name has its last char replaced). Lists are pushed 15 lines per 100 ms batch.

| CM | dir | payload | meaning |
|---|---|---|---|
| `$10` | C→S | empty | **GetSysInfo** — request the server banner + MOTD poem. Handled by SystemZone (works even in limbo? — no: SystemZone is a zone you're always in, so yes, works immediately). Server responds with a Begin/Data/More list of category `system`: 7 banner lines (`'----------------------------'`, `'~{_/*\_/*\_/*\_/*\_/*\_/*\}~'`, `'Snake Challenge QUADRO development system'`, …, `'M3wP /Ecclestial Solutions'`, …) plus up to 8 poem lines from `motd/`. The real client sends this right after the handshake. |
| `$11` | S→C | `"<list> <category> [<context>]"` | **Begin** — a list is starting. `<category>` is `system`/`lobby`/`play`; `<context>` (3rd param, only for member listings) is the room/board name. |
| `$12` | S→C | `"<list> <remaining>"` | **More** — end of a ≤15-line batch; `<remaining>` is the count still queued (ASCII decimal). `0` ⇒ list complete. |
| `$12` | C→S | `"<list>"` | **More (request)** — ask for the next batch of that list. A list not continued within ~10 min (6000 × 100 ms) is dropped. |
| `$13` | S→C | `"<list> <line…>"` | **Data** — one line. Everything after the first space is the line (lines may contain spaces). |
| `$14` | C→S | `"<target> <text…>"` | **Peer** — private message to a named player. |
| `$14` | S→C | `"<sender> <text…>"` | Peer delivery — the server overwrites param 0 with the *sender's* name. Error if no target param: mcServer/$00 `Invalid text peer`. |

### mcLobby (0x2_) — chat rooms (separate from game boards)

| CM | dir | payload | meaning |
|---|---|---|---|
| `$20` | S→C | empty | **Error** — bad room password on join. |
| `$21` | C→S | `"<room> [<password>]"` | **Join** (creates the room if absent; ≤8 chars of name used). |
| `$21` | S→C | `"<room> <name>"` | Join broadcast to every member (including you — this is your join confirmation). |
| `$22` | C→S | `"<room>"` | **Part**. Error: mcServer/$00 `Invalid lobby part`. |
| `$22` | S→C | `"<room> <name>"` | Part broadcast. |
| `$23` | C→S | `""` or `"<room>"` | **List** — no param: list public room names; with param: list members. Reply arrives as an mcText list (category `lobby`). Error: `Invalid lobby list`. |
| `$24` | C→S | `"<room> <anything> <text…>"` | **Room chat** — param 1 is a placeholder; the server overwrites it with your real name. |
| `$24` | S→C | `"<room> <sender> <text…>"` | Room chat broadcast (echoed to the sender too). |

### mcConnect (0x3_)

| CM | dir | payload | meaning |
|---|---|---|---|
| `$31` | C→S | `"<username>"` | **Set username.** Exactly one param, length > 1; only the first 8 chars are kept; must be unique (case-insensitive) among connected players and settable once per connection. |
| `$31` | S→C | `"<username> "` | Success echo (the server appends your then-empty old name as a second param, so the payload has a trailing space). Failure ⇒ mcServer/$00 `Invalid connect ident`. |

### mcClient (0x4_)

| CM | dir | payload | meaning |
|---|---|---|---|
| `$41` | C→S | `"<name> <host> <version>"` | **Client identify.** Exactly 3 params. The ghost client sends `ghost PC 0.00.01A`; the MEGA65 sends its own triple. Content is not validated beyond the count. Once per connection. Failure ⇒ mcServer/$00 `Invalid client ident`. |
| `$42` | C→S | empty | **KeepAlive** — response to the server's challenge. |
| `$42` | S→C | empty | Server's no-op acknowledgment of your keepalive (exists purely to give your TCP ACK something to piggyback on — ignore it). |

### mcServer (0x5_)

| CM | dir | payload | meaning |
|---|---|---|---|
| `$50` | S→C | `"<error text…>"` | **Server error.** Known texts: `Invalid client ident`, `Invalid connect ident`, `Unrecognised command`, `Invalid lobby join/part/list`, `Invalid text peer`, `Invalid play join/part/list`, `Play in progress or full`, `Invalid corner claim`, `Corner already taken`, `Already holding a corner`. |
| `$51` | S→C | `"alpha <platform> 0.00.01A"` | **Server greeting**, sent immediately on connect. `<platform>` ∈ `mswindows`/`linux`/`macos`/`unix`/`android`. Receiving this is the trigger to send `$41` + `$31`. |
| `$52` | S→C | empty | **KeepAlive challenge.** Reply with `$42` (empty). See §6. |

### mcPlay (0x6_) — the game itself

| CM | dir | payload | meaning |
|---|---|---|---|
| `$60` | S→C | `"Play in progress or full"` | Play error (only used for the 64-spectator cap on join). |
| `$61` | C→S | `"<board>"` | **Join board** (as spectator). Boards are the fixed set `board1`(easy, MaxProgress 4), `board2`(normal, 6), `board3`(hard, 9), `board4`(expert, 14), `board5`(training, 2) — `ARR_SNAKE_BOARDS`. On success the server immediately sends you GameStatus (`$66`) plus one SlotStatus (`$67`) per currently-claimed corner. **There is no join broadcast** (unlike chess/lobby). Bad name ⇒ `Invalid play join`. |
| `$62` | C→S | `"<board>"` | **Part** — leave the board zone (releases your corner if you hold one, broadcasts its SlotStatus). |
| `$63` | C→S | `""` or `"<board>"` | **List** boards / board members, replied as an mcText list (category `play`). |
| `$64` | C→S | `"<text…>"` | **Game chat.** ⚠ server does `ExtractParams` and re-broadcasts only `Params[0]` — i.e. **only the first space-delimited word of your chat line survives** (SnakeServer.pas:10218/10230). The MEGA65 client sends its chat box verbatim, so multi-word chat is silently truncated to word 1 by the current server. |
| `$64` | S→C | `"<sender> <word>"` | Chat broadcast to everyone in the zone (spectators included, sender included). |
| `$65` | C→S | `[slot]` | **SlotClaim** — press START on a corner. `slot` = `0..3` or `$FF` (`SLOT_CLAIM_ANY` = lowest free). Success ⇒ SlotStatus broadcast for that slot (yours has `isyou=1`). Refusals: `Already holding a corner` / `Corner already taken` / `Invalid corner claim` via mcServer/$00, **plus** (for a concrete slot number) a unicast SlotStatus for that slot so your "claim outstanding" marker clears. |
| `$66` | S→C | `[state, secsLo, secsHi, 20×char]` | **GameStatus** — see §4.1. |
| `$67` | S→C | `[slot, pstate, isyou, lives, 6×digit, gear]` | **SlotStatus** — see §4.2. |
| `$68` | C→S | empty | **SlotRelease** — give up your corner (silent no-op if you hold none). |
| `$69` | S→C | `[count, (row, col, tile) × count]` | **TileDelta** — cells that changed this tick. `count ≤ 78` (`PLAY_DELTAS_PER_MSG`; 1 + 78×3 = 235 bytes); a heavy tick is split across multiple `$69` messages, apply them in arrival order. Sent only to **watchers**. |
| `$6A` | C→S | `[startRow]` | **BoardRowsReq** — ask for 2 rows. `startRow` must be **even** and `0..18`; anything else is *silently ignored* (no error), so drive the sync with a retry timeout (the M65 client retries after ~20 frames ≈ 350 ms). |
| `$6B` | S→C | `[startRow, 30 bytes row startRow, 30 bytes row startRow+1]` | **BoardRowsData** — 61-byte payload, cols left→right (col 0 first), row 0 = top. Also sent **unsolicited, all 10 pairs**, to every watcher whenever the board is rebuilt wholesale (play starts/stops, level change) — `PushBoardToWatchers`. |
| `$6C` | C→S | empty | **WatchStart** — "my UI is on the board page". Adds you to the Watchers list; required to receive `$69`, `$6B` pushes, and shake. Does not itself push anything — you then pull rows via `$6A`. |
| `$6C` | S→C | `[frames]` | **Shake** — jiggle the screen for `frames` display frames (50 Hz assumed; 1 frame = 20 ms). Cued ~0.8 s before a lava eruption (110 frames = 2.2 s), on a boss hit (8) and boss kill (25). ⚠ same method number as WatchStart — disambiguated purely by direction. |
| `$6D` | C→S | empty | **WatchStop** — left the board page. |
| `$6E` | C→S | `[dir]` | **Direction** — `0`=up, `1`=down, `2`=left, `3`=right (`TSnakeDir` ordinals; confirmed against the client's `SNAKE_DIR_*`). Fire-and-forget, no ack, no sequence numbers; the newest replaces the old. Silently ignored if malformed, if you hold no live snake, if it equals the current pending look, or if it is the *reverse of the direction last actually travelled* (reversal refusal — you can't eat your own neck). |
| `$6F` | — | — | unused (the one spare method number). |

Messages the SnakeClasses.pas comment block lists but that have **no server handler** (would
bounce as mcServer/$00 `Unrecognised command`): mcPlay `$65 KickPeer` (comment stale — $65
is now SlotClaim), `$6E GameChat` (moved to `$64` on 2026-08-25). Trust the code, not that
comment block — it predates the 2026-08 changes.

---

## 3. Connection lifecycle

### 3.1 Handshake

```
S→C  $51  "alpha linux 0.00.01A"          server greeting (immediately on accept)
C→S  $41  "webclient PC 0.00.01A"         client identify (3 params, any content)
C→S  $31  "MYNAME"                        username (2..8 chars, unique)
C→S  $10  (empty, optional)               sysinfo/MOTD request
S→C  $31  "MYNAME "                       username accepted
S→C  $11/$13/$12 …                        banner+poem list (if requested)
```

**The limbo gate:** a fresh connection sits in the "limbo" zone. Promotion into the
lobby/play zones happens on the server's **100 ms housekeeping tick**, only once *both*
client-ident and username are set (`TLimboZone.ExpirePlayers`). Any mcLobby/mcPlay message
sent before promotion bounces with mcServer/$00 `Unrecognised command` — so **wait
~300 ms after the handshake** (ghost_client.py uses exactly `time.sleep(0.3)`), or retry
the join on that specific error. If ident+username haven't both landed within **60 s**
(600 × 100 ms), the server drops the connection ("auth failure").

### 3.2 Join, watch, sync

```
C→S  $61 "board1"                         join board (spectator)
S→C  $66 [0, secsLo, secsHi, "LEVEL..."]  game status snapshot
S→C  $67 […] per claimed corner           slot snapshots
C→S  $6C (empty)                          WatchStart
C→S  $6A [0]                              request rows 0-1
S→C  $6B [0, 60 tile bytes]
C→S  $6A [2] … $6A [18]                   … until all 10 pairs held
```

Track which row pairs have arrived and re-request any pair not answered within ~350 ms.
After the initial sync, keep applying `$69` deltas; treat any unsolicited `$6B` as
authoritative overwrite of those two rows (level changes push the whole board this way,
*before* the deltas of the new level start flowing — deltas generated during a rebuild are
deliberately discarded server-side).

### 3.3 Playing

```
C→S  $65 [$FF]                            claim any corner (or [0..3] for a specific one)
S→C  $67 [slot, 5, 1, 3, "000000", gear]  psPlaying, isyou=1, 3 lives   → you're in
S→C  $6B ×10 + $66                        (if this claim flipped the board into play mode:
                                           full level push; otherwise you respawn onto the
                                           running board within 1 tick, shielded 3 s)
C→S  $6E [dir]                            steer (send on stick change only; the M65 client
                                           sends one message per direction change)
S→C  $69 …                                board deltas, ~up to 12/sec (only when cells moved)
S→C  $66 …                                once per second (clock), and immediately on change
S→C  $67 …                                on any slot event: death (lives-1, state 5),
                                           respawn, pickup that shifts your gear, score change
                                           is NOT broadcast per-food… (see note below)
```

Note on SlotStatus frequency: the server broadcasts SlotStatus on claim/release/death/
respawn and whenever a corner's *gear* changes (`PlayGear` change detection in the tick
loop); the score/lives ride along on whichever of those fires. Don't assume a SlotStatus
per food eaten.

- **Death:** snake removed (cells vacated via deltas), `lives` decremented; if lives remain,
  respawn after 2 s (`PLAY_RESPAWN_TICKS`) at your corner's fixed circuit position with a
  3 s flashing shield. On the death and again on respawn you get SlotStatus broadcasts.
- **Run over (lives = 0):** the corner reverts to spectator — SlotStatus arrives with
  `pstate = 0` (psNone), `isyou = 0`, and the final score still in the digits (score is
  cleared on *claim*, not on release, so it stays on the HUD). There is no separate
  "game over" message: `pstate 5→0 with isyou previously 1` **is** your game-over signal.
  You remain a spectator/watcher in the zone.
- **Board start/stop edge:** first corner claimed on an idle board → `StartPlay` (level 1
  built, full board push); last corner released → `StopPlay` (attract/demo board rebuilt,
  full push, demo reel resumes as deltas). Spectating an idle board shows the attract
  reel: 4 demo snakes lapping the inset rectangle plus lava/bees/food/boss showcase waves.
- **Leaving:** send `$6D` WatchStop when hiding the board UI, `$68` to release your corner,
  `$62 "board1"` to leave the zone, `$00` (mcSystem hang-up) or just close the socket to
  disconnect. Server-side disconnect cleanly releases everything.

### 3.4 Level structure (for HUD logic)

- Levels last **120 s** (`PLAY_LEVEL_MS`); the last **30 s** are the "ramp" (one extra bee,
  one gear faster; the client is expected to colour the clock red below
  `PLAY_STATUS_WARN_SECS = 30` — that's what the raw seconds in `$66` are for).
- Stage cycle of 8, from `(LevelNumber - 1) mod 8` (`PLAY_STAGE_*` arrays):
  stages 1-3 bees, **4 lava (tier 1)**, 5-6 bees, **7 lava (tier 2)**, **8 boss**
  (boss stage keeps its bees). Keys spawn on stages 1,2,3 (2 chances) and 5,6 (1 chance);
  none on lava/boss stages.
- On a **boss level the clock is frozen** — `$66` keeps arriving but seconds don't move,
  and the status text switches to `LEVEL  8   BOSS ***` (one `*` per remaining boss life).
  The level ends only when the boss dies (then a 2.5 s beat, then the next level's board
  push).
- Level change (`NextLevel`): everyone alive is respawned at their corner; lives and score
  carry over ("a level change is not a new game").

---

## 4. Server→client payload layouts in detail

### 4.1 GameStatus — `$66`, payload 23 bytes

| offset | size | value |
|---|---|---|
| 0 | 1 | `TGameState` ordinal (`gsWaiting=0, gsPreparing=1, gsPlaying=2, gsPaused=3, gsFinished=4`). ⚠ the server never assigns `State` after construction, so **this byte is always 0 in practice** — ignore it. |
| 1 | 2 | seconds left on the level clock, **little-endian** (rounded up; 0 only when the level is genuinely over). |
| 3 | 20 | status line, ASCII, space-padded to exactly `PLAY_STATUS_LEN = 20`: `LEVEL %2d   TIME m:ss` or, while the boss is on the board, `LEVEL %2d   BOSS ***…` (a `*` per boss life). Render verbatim. |

Sent: on zone join, then to everyone in the zone whenever the *displayed* second changes
(≈1/sec while playing; not at all while the board idles in attract mode).

### 4.2 SlotStatus — `$67`, payload 11 bytes

| offset | size | value |
|---|---|---|
| 0 | 1 | slot 0..3 |
| 1 | 1 | `TPlayerState` ordinal — in practice only `0` (psNone, free/released) and `5` (psPlaying, claimed). Full enum: psNone=0, psIdle=1, psReady=2, psPreparing=3, psWaiting=4, psPlaying=5, psFinished=6, psWinner=7. |
| 2 | 1 | `isyou` — 1 iff this slot is held by *you* (the message is personalised per recipient). |
| 3 | 1 | lives remaining (starts at `PLAY_START_LIVES = 3`; bonus life at every 100,000 points). |
| 4 | 6 | score as **6 ASCII digits, zero-padded** (`000000`–`999999`, clamped). |
| 10 | 1 | gear = current **ticks-per-step, smaller is faster**: 6=very slow (2.0 steps/s), 5=slow (2.4), 4=normal (3.0), 3=fast (4.0), 2=fastest (6.0), 1=top (12.0); `0` = corner unoccupied. A dead-but-respawning snake reports the board's base gear. |

### 4.3 TileDelta — `$69`

`[count][row col tile] × count`, count ≤ 78. Row 0..19, col 0..29, tile per §5.
Update your local grid cell-by-cell; the server keeps its own `Board` byte-identical to
what the deltas describe, so deltas and row fetches never disagree.

### 4.4 BoardRowsData — `$6B`

`[startRow][30 bytes of row startRow][30 bytes of row startRow+1]` — 61 bytes.
`startRow` even, 0..18. Columns run left (0) → right (29).

---

## 5. Board geometry and the tile byte

Board is **30 columns × 20 rows** (`BOARD_COLS = 30; BOARD_ROWS = 20`), row 0 at top,
solid `TILE_WALL` ring around the outside, interior geometry per level (4 mirrored wall
variants that grow with difficulty; centre 4×4 always kept clear for the boss spawn).

`TILE_COUNT = 78` distinct values (0..77). The MEGA65 client indexes its char/colour
tables by raw tile value with **no bounds check** — your client should treat ≥78 as
"unknown, render as floor" defensively.

⚠ The numeric ranges quoted in some SnakeServer.pas *comments* ("lava 57..59, bee 60,
food 61..64") are stale — they predate the boss becoming a 5th render slot. The
*expressions* are authoritative; evaluated with `SNAKE_RENDER_SLOTS = 5` they give:

| value | meaning |
|---|---|
| 0 | `TILE_FLOOR` |
| 1 | `TILE_WALL` |
| 2 | `TILE_ATTRACT` (legacy attract bounce; kept for numbering stability, unused) |
| 3–62 | snake segments: `tile = 3 + ((player*2 + role)*6) + shape` |
| 63–68 | `TILE_SNAKE_FLASH_BASE + shape` — white invulnerability-flash **body** (any snake; the head never flashes, it keeps its player tile) |
| 69–71 | lava, by age tier: 69 = hot core (oldest third of the pool), 70 = middle, 71 = cooling crust (newest). Heat ramp yellow/orange/brown. |
| 72 | `TILE_BEE` (char `$DA`, colour `$04` per dengland) |
| 73 | food 0 — clubs (`$58`): no-grow 1.5 s, speed +, **1200 pts** |
| 74 | food 1 — solid circle (`$51`): extra-grow 4 s, speed −, **400 pts** |
| 75 | food 2 — open circle (`$57`): big speed burst, **800 pts** |
| 76 | food 3 — heart (`$53`): shield 4 s (cap 5 s), speed +, **1000 pts** |
| 77 | food 4 — THE KEY (screen code `$00` = `@`, yellow): cuts the level clock to 30 s, **2000 pts**; scheduled, short-lived (4–6 s on the board) |

Snake tile sub-ranges (player, role):

| player | body (shape 0..5) | head (shape 0..5) |
|---|---|---|
| 0 | 3–8 | 9–14 |
| 1 | 15–20 | 21–26 |
| 2 | 27–32 | 33–38 |
| 3 | 39–44 | 45–50 |
| 4 = **boss** (cyan body, purple head) | 51–56 | 57–62 |

Shapes (`SHAPE_*`, named by the compass directions the pipe opens toward; suggested
C64 screen codes from the design notes in brackets):

| shape | opens | char |
|---|---|---|
| 0 `SHAPE_HORZ` | E–W | `$C0` |
| 1 `SHAPE_VERT` | N–S | `$DD` |
| 2 `SHAPE_WS` | W+S | `$C9` |
| 3 `SHAPE_NE` | N+E | `$CA` |
| 4 `SHAPE_NW` | N+W | `$CB` |
| 5 `SHAPE_ES` | E+S | `$D5` |

Snakes render as connected pipes: a head that has committed to a turn shows the corner
shape one step early; the invulnerability flash alternates body tiles between the player
range and 63–68 every tick (every 2 ticks when the shield is about to run out —
"half-speed flash" warning). All of this arrives pre-computed in the tile byte; the
client just draws what it's told.

Bees eat/kill on contact (1500 pts if you eat one while shielded); lava kills; walls and
other snakes kill unless you or they are floating/shielded; a mutual head-on shields both
parties (and on the boss stage, a head-on is the only way to damage the boss —
5000 pts/hit, 20000 for the kill).

---

## 6. Keepalive and expiry (mandatory)

From `TPlayer.KeepAliveDecrement` / `PlayersKeepAliveExpire` / the `.lpr` main loop:

- Every player *not in limbo* has a 30,000 ms countdown, decremented 100 ms per main-loop
  pass. **Any inbound message that a zone handles resets it** (dispatcher calls
  `KeepAliveReset` on every handled message) — steering traffic counts.
- When it hits 0 the server sends `$52` (mcServer/2 Challenge, empty), increments a miss
  counter, and re-arms 30 s. The client must answer `$42` (mcClient/2, empty); that resets
  counter and misses (and the server replies with a no-op `$42` of its own).
- At **5 consecutive misses (~2.5 min of total silence)** the player is removed and the
  connection closed.
- So the simplest correct JS client: on receiving byte pair `01 52`, immediately send
  `01 42`. Nothing needs to be sent proactively.
- Separately: limbo expiry (60 s to complete the handshake, §3.1), and the server also
  detects half-closed sockets (FIN) and errors on its 20 ms worker loop.

---

## 7. Worked example — annotated byte transcript

Client `WEB` connects, identifies, joins board1, watches, syncs one row pair, claims a
corner, turns left. (Frames shown one per line; on the wire they may coalesce.)

```
--- TCP connect to 19763 ---

S→C  15 51 61 6C 70 68 61 20 6C 69 6E 75 78 20 30 2E 30 30 2E 30 31 41
     len=$15(21) cm=$51 (Server/Identify)  "alpha linux 0.00.01A"

C→S  16 41 77 65 62 63 6C 69 65 6E 74 20 50 43 20 30 2E 30 30 2E 30 31 41
     len=$16(22) cm=$41 (Client/Identify)  "webclient PC 0.00.01A" (21 chars payload;
     always compute len = 1 + payload.length)

C→S  04 31 57 45 42
     len=4 cm=$31 (Connect/Identify)  "WEB"

S→C  05 31 57 45 42 20
     cm=$31 echo: "WEB " (accepted; note trailing space = appended empty old-name param)

     … client waits ~300 ms (limbo promotion happens on the 100 ms housekeeping tick) …

C→S  07 61 62 6F 61 72 64 31
     len=7 cm=$61 (Play/Join)  "board1"

S→C  18 66 00 3C 00 4C 45 56 45 4C 20 20 31 20 20 20 54 49 4D 45 20 31 3A 30 30
     len=$18(24) cm=$66 GameStatus: state=0, secs=$003C=60 (LE), "LEVEL  1   TIME 1:00"
     (idle board would show the full 2:00; values here illustrative)

S→C  0C 67 00 05 00 03 30 30 34 32 30 30 05
     len=$0C(12) cm=$67 SlotStatus: slot 0, pstate 5 (playing), isyou 0,
     lives 3, score "004200", gear 5   — someone else already on corner 0

C→S  01 6C
     cm=$6C WatchStart (empty payload, len=1)

C→S  02 6A 00
     cm=$6A BoardRowsReq startRow=0

S→C  3E 6B 00  01 01 01 … (30 bytes: row 0, all TILE_WALL=$01)
              01 00 00 … 00 01 (30 bytes: row 1, wall/floor/wall)
     len=$3E(62) cm=$6B BoardRowsData
     … client repeats $6A for rows 2,4,…,18, retrying any pair not answered in ~350 ms …

C→S  02 65 FF
     cm=$65 SlotClaim, slot=$FF (any free corner)

S→C  0C 67 01 05 01 03 30 30 30 30 30 30 05
     cm=$67 SlotStatus: slot 1, pstate 5, isyou 1, lives 3, score "000000", gear 5
     → we hold corner 1; (broadcast to everyone else with isyou 0)

S→C  0D 69 04 11 07 00 11 08 0F 11 09 15 12 09 09
     len=$0D(13) cm=$69 TileDelta count=4:
       (17, 7)→$00     floor — tail vacated
       (17, 8)→$0F=15  player-1 body HORZ  (3 + ((1*2+0)*6) + 0)
       (17, 9)→$15=21  player-1 head HORZ  (3 + ((1*2+1)*6) + 0)
       (18, 9)→$09=9   player-0 head HORZ
     (spawn/step traffic; exact cells depend on the live game)

C→S  02 6E 02
     cm=$6E Direction = 2 (left).  No reply; the turn shows up as head-repaint deltas.

     … 30 s of steering with no other traffic would eventually elicit:
S→C  01 52                    keepalive challenge
C→S  01 42                    keepalive response
S→C  01 42                    server's piggyback ack (ignore)
```

---

## 8. Gaps and uncertainties

1. **Stale comment block in SnakeClasses.pas** — the method list there (`$64 TextPeer
   unused`, `$65 KickPeer unused`, `$6E GameChat`) describes the chess-era layout. The
   server code (§2) is what's real: `$64`=chat, `$65`=SlotClaim, `$6E`=Direction. I have
   used the code throughout.
2. **GameStatus `state` byte:** `TSnakeGame.State` is never written after construction
   (grep for `State:=` finds only *slot* states), so byte 0 of `$66` is constant 0
   (gsWaiting) even mid-game. Don't key any logic off it; use SlotStatus and the presence
   of deltas instead. If a future server version starts setting it, ordinals are as
   listed in §4.1.
3. **Chat truncation:** inbound `$64` chat is split on spaces and only `Params[0]` is
   re-broadcast (SnakeServer.pas:10218-10231). Whether this is intended (one-word chat)
   or a latent bug is unknowable from source — the client sends the full line. A JS
   client should not promise multi-word chat delivery.
4. **Reject path:** when `MaxConnections` is hit, `OnReject` fires but the `.lpr` handler
   is an empty TODO ("Send a nice server error message") and the connection object is
   never added to a worker — from the client side the socket likely just sits unanswered
   (no greeting). Treat "no `$51` within a few seconds" as connect failure.
5. **BoardRowsReq validation is silent** — odd or out-of-range `startRow` gets no reply
   and no error. The retry loop is mandatory, not defensive.
6. **SlotStatus cadence:** I verified broadcasts on claim/release/death/respawn/gear-change
   and on the per-recipient snapshots at join; I did *not* exhaustively trace every
   `SlotStatusToAll` call site in the 11k-line file (e.g. eat-food may or may not fire one
   directly vs. riding the gear change). Render score/lives from the latest `$67` whenever
   one arrives; don't assume you'll see every increment.
7. **Demo/attract deltas:** while a board is idle, watchers still receive `$69` streams
   (the attract reel) and occasional `$6C` shakes. Values use the same tile table; no
   special handling needed, but don't interpret demo snakes as claimable state.
8. **Exact spawn positions/direction of travel** at respawn are derivable
   (`SpawnPlayerSnake` walks the demo circuit: rectangle inset 2 from the border, four
   snakes a quarter-lap apart) but the client never needs them — everything arrives as
   tiles. Your snake's initial `Dir` after spawn is whatever the circuit gives; the
   reversal-refusal means your first Direction message may be silently dropped if it
   happens to be the reverse — harmless.
9. **Text params ≤ 8 chars:** usernames, room names and list names are truncated to 8
   server-side; board names in `ARR_SNAKE_BOARDS` are ≤ 6 and matched case-insensitively.
10. **The M65 payload cap (235)** never binds the *receiving* client — no current server
    message exceeds 235 bytes payload (largest: TileDelta 235, BoardRowsData 61,
    GameStatus 23) — but parse defensively up to 254.
11. **Port check quirk:** fw_ctrls_net.s:9232 confirms 19763 (`$4D33`) and notes the
    client once byte-swapped it — the server end is definitively 19763.

---

12. **`ExtractParams` drops a trailing empty segment** (SnakeClasses.pas `ExtractParams`):
    `"abc "` yields ONE param on the server, not `["abc", ""]`. So the `$31` success echo
    `"WEB "` is `["WEB"]` server-side. `rgg_common.quadro.codec.params` splits on every
    `$20` (the client-side view, `["WEB", ""]`); `tools/mockquadro` layers
    `extract_params()` on it to reproduce the server exactly. Never rely on a trailing
    empty param surviving a round trip. (Found 2026-08-30 while building the mock; the
    mock's README lists seven more source-vs-spec details: untruncated `$31` echo, `$22`
    on a room you are not in, silent `$14` to an unknown player, `$21` param-count errors,
    `$23` on a private room, empty `$22`, and `$63` board list.)

## Protocol essentials (10 lines)

1. TCP 19763, plain bytes, no TLS; browser needs a WS↔TCP proxy; Nagle off server-side.
2. Frame: `[len][cat<<4|method][payload]`, len = 1+payload (excl. itself), payload ≤ 254; text = space-joined ASCII; the only 16-bit int (clock secs) is little-endian.
3. Malformed frames or any client→server category-0 message ⇒ server disconnects you.
4. Handshake: recv `$51` greeting → send `$41 "name PC 0.00.01A"` + `$31 "USERNAME"` → wait ~300 ms (limbo tick) → `$61 "board1"` to join as spectator.
5. Board: 30×20 tiles, byte per cell, 78 tile values (0 floor, 1 wall, 3–62 snakes ((p*2+role)*6+shape)+3, 63–68 flash, 69–71 lava, 72 bee, 73–77 food/key).
6. Sync: send `$6C` WatchStart, then pull rows two at a time with `$6A [evenRow]` → `$6B [row, 60 bytes]`, retrying ≈350 ms; thereafter apply `$69` deltas `[n,(row,col,tile)×n]` and treat unsolicited `$6B` pushes (level change) as overwrites.
7. Play: `$65 [0..3|$FF]` claims a corner, `$68` releases; `$67` SlotStatus `[slot,pstate,isyou,lives,"000000",gear]` is your claim/death/game-over feed (pstate 5=playing, 0=free; gear = ticks/step, smaller=faster).
8. Input: `$6E [dir]` with 0/1/2/3 = up/down/left/right, fire-and-forget; reversals silently refused.
9. Clock: `$66` GameStatus ~1/sec `[0, secsLE, 20-char status line]`; levels 120 s, cycle of 8 (4&7 lava, 8 boss with frozen clock); `$6C` server→client = screen shake `[frames]`.
10. Keepalive: on `01 52` reply `01 42` (server acks `01 42`, ignore); 5 unanswered 30 s challenges (~2.5 min silent) = drop; any handled message resets the timer.

---

## 9. Federation delta (RetroGameGate)

**Wire version: 1** (this section only; §1–§8 describe the server as it is today).
Tested by: `protocol/vectors/quadro-frames.json` (`username-otp`, `username-echo`),
`tools/mockquadro`, `tools/quadro_compat.py`.

This section is written as the change request we send to the author of
`M3wPSnakeChallenge`. Everything else in this file stays as it is; the changes below are
the complete list of what the portal needs from the game server. Line numbers refer to
`src/SnakeServer.pas` at the revision cached in `vendor/upstream/` (11,008 lines).

### 9.1 Why

RetroGameGate is a community portal that sits *in front of* independent game servers: users
log into the portal, chat in the server's lobby under their real portal name (the portal
opens one ordinary TCP connection per user to 19763), and are handed over to the game with
a **one-time password** when they start playing on a MEGA65. For that to work the server
must (a) let a name be up to 16 characters so portal identities survive, (b) accept an
optional second parameter on `$31` and ask a small local daemon ("sidecar") whether it is
good, and (c) tell that daemon who joined and left. The server keeps working exactly as
before for every existing client: a one-parameter `$31` from a walk-in player is still
accepted (now via a `NAME` query so that reserved portal names cannot be squatted), and
without the sidecar option on the command line nothing changes at all.

The sidecar is our code (Python, runs on the same host, listens on `127.0.0.1:19764`). The
line protocol it speaks is frozen in `protocol/sidecar-local.md`; you only ever need one
outbound TCP connection to it.

### 9.2 Usernames: 8 → 16 characters

The wire already carries any length (a param is just bytes up to the next space); the
limit is purely the `Copy(…, 8)` calls. Change the constant to 16 at these sites
(verified against the cached source):

| Line | Code today | Role |
|---|---|---|
| 3021 | `n:= Copy(AMessage.Params[0], 1, 8);` | `$31` handler in `TSystemZone.ProcessPlayerMessage` — **the** username truncation |
| 2967 | `n:= Copy(AMessage.Params[0], 1, 8);` | mcText `$12` "more" request — list-name lookup (list names derive from the username, see 3882 below) |
| 2996 | `n:= Copy(AMessage.Params[0], 1, 8);` | mcText `$14` peer message — target-name lookup |
| 3296 | `AMessage.Params[1]:= Copy(APlayer.Name, Low(AnsiString), 8);` | lobby `$24` chat broadcast — re-truncates the sender name |
| 10229 | `m.Params.Add(Copy(APlayer.Name, Low(AnsiString), 8));` | play `$64` chat broadcast — re-truncates the sender name |
| 3882–3897 | `TMessageList.Create`: `p:= Length(s) + 1; if p > 8 then p:= 8;` | mcText list-id derivation (`<name>` + digit; the digit lands at position `min(len+1, 8)`). Raise the clamp to 16 so two 16-char names that differ only after char 8 do not share a list id. |

Not in scope (leave as is): line 3608 truncates the **room** name to 8 (`$21` join); board
names are ≤ 6. `PlayerByName` (2811) already compares with `CompareText` and has no length
logic.

Portal names are `[a-z0-9_]{3,16}`; the portal folds everything to lowercase before
comparing, which matches your `CompareText`. We never send a name containing a space.

### 9.3 `$31 "<name> [<otp>]"`

Today (3016–3054) the handler requires `Params.Count = 1` and `Length(Params[0]) > 1`;
two params fall through to `SendServerError(LIT_ERR_CONNCTID)` at 3053. Requested
behaviour, only when the server was started with a sidecar address (`-s host:port`):

**Two params** (`"<name> <otp>"`):

1. Keep the player in limbo (do not set `APlayer.Name` yet). The 60 s limbo timer keeps
   running as today.
2. Send `VERIFY <name> <otp> <remote_ip> <req_id>` to the sidecar (`name` already cut to
   16 chars; `remote_ip` = the peer address of the connection).
3. On `OK <req_id> <name16>`: proceed **exactly as today** for a good username — the
   uniqueness check via `PlayerByName`, the `m.Params.Add(APlayer.Name)` echo
   (`$31 "<name16> "` with the trailing space, unchanged), `APlayer.Name:= <name16>`, log
   line — **but using `<name16>` from the reply**, not the client's spelling. If
   `PlayerByName` finds the name already live, reject with `$50 "Invalid connect ident"` as
   today (the sidecar has then consumed the OTP; that is acceptable — the portal reissues).
4. On `NO <req_id> <reason>`, or **no reply within 5 s**: `SendServerError(LIT_ERR_CONNCTID)`
   — the existing `$50 "Invalid connect ident"` — and leave the player in limbo, exactly
   as a bad one-param name is handled now. Do not close the socket; the client may retry
   with a different name, or the limbo expiry drops it.

**One param** (`"<name>"`, every existing client):

1. Send `NAME <name> <remote_ip> <req_id>`.
2. `OK <req_id> <name>` → proceed exactly as today. `NO <req_id> reserved|banned` or a 5 s
   timeout → `$50 "Invalid connect ident"`, stay in limbo.

The wait must not block your dispatcher thread: park the request (player + `req_id`) and
finish the `$31` when the reply lands (the sidecar answers in well under a millisecond from
its cache; the 5 s is a safety net). A player with a `$31` in flight who sends a second
`$31` gets `$50 "Invalid connect ident"` for the second one.

Test vector (`quadro-frames.json` → `username-otp`): the client frame
`11 31 6B 65 6E 20 37 51 33 4D 38 4B 32 5A 50 34 58 41` is `$31 "ken 7Q3M8K2ZP4XA"`;
the success echo is `05 31 6B 65 6E 20` (`"ken "`).

OTPs are 12 characters from `0-9 A-H J-N P-T V-Z` — never a space, so they are always a
legal param, and they cannot be confused with a name because the name always comes first.

### 9.4 `EVENT JOIN` / `EVENT PART`

Send `EVENT JOIN <name> <remote_ip>` at the moment `TLimboZone.ExpirePlayers` (3123) moves
a player to lobby/play, and `EVENT PART <name> <remote_ip>` whenever a player that has a
name is removed from `SystemZone` for any reason (hang-up `$00`, keepalive expiry, socket
error, `KICK`). Fire-and-forget; no reply; nothing to do if the sidecar socket is down.

### 9.5 Optional: `KICK <name> <reason>`

If it is cheap for you: on `KICK <name> <reason>` from the sidecar, disconnect that player
as if the socket had dropped (`DisconnectByIdent`), which then produces the usual
`EVENT PART`. Unknown name = ignore. If you leave this out the portal copes (the
one-connection lock frees itself on the next `PART` or after 90 s).

### 9.6 `fail_open` / `fail_closed`

A command-line switch. With the sidecar socket down (not yet connected, or dropped —
reconnect with 1/2/5/10 s backoff):

- `fail_closed` (default when `-s` is given): every `$31` is rejected with
  `$50 "Invalid connect ident"` until the sidecar is back. This is what a portal-fronted
  server wants — nobody can impersonate a portal user while the check is unavailable.
- `fail_open`: behave as before this change (uniqueness check only; a second param is
  ignored). For servers that also serve walk-ins without the portal.

Without `-s` at all: legacy behaviour, no sockets opened, this whole section is inert.

### 9.7 What does *not* change

Framing, categories, the greeting, the `$41` triple, keepalive, limbo timing (promotion on
the 100 ms tick, 60 s expiry), the error strings, the 235-byte MEGA65 cap, and every
mcLobby/mcPlay message. The portal's chat proxies are ordinary clients: they send
`$41 "rggportal portal <ver>"` then `$31 "<name> <otp>"`, join a lobby room, and answer
`$52` with `$42`. 8-bit walk-ins see portal users as ordinary, verified names.

### 9.8 How we test it

`tools/mockquadro` is an asyncio re-implementation of §1–§8 plus this section, and
`tools/quadro_compat.py` diffs it against the live server (`101.183.250.184:19763`) for the
greeting, limbo, keepalive and error strings. Once your build is up we run the same script
against it, then the sidecar end-to-end. A channel whose server does not yet have this
change is marked `legacy` on the portal (8-char names, no OTP, chat only).

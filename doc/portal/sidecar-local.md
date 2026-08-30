# Sidecar local protocol — game server ↔ sidecar on 127.0.0.1:19764

**Wire version: 1 — FROZEN v1. The game author codes against this document.** Any change
is a new version and needs the author's agreement first (see `README.md` §Versioning).

Tested by: `tools/mockquadro` (implements the Pascal side), `sidecar/rgg_sidecar/local_api`
(implements the sidecar side), and the integration fixture that runs both.

## 1. Purpose

The game server (`SnakeServer.pas` and siblings) has no accounts and no crypto. When a
client sends `$31 "<name> <otp>"` (see `quadro.md` §9) the server asks the sidecar, over
this connection, whether that name/OTP pair is good. The sidecar answers from a cache the
portal pre-fills, so the answer is normally sub-millisecond and works even if the portal
link is momentarily down. The same connection carries join/part events back to the sidecar
and (optionally) a kick request from the sidecar to the server.

## 2. Transport

| Item | Value |
|---|---|
| Listener | the **sidecar** listens on `127.0.0.1:19764` (TCP, IPv4, loopback only) |
| Dialler | the **game server** connects (outbound) at start-up and keeps the connection open |
| Connections | one at a time is enough; the sidecar accepts several (a second connection does not disturb the first) |
| Encoding | ASCII, one command per line, `\n` terminated (`\r\n` is tolerated on input; never emitted) |
| Separators | exactly one space (`0x20`) between fields; no leading/trailing spaces; a field never contains a space |
| Line length | ≤ 512 bytes including `\n`; longer lines are a protocol error (the receiver closes the socket) |
| Case | keywords are UPPERCASE; names are compared case-insensitively (like the game server's `CompareText`) |
| Reconnect | if the socket drops, the game server reconnects with backoff 1 s → 2 s → 5 s → 10 s (cap) |
| Answer deadline | **5 s** from sending `VERIFY`/`NAME`; no answer by then = treat as `NO` (see §6) |
| Ordering | requests may be pipelined; answers can arrive in any order — always match on `req_id` |

`req_id` is an unsigned decimal integer chosen by the game server (a per-process counter is
fine; it only has to be unique among outstanding requests on this connection). The sidecar
echoes it verbatim.

## 3. Messages: game server → sidecar

### `VERIFY <name> <otp> <remote_ip> <req_id>`

Asked when `$31` arrived with **two** params. `<name>` is the name the client typed (already
cut to 16 chars by the server), `<otp>` is the second param verbatim (12 chars of
`0-9 A-H J-N P-T V-Z`, the sidecar normalises case), `<remote_ip>` is the client's peer
address in dotted decimal (IPv4).

Replies (exactly one, always):

| Reply | Meaning / what the server does |
|---|---|
| `OK <req_id> <name16>` | Accept. **Use `<name16>` as the player's name** (it is the portal's canonical spelling, ≤ 16 chars, never contains a space). Proceed exactly as today for a good username: echo `$31 "<name16> "`, promote from limbo on the next tick. |
| `NO <req_id> unknown` | no such OTP (never issued, or issued for another channel) |
| `NO <req_id> expired` | OTP existed but its TTL passed |
| `NO <req_id> used` | OTP already consumed by an earlier connection |
| `NO <req_id> banned` | the user/device/IP behind this OTP is banned here |
| `NO <req_id> ippin` | the OTP was pinned to another IP (`ip_pin` option, `otp-handover.md` §8) |
| `NO <req_id> name` | the OTP is valid but was issued for a different name than `<name>` |

On any `NO`, and on timeout, the server answers the client with `$50 "Invalid connect
ident"` (its existing error text) and keeps the connection in limbo as it does today for a
bad username. The reason word is for the server's log only; it never goes to the client.

A `VERIFY` that returns `OK` **consumes** the OTP: a second `VERIFY` with the same OTP
returns `NO … used`.

### `NAME <name> <remote_ip> <req_id>`

Asked when `$31` arrived with **one** param (legacy client, no OTP). Lets the portal
reserve usernames: a name that belongs to a portal user may only be used with an OTP.

| Reply | Meaning |
|---|---|
| `OK <req_id> <name>` | fine, proceed as today with `<name>` (the sidecar returns it unchanged except for length/case normalisation — treat it as authoritative) |
| `NO <req_id> reserved` | this name belongs to a portal user; reject with `$50 "Invalid connect ident"` |
| `NO <req_id> banned` | the name or `<remote_ip>` is banned here; reject the same way |

### `EVENT JOIN <name> <remote_ip>` / `EVENT PART <name> <remote_ip>`

Fire-and-forget, no reply. `JOIN` is sent when a player is promoted out of limbo
(i.e. name accepted **and** client-ident present — the moment `TLimboZone.ExpirePlayers`
moves the player to lobby/play). `PART` is sent when a player with a name leaves for any
reason (hang-up, keepalive expiry, socket error, kick). A player who never got a name
produces no events. The sidecar uses these to keep the portal's "who is in the game" view
and the MEGA65 one-connection lock accurate; it tolerates duplicates and a `PART` without a
prior `JOIN`.

### `CHAT <room> <name> <text…>`

Optional (only if the server was started with the lobby-mirror feature on). Sent for every
lobby chat line the server broadcasts (`$24`). `<text…>` is the rest of the line and may
contain spaces. No reply. Sidecars that do not mirror simply ignore it.

### `PING`

Either side may send `PING`; the other answers `PONG`. Recommended: the game server sends
`PING` every 30 s when idle and treats no `PONG` within 5 s as a dead socket (close,
reconnect). The sidecar answers `PONG` immediately and never initiates unless idle > 60 s.

## 4. Messages: sidecar → game server

### `KICK <name> <reason>`

Optional capability (the author may leave it out of v1). Asks the server to disconnect the
named player as if the connection had dropped: send nothing to the client, close the socket,
emit the usual `EVENT PART`. `<reason>` is one word (`ban`, `admin`, `release`, `replaced`)
for the log. No reply. Unknown name = silently ignored.

### `PONG`

Answer to `PING`.

Any other line from the sidecar is ignored by the game server (forward compatibility).

## 5. Grammar (ABNF-ish)

```
line      = request / reply / event / chat / kick / "PING" / "PONG"
request   = "VERIFY" SP name SP otp SP ip SP reqid
          / "NAME"   SP name SP ip SP reqid
reply     = "OK" SP reqid SP name
          / "NO" SP reqid SP reason
event     = "EVENT" SP ("JOIN" / "PART") SP name SP ip
chat      = "CHAT" SP room SP name SP text
kick      = "KICK" SP name SP word
name      = 1*16( ALPHA / DIGIT / "_" / "-" / "." )        ; no SP ever
otp       = 12( DIGIT / %x41-48 / %x4A-4E / %x50-54 / %x56-5A ) ; Crockford, sidecar folds case
ip        = dotted-decimal IPv4
reqid     = 1*10DIGIT
reason    = "unknown" / "expired" / "used" / "banned" / "ippin" / "name" / "reserved"
text      = *VCHAR-and-SP                                   ; rest of line
```

Every line ends with LF. The receiver must ignore lines it does not understand (log them)
and must close on a line > 512 bytes or containing bytes < 0x20 other than CR/LF.

## 6. Failure behaviour

| Situation | Game server does |
|---|---|
| Socket to the sidecar is **down** and `$31` arrives with 2 params | `fail_closed` (default when the server was started with a sidecar address): reject with `$50 "Invalid connect ident"`. `fail_open`: ignore the OTP, treat as a 1-param `$31` (legacy behaviour: uniqueness check only). |
| Socket down and `$31` arrives with 1 param | `fail_closed`: reject. `fail_open`: legacy behaviour. |
| No reply within **5 s** | same as `NO` (reject). Do not block the main loop — keep the player in limbo and answer when the reply (or the deadline) lands; the limbo 60 s timer keeps running. |
| Reply with an unknown `req_id` | ignore (late answer after a timeout) |
| Sidecar process not present at server start | keep trying to connect with the backoff in §2; behave per `fail_open`/`fail_closed` meanwhile |

The `fail_open`/`fail_closed` switch is a command-line option of the game server
(suggested `-s 127.0.0.1:19764` to enable the sidecar, `--fail-open` to select the lenient
mode). Without `-s` the server behaves exactly as before this document.

The **sidecar** side: with the portal link down it keeps answering `VERIFY` from its cache
(OTPs already issued keep working until they expire) and answers `NAME` from its last
`names.sync` snapshot; it never blocks a `VERIFY` on a portal round-trip for longer than
3 s (`sidecar-ws.md` §5).

## 7. Worked transcript

Game server process starts, dials the sidecar, and three clients arrive: a portal user with
an OTP, a legacy walk-in with a free name, and a walk-in trying a reserved name.

```
S = game server (SnakeServer)      C = sidecar

--- TCP connect S → 127.0.0.1:19764 ---

S→C  PING
C→S  PONG

# client 1: $31 "ken 7Q3M8K2ZP4XA" from 203.0.113.7
S→C  VERIFY ken 7Q3M8K2ZP4XA 203.0.113.7 1
C→S  OK 1 ken
     (server echoes $31 "ken " to the client; next 100 ms tick promotes him)
S→C  EVENT JOIN ken 203.0.113.7

# client 2: $31 "M3WP" from 198.51.100.4 (no OTP)
S→C  NAME M3WP 198.51.100.4 2
C→S  OK 2 M3WP
     (server proceeds as today: uniqueness check, echo, promote)
S→C  EVENT JOIN M3WP 198.51.100.4

# client 3: $31 "ken" from 198.51.100.9 — name is reserved for a portal user
S→C  NAME ken 198.51.100.9 3
C→S  NO 3 reserved
     (server sends $50 "Invalid connect ident"; client stays in limbo)

# client 1 replays the same OTP from a second connection
S→C  VERIFY ken 7Q3M8K2ZP4XA 203.0.113.7 4
C→S  NO 4 used
     (server sends $50 "Invalid connect ident")

# lobby mirror on: ken says hello in room "main"
S→C  CHAT main ken hello there

# portal admin releases the device → sidecar asks for a kick
C→S  KICK ken release
S→C  EVENT PART ken 203.0.113.7

# client 2 hangs up ($00)
S→C  EVENT PART M3WP 198.51.100.4

# sidecar restarts: socket drops; server reconnects after 1 s and continues
```

## 8. Test hooks

`tools/mockquadro` implements the **server** side of this document (it dials a sidecar and
speaks it verbatim) and also exposes a `--fail-open` flag, so the sidecar and the portal can
be tested end-to-end before the real server change ships. The sidecar's `local_api` has a
replay fixture built from the transcript above.

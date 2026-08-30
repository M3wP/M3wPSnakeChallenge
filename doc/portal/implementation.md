# Snake QUADRO — portal support as built

**For Savrok.** What the game server now does, and the four places it differs from
`quadro.md` §9 / `sidecar-local.md`. Branch `portal`, commit `6af3f4e`.

The line protocol itself is implemented **exactly** as frozen — every verb, every reason
word, the 5 s deadline, the 1/2/5/10 s reconnect backoff, `PING`/`PONG`, the 512-byte line
limit, and "ignore anything you don't recognise". Nothing below asks you to change the
sidecar.

---

## 1. The switch is `--sidecar=`, not `-s`

`-s` was already taken — it has meant *silent* since long before this work
(`SnakeQuadroCLIServer.lpr`, option string `'hm:sdl:'`). So:

```
SnakeQuadroCLIServer --sidecar=127.0.0.1:19764            # fail_closed (default)
SnakeQuadroCLIServer --sidecar=127.0.0.1:19764 --fail-open
```

**The `=` is required.** FPC's long-option parser does not accept a space, and
`--sidecar 127.0.0.1:19764` fails with *"Option at position 1 needs an argument"*. Port may
be omitted and defaults to 19764.

Without `--sidecar` the server opens no socket, makes no query, and behaves exactly as it
did before — which is what a channel marked `legacy` on the portal will be running.

## 2. Chat sender names are still cut to 8 — deliberately, for now

§9.2 lists six sites to raise from 8 to 16. **Five are done. The two chat sender
re-truncations are not**, and this is the one thing worth reading carefully.

Those two are the only thing standing between a long name and memory corruption on every
MEGA65 client already in the field. The client copies a chat sender's name into a fixed
buffer with a loop bounded **only by the space character**:

```
room_haveblank  .res 1
room_lastuser   .res 11     <- a 16-char name writes 17 bytes
play_haveblank  .res 1
play_lastuser   .res 11
msgs_change_idx .res 1      <- framework control-message state
```

So a 16-character portal user saying anything in the in-game chat would have written over
`msgs_change_idx` on every listening 8-bit client.

**What this means for the portal, concretely:**

- A portal user's **identity** is a full 16 characters. `VERIFY`/`NAME` carry 16, the `$31`
  echo returns 16, `EVENT JOIN`/`PART` carry 16, uniqueness is checked on 16, and mcText
  list ids are derived from 16.
- Only the **sender name attached to a chat line** (`$24` lobby, `$64` play) is cut to 8 on
  the way out. A user called `verylongname1234` shows as `verylong` in 8-bit chat. Cosmetic,
  and only in chat.
- The join/part broadcasts are *not* affected — they carry the full name. The client only
  renders those through its length-managed text appender; it does not copy them into a fixed
  buffer.

The client fix ships in this same commit (both loops bounded, both buffers 17 bytes), so
raising those two sites is a one-line change once a client carrying it is actually deployed.
Until then the server-side cut is what makes the overrun unreachable.

## 3. `KICK` is implemented

§9.5 called it optional. It was cheap, so it is in. `KICK <name> <reason>` disconnects that
player as if the socket had dropped, which produces the usual `EVENT PART`. An unknown name
is silently ignored. You do not need the 90 s fallback for this server.

## 4. `$31` is answered asynchronously — expect the reply to land, not to block

The server parks the request and returns immediately; the answer is applied on its next
100 ms housekeeping pass. Consequences worth knowing at your end:

- **Nothing is sent to the client between the `$31` and your reply.** No ack, no error. A
  portal client should not read that silence as a failure until its own timeout.
- The player stays in limbo throughout, and limbo's own 60 s expiry keeps running
  underneath. A very slow answer therefore still loses the connection at 60 s even though
  the sidecar deadline is 5 s.
- Approval-to-promotion is at most one 100 ms tick, because the reply pump runs immediately
  before the promotion sweep. In practice `EVENT JOIN` follows your `OK` within ~100 ms.
- `req_id`s are a per-process counter starting at 1. They are echoed back to us and matched;
  a reply carrying an id we have already timed out is ignored, as §6 says.

## 5. Testing

`tools/mock_sidecar.py` in this repo implements **your** side of the protocol, so the server
change could be finished before your sidecar was available. It is a dev tool, not a
deliverable — but it is a second independent reading of the spec, which may be useful when
we cross-check:

```
python tools/mock_sidecar.py                     # canned OTPs, prints every line
python tools/mock_sidecar.py --reason expired    # force any NO reason
python tools/mock_sidecar.py --slow              # never answer, to exercise the deadline
python tools/mock_sidecar.py --kick ken:25       # KICK after 25s
python tools/mock_sidecar.py --no-pong           # stop answering PING
```

Drive the server with `tools/dev_ghost.py --port 19763 --name ken --otp 7Q3M8K2ZP4XA --room main`.

**Verified against it so far:** OTP accepted with the canonical name echoed; replay refused
`used`; a walk-in refused `reserved` on a portal-owned name; an ordinary walk-in accepted;
every refusal reaching the client as the existing `$50 "Invalid connect ident"` with the
reason word logged server-side only; the 5 s deadline firing; `KICK` disconnecting and
producing its `PART`; `fail-open` and `fail-closed` both behaving with the sidecar down; and
reconnect after the sidecar restarts.

Two stalled logins time out in the **same** main-loop pass rather than serially, which is
the evidence that the dispatcher is genuinely not blocked.

**Not yet verified:** anything against your real sidecar; `CHAT` mirroring (not implemented
— say if you want it); and the 16-char path against a real MEGA65 on hardware.

## 6. Still open at our end

- `--fail-open` currently applies to both shapes. With the sidecar down and `fail_open` set,
  a two-param `$31` is accepted with the **OTP ignored**, per `sidecar-local.md` §6. Worth
  confirming that is what you want rather than refusing the OTP form specifically.
- `CHAT <room> <name> <text…>` mirroring is not implemented. Note that this server
  re-broadcasts only the **first space-delimited word** of an in-game `$64` chat line
  (`quadro.md` §8.3), so a mirror of that particular stream would be lossy for reasons that
  predate the portal.

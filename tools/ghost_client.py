#!/usr/bin/env python
"""
ghost_client.py - throwaway test client for the M3wPChess server.

NOT part of the shipped project - this is a dev-only tool for exercising
the server's connect/auth/lobby/play protocol from a desktop machine when
you don't have a second MEGA65 (or working Xemu networking) handy to test
2-player flows against a real client. Speaks just enough of the wire
protocol to authenticate and join a game; everything else (chat, room
list, etc.) can be poked at via the "raw" command below.

Wire format (see ChessClasses.pas / M3wPChess's chess.s MSG_CATG_* defines):
    byte 0        = length of everything after this byte (1 + len(payload))
    byte 1        = (category << 4) | method
    byte 2..N     = payload - either space-joined ASCII params, or raw
                    binary bytes, depending on the message type

Usage:
    python ghost_client.py --name Ghost2 --game testgame
    (then type commands at the prompt - "help" lists them)
"""

import argparse
import socket
import sys
import threading
import time

# Python fully-buffers stdout when it isn't a terminal (e.g. redirected to a
# log file for a backgrounded dev_ghost.py run) - without this, nothing
# written via print()/describe() actually reaches that file until the
# process exits, making a live session impossible to observe while it's
# still running. line_buffering=True flushes on every newline instead.
try:
	sys.stdout.reconfigure(line_buffering=True)
except AttributeError:
	pass	# Python < 3.7 - not worth a fallback for a dev-only tool

CATEGORY_NAMES = {
    0x0: "System",
    0x1: "Text",
    0x2: "Lobby",
    0x3: "Connect",
    0x4: "Client",
    0x5: "Server",
    0x6: "Play",
}

CATG_SYST, CATG_TEXT, CATG_LOBY, CATG_CNCT, CATG_CLNT, CATG_SRVR, CATG_PLAY = (
    0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60,
)

PS_NONE, PS_IDLE, PS_READY = 0, 1, 2


def encode(catg_method, payload: bytes) -> bytes:
    return bytes([1 + len(payload), catg_method]) + payload


def params(*parts) -> bytes:
    return " ".join(str(p) for p in parts).encode("ascii")


class GhostClient:
    def __init__(self, host, port, name):
        self.host = host
        self.port = port
        self.name = name
        self.sock = None
        self.buf = bytearray()
        self.slot = None
        self.game = None
        self.room = None
        self.running = True
        self.my_turn = False
        self.echo_chat = False
        self.echo_room_chat = False

    def connect(self):
        self.sock = socket.create_connection((self.host, self.port))
        print(f"[connected to {self.host}:{self.port}]")
        threading.Thread(target=self._reader, daemon=True).start()

    def send(self, catg_method, payload: bytes = b""):
        frame = encode(catg_method, payload)
        self.sock.sendall(frame)
        print(f"  -> sent {describe(catg_method, payload)}")

    # ---- handshake helpers, mirroring clientSendIdent/clientSendUser ----
    def send_ident(self):
        self.send(CATG_CLNT | 0x1, params("ghost", "PC", "0.00.01A"))

    def send_username(self):
        self.send(CATG_CNCT | 0x1, self.name.encode("ascii"))

    def join(self, game, password=None):
        self.game = game
        payload = params(game) if not password else params(game, password)
        self.send(CATG_PLAY | 0x1, payload)

    def join_room(self, room, password=None):
        """Joins a lobby/chat room (mcLobby/0x1) - a TLobbyRoom, a
        different zone from the play/chess game TChessGame join() targets.
        Room membership triggers the server's own auto room-list send back
        to us (mcLobby/0x3, see TLobbyRoom.Add) - no separate request
        needed from this side, same as the real client since a recent fix."""
        self.room = room
        payload = params(room) if not password else params(room, password)
        self.send(CATG_LOBY | 0x1, payload)

    def send_room_chat(self, text):
        """Sends room/lobby chat (mcLobby/0x4) - see TLobbyRoom.
        ProcessPlayerMessage Method=4. Payload is "<room> <placeholder>
        <text...>" - the server overwrites the name field with our real
        authenticated name regardless of what's sent here, same as
        send_chat's mcPlay equivalent doesn't even need a name field at all."""
        self.send(CATG_LOBY | 0x4, params(self.room, self.name, text))

    def ready(self, is_ready=True):
        if self.slot is None:
            print("  (don't know my own slot yet - join a game and wait for "
                  "the join broadcast first)")
            return
        self.send(CATG_PLAY | 0x7, bytes([self.slot, PS_READY if is_ready else PS_IDLE]))

    def move(self, from_cell, to_cell):
        payload = from_cell.upper().encode("ascii") + to_cell.upper().encode("ascii")
        self.send(CATG_PLAY | 0xC, payload)

    def part(self):
        """Sends Part (mcPlay/0x2) for the game we joined - see
        TChessGame.Remove/TPlayZone.ProcessPlayerMessage Method=2. Used to
        simulate resigning: a mid-game Part forfeits (the other slot gets
        marked psWinner), same as a dropped connection would."""
        self.send(CATG_PLAY | 0x2, params(self.game))

    def send_chat(self, text):
        """Sends GameChat (mcPlay/0xE) - see TChessGame.SendGameChat. Just
        raw text, no name prefix - the server stamps the sender itself."""
        self.send(CATG_PLAY | 0xE, text.encode("ascii"))

    def wait_for_turn(self, timeout=30.0):
        """Blocks until a SlotStatus broadcast marks our own slot psPlaying
        (see ChessServer.pas TChessGame.SendSlotStatus - Data[1] is the raw
        TPlayerState byte, 5 = psPlaying), or timeout elapses."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.my_turn:
                return True
            time.sleep(0.1)
        return False

    def play_moves(self, move_pairs, wait_turn=True, turn_timeout=30.0):
        """Sends a sequence of (from_cell, to_cell) moves, one per our turn.
        Between moves it waits for a fresh psPlaying SlotStatus rather than
        just sleeping, since the opponent's reply time is unpredictable
        (e.g. a human talking through a demo)."""
        for i, (from_cell, to_cell) in enumerate(move_pairs):
            if wait_turn:
                print(f"[move {i + 1}/{len(move_pairs)}: waiting up to "
                        f"{turn_timeout}s for our turn]")
                if not self.wait_for_turn(turn_timeout):
                    print("(gave up waiting for our turn - sending anyway, "
                            "server will just ignore it if it's still not "
                            "our turn)")
            self.move(from_cell, to_cell)
            # It's about to become the opponent's turn again - don't let a
            # stale my_turn=True (from before this move) fool the next
            # iteration's wait_for_turn into returning immediately.
            self.my_turn = False
            time.sleep(0.3)

    # ---- background reader ----
    def _reader(self):
        while self.running:
            try:
                chunk = self.sock.recv(4096)
            except OSError:
                break
            if not chunk:
                print("[server closed the connection]")
                self.running = False
                break
            self.buf.extend(chunk)
            self._drain()

    def _drain(self):
        while len(self.buf) >= 1:
            total = self.buf[0] + 1  # length byte + everything it counts
            if len(self.buf) < total:
                return
            frame = bytes(self.buf[:total])
            del self.buf[:total]
            self._handle(frame)

    def _handle(self, frame: bytes):
        catg_method = frame[1]
        payload = frame[2:]
        print(f"  <- recv {describe(catg_method, payload)}")

        category = catg_method & 0xF0
        method = catg_method & 0x0F

        # Auto-reply to server keepalive challenges (mcServer/2), same as
        # clientSendKeepAlive on the real client - without this the server
        # will eventually time the connection out as unresponsive.
        if category == CATG_SRVR and method == 0x2:
            self.send(CATG_CLNT | 0x2)
            return

        # Auto-detect our own slot from a play-join broadcast (mcPlay/1,
        # params: game name, joiner name, slot digit) - see TChessGame.Add.
        if category == CATG_PLAY and method == 0x1:
            parts = payload.decode("ascii", errors="replace").split(" ")
            if len(parts) == 3 and parts[1] == self.name:
                self.slot = int(parts[2])
                print(f"  (that's us - we're slot {self.slot})")

        # Track whose turn it is from SlotStatus broadcasts (mcPlay/7, raw
        # bytes [slot, TPlayerState, TChessCheckState] - see
        # TChessGame.SendSlotStatus). State 5 = psPlaying.
        if category == CATG_PLAY and method == 0x7 and len(payload) == 3:
            if self.slot is not None and payload[0] == self.slot:
                was_turn = self.my_turn
                self.my_turn = (payload[1] == 5)
                if self.my_turn and not was_turn:
                    print("  (it's our turn now)")

        # Echo mode - for testing the in-game chat log without a second
        # human. GameChat (mcPlay/0xE) payload is "name text..." (see
        # TChessGame.SendGameChat) and gets broadcast to BOTH players,
        # including whoever sent it - the name check here is what stops
        # that from turning into echoing our own echo forever.
        if category == CATG_PLAY and method == 0xE and self.echo_chat:
            if b" " in payload:
                sender_b, msg_b = payload.split(b" ", 1)
            else:
                sender_b, msg_b = payload, b""
            sender = sender_b.decode("ascii", errors="replace")
            if sender != self.name:
                print("  (echoing chat back)")
                self.send_chat(msg_b.decode("ascii", errors="replace"))

        # Same idea as echo_chat above, but for room/lobby chat (mcLobby/
        # 0x4). Payload is "room sender text..." (see TLobbyRoom.
        # ProcessPlayerMessage Method=4) and is likewise broadcast back to
        # the sender too, hence the name check.
        if category == CATG_LOBY and method == 0x4 and self.echo_room_chat:
            parts = payload.split(b" ", 2)
            if len(parts) == 3:
                _room_b, sender_b, msg_b = parts
                sender = sender_b.decode("ascii", errors="replace")
                if sender != self.name:
                    print("  (echoing room chat back)")
                    self.send_room_chat(msg_b.decode("ascii", errors="replace"))

    def close(self):
        self.running = False
        try:
            self.sock.close()
        except OSError:
            pass


def describe(catg_method: int, payload: bytes) -> str:
    category = catg_method & 0xF0
    method = catg_method & 0x0F
    cat_name = CATEGORY_NAMES.get(category >> 4, "?")
    # Payloads like MoveMade can carry raw non-text bytes (e.g. $FF for a
    # captured piece's "off board" cell). decode(errors="replace") turns
    # those into U+FFFD, which crashes print() on a cp1252 Windows console
    # (and kills the reader thread when it does, since this runs there) -
    # so build the preview by hand and only ever emit plain ASCII.
    text = "".join(chr(b) if 32 <= b < 127 else "." for b in payload)
    hexed = payload.hex()
    return f"{cat_name}/{method:#04x}  text={text!r}  hex={hexed}"


HELP = """\
Commands:
  join <game> [password]   join/create a play room (mcPlay/1)
  ready                    mark ourselves ready (mcPlay/7) - needs a slot first
  notready                 mark ourselves not ready (mcPlay/7)
  raw <catg_hex> <method_hex> <text...>
                            send an arbitrary message, e.g. "raw 0x20 0x1 lobbyroom"
  quit                     disconnect and exit
  help                     this message

Note: if "join" right after connecting gets back a Server/0x00
"Unrecognised command", that's the server's periodic housekeeping tick
not having promoted us out of limbo yet (see TLimboZone.ExpirePlayers) -
just wait a moment and try again.
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=19762)
    ap.add_argument("--name", default="Ghost2")
    ap.add_argument("--game", default=None, help="auto-join this game/room on connect")
    args = ap.parse_args()

    c = GhostClient(args.host, args.port, args.name)
    c.connect()

    # Same order as the real client's response to the server's initial
    # mcServer/1 handshake (see chess.s clientProcServerMsg's @ident branch).
    c.send_ident()
    c.send_username()

    if args.game:
        # Promotion out of the "limbo" zone (where ident/username land) into
        # "lobby"/"play" (where join actually gets handled) happens on the
        # server's periodic housekeeping tick, not the instant it receives
        # our messages - see TLimboZone.ExpirePlayers in ChessServer.pas.
        # Auto-join fires fast enough to beat that tick, which the server
        # answers with Server/0x00 "Unrecognised command" (no zone we're in
        # yet handles mcPlay). A short wait here avoids the race; typing
        # "join" by hand at the prompt is usually slow enough not to need it.
        time.sleep(0.3)
        c.join(args.game)

    print(HELP)
    try:
        while c.running:
            line = input("> ").strip()
            if not line:
                continue
            cmd, *rest = line.split()
            cmd = cmd.lower()

            if cmd == "quit":
                break
            elif cmd == "help":
                print(HELP)
            elif cmd == "join":
                if not rest:
                    print("usage: join <game> [password]")
                    continue
                c.join(*rest[:2])
            elif cmd == "ready":
                c.ready(True)
            elif cmd == "notready":
                c.ready(False)
            elif cmd == "raw":
                if len(rest) < 2:
                    print("usage: raw <catg_hex> <method_hex> <text...>")
                    continue
                catg = int(rest[0], 16)
                method = int(rest[1], 16)
                text = " ".join(rest[2:])
                c.send(catg | method, text.encode("ascii"))
            else:
                print(f"unknown command {cmd!r} - type 'help'")
    except (EOFError, KeyboardInterrupt):
        pass
    finally:
        c.close()
        print("[disconnected]")


if __name__ == "__main__":
    sys.exit(main())

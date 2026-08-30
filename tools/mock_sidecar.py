#!/usr/bin/env python
"""mock_sidecar.py - stand in for the RetroGameGate sidecar.

NOT part of the shipped project - a dev tool, like ghost_client.py.

Speaks the server side of doc/portal/sidecar-local.md (wire version 1,
FROZEN) so the game server's --sidecar path can be built and exercised
before Savrok's real sidecar is available. It listens; the game server
dials it.

    python tools/mock_sidecar.py

Then, in another shell:

    ./SnakeQuadroCLIServer.exe --sidecar=127.0.0.1:19764 -d

Every line in each direction is printed, so this doubles as a wire log.

Switches worth knowing:

    --reason expired     answer every VERIFY/NAME with NO <reason>, to walk
                         through each refusal the spec lists
    --slow               never answer at all, to prove the server's 5 s
                         deadline fires and that it keeps serving other
                         players while it waits
    --reserve NAME       answer NAME for that name with NO reserved
    --kick NAME:SECS     send KICK NAME release that many seconds in
    --no-pong            stop answering PING, to exercise the server's
                         dead-socket detection
"""

import argparse
import socket
import sys
import threading
import time


#	sidecar-local.md S3. The OTP alphabet is Crockford base32
#	(0-9 A-H J-N P-T V-Z) and the sidecar folds case, so these compare
#	upper-cased.
DEFAULT_OTPS = {
    "7Q3M8K2ZP4XA": "ken",
    "ABCDEFGH1234": "m3wp",
    "0123456789AB": "savrok",
}

#	S3: every NO reason the game server has to cope with.
REASONS = ("unknown", "expired", "used", "banned", "ippin", "name",
           "reserved")

LINE_MAX = 512


class Sidecar:
    def __init__(self, args):
        self.args = args
        self.otps = dict(DEFAULT_OTPS)
        self.used = set()
        self.reserved = {n.lower() for n in (args.reserve or [])}
        self.lock = threading.Lock()

    # ---------------------------------------------------------- plumbing
    def serve(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((self.args.host, self.args.port))
        srv.listen(5)
        print("[listening on %s:%d]" % (self.args.host, self.args.port))

        while True:
            conn, peer = srv.accept()
            print("[game server connected from %s:%d]" % peer)
            threading.Thread(target=self._session, args=(conn,),
                             daemon=True).start()

    def _session(self, conn):
        buf = b""
        if self.args.kick:
            threading.Thread(target=self._kick_later, args=(conn,),
                             daemon=True).start()
        try:
            while True:
                data = conn.recv(4096)
                if not data:
                    break
                buf += data

                while b"\n" in buf:
                    raw, buf = buf.split(b"\n", 1)
                    line = raw.rstrip(b"\r").decode("ascii", "replace")
                    if not line:
                        continue
                    if len(raw) + 1 > LINE_MAX:
                        print("  !! line over %d bytes - closing" % LINE_MAX)
                        conn.close()
                        return
                    print("  <- %s" % line)
                    for out in self.handle(line):
                        print("  -> %s" % out)
                        conn.sendall((out + "\n").encode("ascii"))
        except OSError:
            pass
        finally:
            print("[game server disconnected]")
            try:
                conn.close()
            except OSError:
                pass

    def _kick_later(self, conn):
        name, _, secs = self.args.kick.partition(":")
        try:
            delay = float(secs) if secs else 10.0
        except ValueError:
            delay = 10.0
        time.sleep(delay)
        line = "KICK %s release" % name
        try:
            print("  -> %s" % line)
            conn.sendall((line + "\n").encode("ascii"))
        except OSError:
            pass

    # ----------------------------------------------------------- protocol
    def handle(self, line):
        parts = line.split(" ")
        verb = parts[0].upper()

        if verb == "PING":
            return [] if self.args.no_pong else ["PONG"]

        if verb == "PONG":
            return []

        if verb in ("EVENT", "CHAT"):
            #	Fire-and-forget (S3) - nothing to answer, and the point of
            #	printing them is that they are the portal's view of who is
            #	in the game.
            return []

        if verb == "VERIFY" and len(parts) >= 5:
            return self._verify(parts[1], parts[2], parts[3], parts[4])

        if verb == "NAME" and len(parts) >= 4:
            return self._name(parts[1], parts[2], parts[3])

        print("  ?? unrecognised, ignoring")
        return []

    def _held(self):
        """--slow: answer nothing at all, so the server's deadline runs."""
        return self.args.slow

    def _verify(self, name, otp, ip, reqid):
        if self._held():
            print("     (--slow: not answering)")
            return []

        if self.args.reason:
            return ["NO %s %s" % (reqid, self.args.reason)]

        key = otp.upper()

        with self.lock:
            if key not in self.otps:
                return ["NO %s unknown" % reqid]

            if key in self.used:
                return ["NO %s used" % reqid]

            canon = self.otps[key]

            #	S3: "the OTP is valid but was issued for a different name".
            if canon.lower() != name.lower():
                return ["NO %s name" % reqid]

            #	An OK CONSUMES the OTP - a replay from a second connection
            #	must come back "used".
            self.used.add(key)

        return ["OK %s %s" % (reqid, canon)]

    def _name(self, name, ip, reqid):
        if self._held():
            print("     (--slow: not answering)")
            return []

        if self.args.reason:
            return ["NO %s %s" % (reqid, self.args.reason)]

        #	The portal reserves the names of its users: they may only be
        #	used with an OTP, which is what stops a walk-in squatting one.
        if name.lower() in self.reserved:
            return ["NO %s reserved" % reqid]

        if name.lower() in {v.lower() for v in self.otps.values()}:
            return ["NO %s reserved" % reqid]

        return ["OK %s %s" % (reqid, name)]


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=19764)
    ap.add_argument("--reason", choices=REASONS,
                    help="refuse everything with this reason")
    ap.add_argument("--slow", action="store_true",
                    help="never answer, to exercise the 5s deadline")
    ap.add_argument("--reserve", action="append", metavar="NAME",
                    help="answer NAME for this name with NO reserved")
    ap.add_argument("--kick", metavar="NAME[:SECS]",
                    help="send KICK NAME release after SECS (default 10)")
    ap.add_argument("--no-pong", action="store_true",
                    help="do not answer PING")
    args = ap.parse_args()

    print("known OTPs:")
    for otp, who in sorted(DEFAULT_OTPS.items(), key=lambda kv: kv[1]):
        print("  %-14s -> %s" % (otp, who))
    print()

    try:
        Sidecar(args).serve()
    except KeyboardInterrupt:
        print("\n[stopped]")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python
"""
dev_ghost.py - scriptable, non-interactive ghost client for one-shot dev
test runs, paired with dev_server.sh. NOT part of the shipped project.

Wraps ghost_client.GhostClient (which is still there for interactive poking)
with a single command line that covers the common manual-test shape used
against a real MEGA65 client: connect, join a game, optionally ready up,
optionally send one raw mcPlay message (e.g. SelectCell), then hold the
connection open for a bit so any resulting broadcast traffic (SlotStatus/
GameStatus/BoardSync/AvailableMoves/...) prints via GhostClient's own
background reader. Replaces writing a fresh throwaway script per test.

Usage:
    python dev_ghost.py --game test --ready
    python dev_ghost.py --game test --ready --select F2
    python dev_ghost.py --game test --ready --move E7 E6 --wait-turn
    python dev_ghost.py --game test --ready --wait-turn \
            --move E7 E6 --move E6 E5 --move D7 D6   # a little sequence
    python dev_ghost.py --game test --ready --echo-chat --hold 300
    python dev_ghost.py --game test --name Ghost2 --hold 5
    python dev_ghost.py --game test --raw 0x60 0xa "F2"   # arbitrary mcPlay msg
    python dev_ghost.py --game test --ready --resign-on-turn   # simulate an opponent resigning
    python dev_ghost.py --room lobby1 --echo-room-chat --hold 300   # lobby/chat room instead of a play game
"""

import argparse
import sys
import time

from ghost_client import GhostClient


def main():
	ap = argparse.ArgumentParser(description=__doc__,
			formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("--host", default="127.0.0.1")
	ap.add_argument("--port", type=int, default=19762)
	ap.add_argument("--name", default="Ghost")
	ap.add_argument("--game", help="play/chess game name to join (TChessGame)")
	ap.add_argument("--room", help="lobby/chat room name to join (TLobbyRoom) "
			"instead of a play game - mutually exclusive with --game")
	ap.add_argument("--otp", default=None,
			help="send the two-param RetroGameGate username form, "
			"$31 '<name> <otp>' - needs a server started with --sidecar")
	ap.add_argument("--password", default=None)
	ap.add_argument("--echo-room-chat", action="store_true",
			help="with --room, echo back any room chat (mcLobby/0x4) text "
			"received from someone else, for testing the room chat/user-"
			"list panel without a second human - stays active for the "
			"whole --hold window")
	ap.add_argument("--ready", action="store_true",
			help="mark ready (mcPlay/7) once our slot is known")
	ap.add_argument("--select", metavar="CELL",
			help="send SelectCell (mcPlay/0xA) for this cell, e.g. F2")
	ap.add_argument("--move", nargs=2, metavar=("FROM", "TO"), action="append",
			help="send MakeMove (mcPlay/0xC), e.g. --move E7 E6 - repeat "
			"for a sequence of moves, one per our turn, e.g. --move E7 E6 "
			"--move E6 E5")
	ap.add_argument("--wait-turn", action="store_true",
			help="with --move, wait (up to --turn-timeout seconds) for a "
			"SlotStatus broadcast marking our slot psPlaying before "
			"sending each move, instead of sending immediately")
	ap.add_argument("--turn-timeout", type=float, default=300.0,
			help="seconds to wait for our turn with --wait-turn (default: 300)")
	ap.add_argument("--raw", nargs=3, metavar=("CATG_HEX", "METHOD_HEX", "TEXT"),
			help="send one arbitrary message after joining, e.g. "
			"--raw 0x60 0xa F2")
	ap.add_argument("--resign-on-turn", action="store_true",
			help="wait (up to --turn-timeout seconds) for our turn, then "
			"resign (mcPlay/0x2 Part) instead of moving - for testing the "
			"other player's WINNER feedback (see clientLogWinIfOurs)")
	ap.add_argument("--echo-chat", action="store_true",
			help="echo back any GameChat (mcPlay/0xE) text received from "
			"the other player, for testing the in-game move-log/chat "
			"panel without a second human - stays active for the whole "
			"--hold window")
	ap.add_argument("--hold", type=float, default=120.0,
			help="seconds to stay connected after setup, watching for "
			"broadcast traffic (default: 120)")
	args = ap.parse_args()

	if bool(args.game) == bool(args.room):
		ap.error("exactly one of --game or --room is required")

	c = GhostClient(args.host, args.port, args.name)
	c.echo_chat = args.echo_chat
	c.echo_room_chat = args.echo_room_chat
	c.connect()

	c.send_ident()
	c.send_username(args.otp)
	time.sleep(0.3)

	if args.room:
		c.join_room(args.room, args.password)

		print(f"[holding connection open for {args.hold}s]")
		time.sleep(args.hold)

		c.close()
		print("[disconnected]")
		return

	c.join(args.game, args.password)

	if args.ready or args.select or args.move or args.raw or args.resign_on_turn:
		# Need our own slot (from the join broadcast) before ready/select
		# mean anything - poll briefly rather than a fixed sleep.
		for _ in range(20):
			if c.slot is not None:
				break
			time.sleep(0.1)
		else:
			print("(never learned our own slot - join may have failed)")

	if args.ready:
		c.ready(True)
		time.sleep(0.3)

	if args.select:
		cell = args.select.upper().encode("ascii")
		c.send(0x60 | 0x0A, cell)
		time.sleep(0.3)

	if args.move:
		c.play_moves(args.move, wait_turn=args.wait_turn,
				turn_timeout=args.turn_timeout)

	if args.raw:
		catg, method, text = args.raw
		c.send(int(catg, 16) | int(method, 16), text.encode("ascii"))
		time.sleep(0.3)

	if args.resign_on_turn:
		print(f"[resign-on-turn: waiting up to {args.turn_timeout}s for our turn]")
		if not c.wait_for_turn(args.turn_timeout):
			print("(gave up waiting for our turn - resigning anyway)")
		c.part()
		time.sleep(0.3)

	print(f"[holding connection open for {args.hold}s]")
	time.sleep(args.hold)

	c.close()
	print("[disconnected]")


if __name__ == "__main__":
	sys.exit(main())

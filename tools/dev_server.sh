#!/usr/bin/env bash
# dev_server.sh - start/stop a local M3wPChessCLIServer instance for manual
# testing, paired with dev_ghost.py. NOT part of the shipped project.
#
# Usage (from anywhere - paths resolve relative to this script):
#   tools/dev_server.sh restart    kill any running instance, then start a
#                                   fresh one with -d (debug logging) in the
#                                   foreground - run this via a backgrounded
#                                   shell command so it keeps running
#   tools/dev_server.sh stop       just kill it
set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXE="$ROOT/M3wPChessCLIServer.exe"

stop() {
	taskkill //F //IM M3wPChessCLIServer.exe 2>/dev/null || true
}

case "${1:-}" in
	stop)
		stop
		;;
	restart)
		stop
		cd "$ROOT"
		exec "$EXE" -d
		;;
	*)
		echo "usage: $0 {restart|stop}" >&2
		exit 1
		;;
esac

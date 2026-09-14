#!/bin/sh
# Fake cloudflared for PMCTunnel tests (Linux/macOS). Mode comes from PMC_FAKE_CLOUDFLARED_MODE:
# ok | slow | no_url | error_exit | exit_after_ready. Replays real-looking logs from logs/ to stderr.
LOGS="$(dirname "$0")/logs"
if [ "$1" = "--version" ]; then
  echo "cloudflared version 2025.8.1 (built 2025-08-01-0000 UTC)"
  exit 0
fi
case "$4" in http://127.0.0.1:*) ;; *) echo "ERR unexpected arguments: $*" >&2; exit 2 ;; esac
if [ "$1" != "tunnel" ] || [ "$2" != "--no-autoupdate" ] || [ "$3" != "--url" ]; then
  echo "ERR unexpected arguments: $*" >&2
  exit 2
fi
MODE="${PMC_FAKE_CLOUDFLARED_MODE:-ok}"
idle() { i=0; while [ $i -lt 120 ]; do sleep 1; i=$((i + 1)); done; exit 0; }
case "$MODE" in
  error_exit) cat "$LOGS/error_429.log" >&2; exit 1 ;;
  no_url) cat "$LOGS/no_url.log" >&2; idle ;;
esac
[ "$MODE" = "slow" ] && sleep 3
cat "$LOGS/banner.log" >&2
[ "$MODE" = "slow" ] && sleep 1
cat "$LOGS/registered.log" >&2
if [ "$MODE" = "exit_after_ready" ]; then sleep 1; exit 0; fi
idle

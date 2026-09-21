#!/usr/bin/env bash
# notify-on-stop.sh — Stop hook for Claude Code
#
# Fires when Claude finishes responding and is waiting for you. Sends a desktop
# notification (macOS / Linux) with the first line of Claude's last message,
# rings the terminal bell, and appends a line to .claude/stop.log so you can
# see how long turns take.
#
# Never blocks (always exits 0). Safe to leave on permanently.
#
# Env overrides:
#   CC_NOTIFY_DISABLE=1   skip
#   CC_NOTIFY_WEBHOOK=url  also POST {"text": "..."} to this URL (Slack/Discord-compatible)

set -u
[ "${CC_NOTIFY_DISABLE:-0}" = "1" ] && exit 0

INPUT="$(cat)"
PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"
NAME="$(basename "$PROJECT")"
SUMMARY="Claude is waiting for you."

if command -v jq >/dev/null 2>&1; then
  TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')"
  # Do not re-notify if a Stop hook already ran for this turn (prevents loops).
  ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')"
  [ "$ACTIVE" = "true" ] && exit 0
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    # Last assistant text block, first line, trimmed to 120 chars.
    LAST="$(tail -n 200 "$TRANSCRIPT" \
      | jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' 2>/dev/null \
      | grep -v '^[[:space:]]*$' | tail -n 1 | head -c 120)"
    [ -n "$LAST" ] && SUMMARY="$LAST"
  fi
fi

TITLE="Claude Code — $NAME"

case "$(uname -s)" in
  Darwin)
    if command -v terminal-notifier >/dev/null 2>&1; then
      terminal-notifier -title "$TITLE" -message "$SUMMARY" -group "claude-$NAME" >/dev/null 2>&1
    else
      # Escape double quotes and backslashes for AppleScript.
      ESC="$(printf '%s' "$SUMMARY" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      osascript -e "display notification \"$ESC\" with title \"$TITLE\"" >/dev/null 2>&1
    fi
    ;;
  Linux)
    if command -v notify-send >/dev/null 2>&1; then
      notify-send "$TITLE" "$SUMMARY" >/dev/null 2>&1
    fi
    ;;
esac

# Terminal bell (works over SSH and in most terminals; tmux users: set monitor-bell).
printf '\a' > /dev/tty 2>/dev/null || true

# Optional webhook (Slack incoming webhook or Discord with ?wait=false works with {"text":...}).
if [ -n "${CC_NOTIFY_WEBHOOK:-}" ] && command -v curl >/dev/null 2>&1; then
  PAYLOAD="$(printf '%s' "$SUMMARY" | jq -Rs --arg t "$TITLE" '{text: ($t + ": " + .)}' 2>/dev/null || printf '{"text":"%s"}' "$TITLE")"
  curl -s -m 5 -X POST -H 'Content-Type: application/json' -d "$PAYLOAD" "$CC_NOTIFY_WEBHOOK" >/dev/null 2>&1 || true
fi

mkdir -p "$PROJECT/.claude" 2>/dev/null
printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SUMMARY" >> "$PROJECT/.claude/stop.log" 2>/dev/null || true

exit 0

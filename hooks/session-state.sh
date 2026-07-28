#!/bin/bash
# Records Claude Code session state for the ClaudeSessions menu bar app.
# Usage: session-state.sh <state>   (hook JSON arrives on stdin)
# States: start | working | attention | done | end
#
# Deliberately dependency-free: shell builtins plus /bin/date only. No jq,
# no python. The app does the JSON parsing, so this just captures the raw
# payload with a small header on top.

set -u
STATE="${1:-unknown}"
DIR="$HOME/.claude/session-state"
mkdir -p "$DIR" 2>/dev/null

input=$(cat)

# session_id is a UUID, so a plain regex is safe here and the captured value
# is guaranteed to be a harmless filename.
sid=""
if [[ "$input" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([0-9a-fA-F-]{8,64})\" ]]; then
  sid="${BASH_REMATCH[1]}"
fi
[ -n "$sid" ] || exit 0

f="$DIR/$sid.state"

if [ "$STATE" = "end" ]; then
  rm -f "$f"
  exit 0
fi

# Notification covers two unrelated things: a real permission prompt (you are
# blocked) and a 60s idle nudge (the session is just sitting at an empty
# prompt). Only the former deserves the red badge.
if [ "$STATE" = "attention" ]; then
  case "$input" in
    *"waiting for your input"*) STATE="idle" ;;
  esac
fi

# Header lines, then the untouched hook payload. Written to a temp file and
# renamed so the app never observes a half-written file.
{
  printf 'claude-session-state/1\n'
  printf '%s\n' "$STATE"
  printf '%s\n' "$PPID"
  printf '%s\n' "${TERM_PROGRAM:-}"
  printf '%s\n' "$(date +%s)"
  printf '%s' "$input"
} > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"

exit 0

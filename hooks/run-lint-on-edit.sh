#!/usr/bin/env bash
# run-lint-on-edit.sh — PostToolUse hook for Claude Code (Write|Edit|MultiEdit)
#
# After Claude edits a file: auto-format it with the project's formatter, then
# run the project's linter on that one file. If the linter reports problems,
# exit 2 so the errors are fed back to Claude and it fixes them immediately,
# instead of the problems surfacing in CI an hour later.
#
# Uses only tools that are already installed in the project (node_modules/.bin,
# the active Python venv, or on PATH). Silently does nothing for unknown file
# types. Never modifies files outside the project directory.
#
# Env overrides:
#   CC_LINT_DISABLE=1        skip entirely
#   CC_LINT_FORMAT_ONLY=1    format, but never block on lint errors
#   CC_LINT_MAX_LINES=5000   skip files larger than this (generated code)

set -u
[ "${CC_LINT_DISABLE:-0}" = "1" ] && exit 0
INPUT="$(cat)"
field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r ".$1 // empty"
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d=d.get(k) if isinstance(d,dict) else None
print(d if isinstance(d,str) else "", end="")' "$1"
  fi
}
FILE="$(field tool_input.file_path)"
PROJECT="${CLAUDE_PROJECT_DIR:-$(field cwd)}"

[ -n "$FILE" ] && [ -f "$FILE" ] || exit 0
case "$FILE" in
  "$PROJECT"/*) ;;                     # inside the project
  *) exit 0 ;;                          # outside: do nothing
esac
case "$FILE" in
  */node_modules/*|*/.venv/*|*/venv/*|*/dist/*|*/build/*|*/.next/*|*/generated/*|*/__generated__/*|*.min.js|*.lock|*-lock.*) exit 0 ;;
esac

MAX="${CC_LINT_MAX_LINES:-5000}"
LINES="$(wc -l < "$FILE" | tr -d ' ')"
[ "$LINES" -gt "$MAX" ] && exit 0

cd "$PROJECT" || exit 0
BIN="$PROJECT/node_modules/.bin"
have() { command -v "$1" >/dev/null 2>&1; }
nbin() { [ -x "$BIN/$1" ] && printf '%s' "$BIN/$1" || { have "$1" && printf '%s' "$1"; }; }

ERRORS=""
EXT="${FILE##*.}"

case "$EXT" in
  ts|tsx|js|jsx|mjs|cjs|json|css|scss|md|mdx|yml|yaml|html|vue|svelte)
    if B="$(nbin biome)" && [ -n "$B" ] && [ -f biome.json ] ; then
      "$B" format --write "$FILE" >/dev/null 2>&1
      case "$EXT" in ts|tsx|js|jsx|mjs|cjs) ERRORS="$("$B" lint "$FILE" 2>&1 | tail -n 40)";; esac
      "$B" lint "$FILE" >/dev/null 2>&1 || true
    else
      if P="$(nbin prettier)" && [ -n "$P" ]; then
        "$P" --write --log-level silent "$FILE" >/dev/null 2>&1 || true
      fi
      case "$EXT" in
        ts|tsx|js|jsx|mjs|cjs|vue|svelte)
          if E="$(nbin eslint)" && [ -n "$E" ]; then
            "$E" --fix --no-warn-ignored "$FILE" >/dev/null 2>&1 || true
            OUT="$("$E" --no-warn-ignored -f unix "$FILE" 2>&1)"; RC=$?
            [ $RC -ne 0 ] && ERRORS="$OUT"
          fi
          ;;
      esac
    fi
    ;;
  py|pyi)
    RUFF="$(nbin ruff)"; [ -z "$RUFF" ] && [ -x ".venv/bin/ruff" ] && RUFF=".venv/bin/ruff"
    if [ -n "$RUFF" ]; then
      "$RUFF" format --quiet "$FILE" >/dev/null 2>&1 || true
      "$RUFF" check --fix --quiet "$FILE" >/dev/null 2>&1 || true
      OUT="$("$RUFF" check --output-format concise "$FILE" 2>&1)"; RC=$?
      [ $RC -ne 0 ] && ERRORS="$OUT"
    elif have black; then
      black -q "$FILE" >/dev/null 2>&1 || true
    fi
    ;;
  go)
    have gofmt && gofmt -w "$FILE" >/dev/null 2>&1
    have goimports && goimports -w "$FILE" >/dev/null 2>&1
    if have go; then
      OUT="$(go vet "$(dirname "$FILE")" 2>&1)"; RC=$?
      [ $RC -ne 0 ] && ERRORS="$OUT"
    fi
    ;;
  rs)
    have rustfmt && rustfmt --edition 2021 "$FILE" >/dev/null 2>&1
    ;;
  sh|bash)
    if have shellcheck; then
      OUT="$(shellcheck -f gcc "$FILE" 2>&1)"; RC=$?
      [ $RC -ne 0 ] && ERRORS="$OUT"
    fi
    ;;
  rb)
    if have rubocop; then
      rubocop -a --format quiet "$FILE" >/dev/null 2>&1 || true
      OUT="$(rubocop --format emacs "$FILE" 2>&1)"; RC=$?
      [ $RC -ne 0 ] && ERRORS="$OUT"
    fi
    ;;
  tf)
    have terraform && terraform fmt "$FILE" >/dev/null 2>&1
    ;;
  sql)
    if have sqlfluff && [ -f .sqlfluff ]; then
      OUT="$(sqlfluff lint --format github-annotation-native "$FILE" 2>&1)"; RC=$?
      [ $RC -ne 0 ] && ERRORS="$OUT"
    fi
    ;;
  *) exit 0 ;;
esac

if [ -n "$ERRORS" ] && [ "${CC_LINT_FORMAT_ONLY:-0}" != "1" ]; then
  {
    echo "Lint errors in $FILE (auto-fix already applied where possible). Fix these before continuing:"
    printf '%s\n' "$ERRORS" | head -n 40
  } >&2
  exit 2
fi
exit 0

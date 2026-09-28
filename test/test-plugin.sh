#!/usr/bin/env bash
# test-plugin.sh - proves the plugin packaging actually works, not just that the JSON parses.
#
#   ./test/test-plugin.sh          run the assertions
#   ./test/test-plugin.sh --prove  break the packaging 5 ways and show each break is caught
#
# run-tests.sh proves the hook blocks the right commands. This file proves that a user who
# runs `/plugin install claude-code-guardrails@honoka-software` gets that same hook wired up:
# the manifests validate, the two names match, the marketplace source exists, the matchers
# cover the tools, and the command string in hooks/hooks.json really executes the hook when
# ${CLAUDE_PLUGIN_ROOT} is substituted and the working directory is the user's project, not
# ours. That last point is why every command below runs from a temp directory: a relative
# path in hooks.json passes a test run from the repo root and breaks for every real user.
#
# Exit 0 = every assertion held.

set -u
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PLUGIN_MANIFEST=.claude-plugin/plugin.json
MARKET_MANIFEST=.claude-plugin/marketplace.json
HOOKS=hooks/hooks.json
PASS=0; FAIL=0; FAILED=()

# ---------------------------------------------------------------------------- --prove
# A test suite that passes tells you nothing until you have seen it fail. --prove breaks
# the packaging five ways and requires each break to be caught. It also checks that each
# mutation actually changed the file's *meaning*: a patch that silently matches nothing
# produces the same "not caught" output as a toothless assertion, and the two have
# opposite fixes. Comparing raw bytes is not enough here, because rewriting a JSON file
# through json.dump reformats it and so changes the bytes even when nothing was edited.
# _canon compares the parsed value with sorted keys instead.
_canon() { python3 -c '
import hashlib,json,sys
b=open(sys.argv[1],"rb").read()
try: b=json.dumps(json.loads(b),sort_keys=True).encode()
except Exception: pass
print(hashlib.sha256(b).hexdigest())' "$1"; }
if [ "${1:-}" = --prove ]; then
  CAUGHT=0; MISSED=()
  sabotage() { # sabotage <label> <python-mutation>
    local label="$1" mutation="$2" before after
    before="$(_canon "$3")"
    cp "$3" "$3.orig"
    python3 -c "$mutation" "$3"
    after="$(_canon "$3")"
    if [ "$before" = "$after" ]; then
      MISSED+=("NO-OP: [$label] left the file meaning the same thing, so it tested nothing")
    elif "$0" >/dev/null 2>&1; then
      MISSED+=("NOT CAUGHT: [$label] and the suite still passed")
    else
      CAUGHT=$((CAUGHT+1)); echo "  caught: $label"
    fi
    mv "$3.orig" "$3"
    if [ "$before" != "$(_canon "$3")" ]; then
      MISSED+=("NOT RESTORED: [$label] left $3 modified")
    fi
  }
  echo "== breaking the packaging on purpose =="
  sabotage "plugin renamed so the install id stops resolving" \
    'import json,sys;p=sys.argv[1];d=json.load(open(p));d["name"]="renamed-plugin";json.dump(d,open(p,"w"),indent=2)' \
    "$PLUGIN_MANIFEST"
  sabotage "marketplace source points at a directory that is not there" \
    'import json,sys;p=sys.argv[1];d=json.load(open(p));d["plugins"][0]["source"]="./plugins/guardrails";json.dump(d,open(p,"w"),indent=2)' \
    "$MARKET_MANIFEST"
  sabotage "hook path made relative, which works here and breaks for every user" \
    'import json,sys;p=sys.argv[1];d=json.load(open(p));[e["hooks"][0].__setitem__("command","./hooks/block-dangerous-commands.sh") for e in d["hooks"]["PreToolUse"]];json.dump(d,open(p,"w"),indent=2)' \
    "$HOOKS"
  sabotage "hook path points at a script that does not exist" \
    'import json,sys;p=sys.argv[1];d=json.load(open(p));[e["hooks"][0].__setitem__("command","\"${CLAUDE_PLUGIN_ROOT}\"/hooks/gone.sh") for e in d["hooks"]["PreToolUse"]];json.dump(d,open(p,"w"),indent=2)' \
    "$HOOKS"
  sabotage "Write/Edit/MultiEdit matcher dropped, leaving file writes ungated" \
    'import json,sys;p=sys.argv[1];d=json.load(open(p));d["hooks"]["PreToolUse"]=[e for e in d["hooks"]["PreToolUse"] if e["matcher"]=="Bash"];json.dump(d,open(p,"w"),indent=2)' \
    "$HOOKS"
  echo "------------------------------------------------------------"
  if [ "${#MISSED[@]}" -eq 0 ]; then
    echo "PASS  $CAUGHT/5 sabotages caught."
    exit 0
  fi
  printf '%s\n' "${MISSED[@]}"
  echo "FAIL  only $CAUGHT of 5 sabotages were caught."
  exit 1
fi

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); }
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2] got [$3]"; fi
}

jget() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));exec("v=d"+sys.argv[2]);print(v)' "$1" "$2" 2>/dev/null; }

# ---------------------------------------------------------------- manifests validate
for m in "$PLUGIN_MANIFEST" "$MARKET_MANIFEST"; do
  if claude plugin validate --strict "./$m" >/dev/null 2>&1; then ok
  else bad "claude plugin validate --strict ./$m did not pass"; fi
done

# ------------------------------------------------- the two names must be the same string
# Documented as the most common cause of a failed install: the user types the manifest
# name, the marketplace only knows the entry name.
PNAME="$(jget "$PLUGIN_MANIFEST" '["name"]')"
ENAME="$(jget "$MARKET_MANIFEST" '["plugins"][0]["name"]')"
check "entry name == manifest name" "$PNAME" "$ENAME"

# ------------------------------------------------------- the marketplace source resolves
# validate passes on a source that does not exist; install is where it fails.
SRC="$(jget "$MARKET_MANIFEST" '["plugins"][0]["source"]')"
if [ -f "$ROOT/$SRC/.claude-plugin/plugin.json" ]; then ok
else bad "marketplace source [$SRC] does not contain .claude-plugin/plugin.json"; fi

# --------------------------------------------------------------- the matchers cover both
MATCHERS="$(python3 -c '
import json,sys
h=json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
print("|".join(sorted(e.get("matcher","") for e in h)))' "$HOOKS" 2>/dev/null)"
check "PreToolUse matchers" "Bash|Write|Edit|MultiEdit" "$MATCHERS"

# ---------------------------------------------------- the command string actually blocks
# Substitute ${CLAUDE_PLUGIN_ROOT} the way Claude Code does, then run the command from a
# directory that is not this repo, with the JSON a real PreToolUse call would send.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

fire() { # fire <matcher-index> <json-payload> -> exit code of the hook
  local idx="$1" payload="$2" cmd
  cmd="$(python3 -c '
import json,sys
h=json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
print(h[int(sys.argv[2])]["hooks"][0]["command"])' "$ROOT/$HOOKS" "$idx")"
  ( cd "$WORKDIR" && CLAUDE_PLUGIN_ROOT="$ROOT" printf '%s' "$payload" | \
    CLAUDE_PLUGIN_ROOT="$ROOT" bash -c "$cmd" >/dev/null 2>&1 )
  echo $?
}

payload() { python3 -c '
import json,sys
print(json.dumps({"tool_name":sys.argv[1],"tool_input":json.loads(sys.argv[2])}))' "$1" "$2"; }

check "Bash matcher blocks rm -rf ~"        2 "$(fire 0 "$(payload Bash  '{"command":"rm -rf ~"}')")"
check "Bash matcher blocks cat .env"        2 "$(fire 0 "$(payload Bash  '{"command":"cat .env"}')")"
check "Bash matcher allows npm test"        0 "$(fire 0 "$(payload Bash  '{"command":"npm test"}')")"
check "Write matcher blocks writing .env"   2 "$(fire 1 "$(payload Write '{"file_path":"config/.env","content":"A=1"}')")"
check "Write matcher allows a source file"  0 "$(fire 1 "$(payload Write '{"file_path":"src/app.ts","content":"export const a = 1"}')")"

# ------------------------------------------------------------------------------ report
echo "------------------------------------------------------------"
if [ "$FAIL" -eq 0 ]; then
  echo "PASS  $PASS/$PASS packaging assertions held."
  exit 0
fi
printf '%s\n' "${FAILED[@]}"
echo "FAIL  $FAIL of $((PASS+FAIL)) packaging assertions did not hold."
exit 1

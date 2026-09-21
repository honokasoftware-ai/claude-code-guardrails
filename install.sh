#!/usr/bin/env bash
# install.sh — copy the hooks into a project's .claude/hooks/ and print the
# settings.json block to merge. Does not modify settings.json for you: you
# should read what you are about to enable.
set -euo pipefail
TARGET="${1:-.}"
SRC="$(cd "$(dirname "$0")" && pwd)"
[ -d "$TARGET" ] || { echo "no such directory: $TARGET" >&2; exit 1; }
mkdir -p "$TARGET/.claude/hooks"
cp "$SRC"/hooks/*.sh "$TARGET/.claude/hooks/"
chmod +x "$TARGET/.claude/hooks/"*.sh
echo "Installed to $TARGET/.claude/hooks/:"
ls -1 "$TARGET/.claude/hooks/"
cat <<'MSG'

Next: merge hooks/settings.json into TARGET/.claude/settings.json.
If that file does not exist yet, you can just copy it:

    cp hooks/settings.json TARGET/.claude/settings.json

Then verify the hooks actually fire:

    ./test/run-tests.sh
MSG

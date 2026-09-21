#!/usr/bin/env bash
# block-dangerous-commands.sh — PreToolUse hook for Claude Code
#
# Reads the tool call as JSON on stdin. Exits 2 (block, message fed back to
# Claude) when the call matches a dangerous pattern. Exits 0 otherwise.
#
# Registered for: Bash, Write, Edit, MultiEdit (see settings.json).
#
# Test:
#   echo '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}' \
#     | ./block-dangerous-commands.sh; echo "exit=$?"     # expect exit=2
#
# Add your own patterns in the PATTERNS section. Keep them specific; a hook
# that blocks too much gets disabled, and then it protects nothing.

set -u

INPUT="$(cat)"

# field <dotted.path> — extract a string field from $INPUT. Uses jq if present,
# python3 otherwise. Fails closed (exit 2) if neither is available.
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
  else
    echo "block-dangerous-commands: needs jq or python3 to parse hook input. Blocking until one is installed." >&2
    exit 2
  fi
}

TOOL="$(field tool_name)"

block() {
  # $1 = reason. Printed to stderr; Claude sees it and must choose another approach.
  echo "BLOCKED by .claude/hooks/block-dangerous-commands.sh: $1" >&2
  echo "If this is genuinely intended, a human must run it manually outside Claude Code." >&2
  exit 2
}

# ---------------------------------------------------------------------------
# File-writing tools: refuse to create or edit secret-bearing files.
# ---------------------------------------------------------------------------
if [ "$TOOL" = "Write" ] || [ "$TOOL" = "Edit" ] || [ "$TOOL" = "MultiEdit" ]; then
  FILE="$(field tool_input.file_path)"
  BASENAME="$(basename "$FILE")"
  case "$BASENAME" in
    .env.example|.env.sample|.env.template|.env.*.example|.env.*.sample|.env.*.template) ;;   # documentation files: fine
    .env|.env.*|*.pem|*.key|id_rsa|id_ed25519|id_ecdsa|credentials|.netrc|.npmrc|.pypirc)
      block "editing secret-bearing file '$FILE'. Edit it by hand; document required variables in .env.example instead." ;;
  esac
  case "$FILE" in
    */.ssh/*|*/.aws/*|*/.gnupg/*|*/.config/gh/*|*/.docker/config.json)
      block "editing credential store '$FILE'." ;;
  esac
  # Content check: obvious secret material being written into any file.
  CONTENT="$(field tool_input.content)"
  [ -n "$CONTENT" ] || CONTENT="$(field tool_input.new_string)"
  if printf '%s' "$CONTENT" | grep -Eq -- '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'; then
    block "content contains a private key block."
  fi
  if printf '%s' "$CONTENT" | grep -Eq '(AKIA[0-9A-Z]{16}|sk_live_[0-9a-zA-Z]{20,}|sk-ant-[0-9a-zA-Z_-]{20,}|ghp_[0-9a-zA-Z]{36}|xox[baprs]-[0-9a-zA-Z-]{10,})'; then
    block "content looks like a live API key/token. Use an environment variable and a secret manager."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Bash tool
# ---------------------------------------------------------------------------
[ "$TOOL" = "Bash" ] || exit 0

CMD="$(field tool_input.command)"
[ -n "$CMD" ] || exit 0

# Normalize: collapse whitespace, keep original for messages.
NORM="$(printf '%s' "$CMD" | tr '\n' ' ' | tr -s ' ')"

# --- PATTERNS: filesystem destruction --------------------------------------
# rm -rf on root, home, cwd-root-ish targets, or with --no-preserve-root
if printf '%s' "$NORM" | grep -Eq '(^|[;&| ])rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*[rR][a-zA-Z]*|--recursive[[:space:]]+--force|--force[[:space:]]+--recursive)[[:space:]]+(--no-preserve-root[[:space:]]+)?("?/"?|"?~"?|"?\$HOME"?|"?/\*"?|"?~/\*"?|"?\.\."?|"?\*"?)([[:space:]]|$)'; then
  block "recursive force delete of a root/home/parent/glob path: $CMD"
fi
if printf '%s' "$NORM" | grep -Eq -- '--no-preserve-root'; then
  block "--no-preserve-root: $CMD"
fi
if printf '%s' "$NORM" | grep -Eq '(^|[;&| ])(mkfs(\.[a-z0-9]+)?|fdisk|parted|diskutil[[:space:]]+(erase|partition))[[:space:]]'; then
  block "disk formatting/partitioning: $CMD"
fi
if printf '%s' "$NORM" | grep -Eq '(^|[;&| ])dd[[:space:]].*of=/dev/'; then
  block "dd writing to a block device: $CMD"
fi
if printf '%s' "$NORM" | grep -Eq '(^|[;&| ])chmod[[:space:]]+(-R[[:space:]]+)?[0-7]*777[[:space:]]+("?/"?|"?~"?)([[:space:]]|$)'; then
  block "chmod 777 on root/home: $CMD"
fi
if printf '%s' "$NORM" | grep -Eq ':\(\)[[:space:]]*\{[[:space:]]*:[[:space:]]*\|[[:space:]]*:'; then
  block "fork bomb."
fi

# --- PATTERNS: git history / protected branches ----------------------------
# Force push (any spelling) to main/master/release/* or with no explicit refspec.
if printf '%s' "$NORM" | grep -Eq '(^|[;&| ])git[[:space:]]+push([[:space:]]+[^;&|]*)?[[:space:]](-f|--force|--force-with-lease(=[^ ]*)?|--force-if-includes)([[:space:]]|$)'; then
  if printf '%s' "$NORM" | grep -Eq '(^|[[:space:]])(main|master|release/[^ ]*|production|prod)([[:space:]]|$)'; then
    block "force push to a protected branch: $CMD"
  fi
  if ! printf '%s' "$NORM" | grep -Eq 'git[[:space:]]+push[[:space:]]+[^ ]*[[:space:]]+[^-][^ ]*(:[^ ]+)?'; then
    block "force push without an explicit remote and branch (could target the current branch if it is main): $CMD"
  fi
fi
# '+branch' refspec is also a force push
if printf '%s' "$NORM" | grep -Eq 'git[[:space:]]+push[[:space:]]+[^ ]+[[:space:]]+\+(main|master|release/|production|prod)'; then
  block "force push via +refspec to a protected branch: $CMD"
fi
if printf '%s' "$NORM" | grep -Eq 'git[[:space:]]+push[[:space:]]+[^ ]+[[:space:]]+(--delete|:)(main|master|release/)'; then
  block "deleting a protected remote branch: $CMD"
fi
if printf '%s' "$NORM" | grep -Eq 'git[[:space:]]+branch[[:space:]]+-D[[:space:]]+(main|master|release/)'; then
  block "deleting a protected local branch: $CMD"
fi
if printf '%s' "$NORM" | grep -Eq 'git[[:space:]]+(commit|push|merge)([[:space:]]+[^;&|]*)?[[:space:]]--no-verify([[:space:]]|$)'; then
  block "--no-verify skips pre-commit/pre-push checks: $CMD"
fi
if printf '%s' "$NORM" | grep -Eq 'git[[:space:]]+(reset[[:space:]]+--hard|checkout[[:space:]]+--[[:space:]]+\.|restore[[:space:]]+\.|clean[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*d?x)([[:space:]]|$)'; then
  block "discards uncommitted work for the whole tree: $CMD. Stash first or target specific files."
fi
if printf '%s' "$NORM" | grep -Eq 'git[[:space:]]+filter-(branch|repo)'; then
  block "history rewrite: $CMD"
fi

# --- PATTERNS: database destruction ----------------------------------------
UPPER="$(printf '%s' "$NORM" | tr '[:lower:]' '[:upper:]')"
if printf '%s' "$UPPER" | grep -Eq '(^|[^A-Z_])DROP[[:space:]]+(DATABASE|SCHEMA|TABLE)([[:space:]]|$)'; then
  block "DROP DATABASE/SCHEMA/TABLE: $CMD"
fi
if printf '%s' "$UPPER" | grep -Eq '(^|[^A-Z_])TRUNCATE([[:space:]]+TABLE)?[[:space:]]'; then
  block "TRUNCATE: $CMD"
fi
# DELETE FROM <table> with no WHERE clause
if printf '%s' "$UPPER" | grep -Eq '(^|[^A-Z_])DELETE[[:space:]]+FROM[[:space:]]+[A-Z0-9_."]+[[:space:]]*(;|$|"|'"'"')' ; then
  block "DELETE without WHERE: $CMD"
fi
if printf '%s' "$NORM" | grep -Eq '(^|[;&| ])(dropdb|mysqladmin[[:space:]]+drop|redis-cli[[:space:]]+flush(all|db))([[:space:]]|$)'; then
  block "database drop/flush: $CMD"
fi
if printf '%s' "$NORM" | grep -Eq '(prisma[[:space:]]+(migrate[[:space:]]+reset|db[[:space:]]+push[[:space:]]+.*--force-reset)|alembic[[:space:]]+downgrade[[:space:]]+base|rails[[:space:]]+db:(drop|reset|schema:load)|(bin/)?rake[[:space:]]+db:(drop|reset)|drizzle-kit[[:space:]]+drop|knex[[:space:]]+migrate:rollback[[:space:]]+--all|manage\.py[[:space:]]+(flush|reset_db)|dbt[[:space:]]+(run|build)[[:space:]]+.*--full-refresh.*--target[[:space:]]+prod)'; then
  block "ORM/migration tool command that destroys data: $CMD"
fi
if printf '%s' "$NORM" | grep -Eq '(^|[;&| ])(kubectl[[:space:]]+delete[[:space:]]+(ns|namespace)|terraform[[:space:]]+destroy|pulumi[[:space:]]+destroy|aws[[:space:]]+(s3[[:space:]]+rb|rds[[:space:]]+delete-db-instance|ec2[[:space:]]+terminate-instances)|gcloud[[:space:]]+.*delete|fly[[:space:]]+apps[[:space:]]+destroy|vercel[[:space:]]+(remove|rm)[[:space:]]+.*--yes|heroku[[:space:]]+(apps:destroy|pg:reset))'; then
  block "infrastructure destruction: $CMD"
fi

# --- PATTERNS: secret exposure ---------------------------------------------
# .env.example / .env.sample / .env.template are documentation, not secrets.
SAFE_NORM="$(printf '%s' "$NORM" | sed -E 's/\.env(\.[A-Za-z0-9_-]+)?\.(example|sample|template)/ENV_DOC_FILE/g')"
if printf '%s' "$SAFE_NORM" | grep -Eq '(^|[;&| ])(cat|less|more|head|tail|bat|nl|strings|xxd|open|code|vim|nano)[[:space:]]+[^;&|]*(\.env([./][^ ]*)?|\.netrc|\.npmrc|\.pypirc|id_rsa|id_ed25519|id_ecdsa|\.pem|\.key|/\.aws/credentials|/\.ssh/|/\.gnupg/|/\.config/gh/hosts\.yml|/\.docker/config\.json|/\.kube/config)([[:space:]]|$)'; then
  block "reading a secret-bearing file: $CMD. Reference variables by name; do not print their values."
fi
if printf '%s' "$NORM" | grep -Eq '(^|[;&| ])(printenv|env|set|export[[:space:]]+-p|declare[[:space:]]+-x)[[:space:]]*($|[;&|]|[[:space:]]*\|)'; then
  block "dumping the full environment: $CMD. Use 'printenv VAR_NAME' for one variable (non-secret) or check with 'test -n \"\$VAR\"'."
fi
if printf '%s' "$NORM" | grep -Eq 'echo[[:space:]]+[^;&|]*\$\{?[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|API_KEY|APIKEY|PRIVATE|CREDENTIAL|DATABASE_URL|DB_URL)[A-Z0-9_]*\}?'; then
  block "echoing a secret-looking variable: $CMD. Use 'test -n' to check presence."
fi
if printf '%s' "$NORM" | grep -Eq '(^|[;&| ])(gh[[:space:]]+auth[[:space:]]+token|vault[[:space:]]+(read|kv[[:space:]]+get)|aws[[:space:]]+(secretsmanager[[:space:]]+get-secret-value|ssm[[:space:]]+get-parameter.*--with-decryption)|gcloud[[:space:]]+secrets[[:space:]]+versions[[:space:]]+access|kubectl[[:space:]]+get[[:space:]]+secret[s]?[[:space:]]+[^;&|]*-o[[:space:]]*(yaml|json)|security[[:space:]]+find-(generic|internet)-password|op[[:space:]]+(read|item[[:space:]]+get)|doppler[[:space:]]+secrets[[:space:]]+download|docker[[:space:]]+(inspect|history)[[:space:]]+[^;&|]*--format[[:space:]]*.*Env)'; then
  block "fetching secret values from a secret store to stdout: $CMD"
fi
if printf '%s' "$NORM" | grep -Eq '(curl|wget)[[:space:]]+[^;&|]*(-d|--data|-F|--form|-T|--upload-file)[[:space:]]*[^;&|]*(\.env|id_rsa|\.pem|credentials)'; then
  block "uploading a secret file over the network: $CMD"
fi

# --- PATTERNS: remote code execution / privilege ---------------------------
if printf '%s' "$NORM" | grep -Eq '(curl|wget)[[:space:]][^|;&]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da|k)?sh([[:space:]]|$)'; then
  block "piping a downloaded script into a shell: $CMD. Download to a file, inspect, then run."
fi
if printf '%s' "$NORM" | grep -Eq '(^|[;&| ])sudo[[:space:]]'; then
  block "sudo: $CMD. Privileged commands are run by a human."
fi
if printf '%s' "$NORM" | grep -Eq '(^|[;&| ])(shutdown|reboot|halt|poweroff|init[[:space:]]+[06]|killall[[:space:]]+-9|pkill[[:space:]]+-9[[:space:]]+-f[[:space:]]+\.)([[:space:]]|$)'; then
  block "system power/kill-all command: $CMD"
fi
if printf '%s' "$NORM" | grep -Eq '(^|[;&| ])(crontab[[:space:]]+-r|launchctl[[:space:]]+(unload|bootout)|systemctl[[:space:]]+(disable|mask|stop))([[:space:]]|$)'; then
  block "disabling scheduled/system services: $CMD"
fi

# --- PATTERNS: publishing / irreversible external actions -------------------
if printf '%s' "$NORM" | grep -Eq '(^|[;&| ])(npm|pnpm|yarn)[[:space:]]+publish|(^|[;&| ])(twine[[:space:]]+upload|uv[[:space:]]+publish|cargo[[:space:]]+publish|gem[[:space:]]+push|docker[[:space:]]+push|gh[[:space:]]+release[[:space:]]+create|git[[:space:]]+push[[:space:]]+[^;&|]*--tags)'; then
  block "publishing/releasing: $CMD. Prepare the release; a human runs the publish step."
fi

exit 0

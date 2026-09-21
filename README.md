# claude-code-guardrails

Shell hooks that stop [Claude Code](https://claude.com/claude-code) from running the
commands you would not have approved: `rm -rf ~`, `git push --force origin main`,
`DROP DATABASE`, `cat .env`, `curl … | sh`, `npm publish`.

MIT licensed. No dependencies beyond bash and `jq` **or** `python3`. No network calls.

```bash
git clone https://github.com/honokasoftware-ai/claude-code-guardrails
cd claude-code-guardrails
./test/run-tests.sh          # 70 assertions, ~2 seconds
./install.sh /path/to/your/project
```

## Why a hook and not a prompt

`CLAUDE.md` is a request. A `PreToolUse` hook is a gate: it receives the tool call as
JSON on stdin and exits `2` to block it, and the model is told why and has to choose
another approach. Instructions get forgotten across a long session and compaction.
An exit code does not.

## What it blocks

`hooks/block-dangerous-commands.sh` registers for `Bash`, `Write`, `Edit` and
`MultiEdit`, and blocks:

| Category | Examples |
|---|---|
| Filesystem destruction | `rm -rf /`, `rm -rf ~`, `--no-preserve-root`, `mkfs`, `dd of=/dev/…`, `chmod 777 /`, fork bombs |
| Git history & protected branches | force push to `main`/`master`/`release/*`, `+main` refspec, deleting protected branches, `--no-verify`, `git reset --hard`, `git clean -fdx`, `filter-branch` |
| Database destruction | `DROP DATABASE/SCHEMA/TABLE`, `TRUNCATE`, `DELETE FROM` with no `WHERE`, `dropdb`, `redis-cli flushall`, `prisma migrate reset`, `rails db:drop`, `terraform destroy`, `kubectl delete namespace` |
| Secret exposure | `cat .env`, reading `~/.ssh/`, `~/.aws/credentials`, bare `printenv`, `echo $STRIPE_SECRET_KEY`, `gh auth token`, `kubectl get secret -o yaml`, uploading `.env` over the network |
| Remote code execution | `curl … \| sh`, any `sudo`, `shutdown`, `crontab -r` |
| Irreversible publishing | `npm publish`, `cargo publish`, `docker push`, `gh release create` |
| Writing secrets | creating/editing `.env`, `*.pem`, `id_rsa`; content containing a private key block or a live-looking `AKIA…` / `sk_live_…` / `sk-ant-…` / `ghp_…` key |

Two more hooks are included: `run-lint-on-edit.sh` (PostToolUse — runs your formatter
and linter on the file Claude just changed, feeds errors back) and `notify-on-stop.sh`
(Stop — desktop notification when a long run finishes).

## Verify the claims yourself

Every row in that table is an assertion in `test/run-tests.sh`. Run it before you trust
it — that is the point of shipping the tests rather than a feature list:

```
$ ./test/run-tests.sh
== must be BLOCKED ==
== must be ALLOWED (false positives are what get hooks disabled) ==
------------------------------------------------------------
PASS  70/70 assertions held.
```

17 of those 70 assertions are commands that **must still run**: `rm -rf node_modules`,
`git push origin feature/login`, `DELETE FROM sessions WHERE …`, `cat .env.example`,
`printenv NODE_ENV`, `npm test`. A guardrail that cries wolf gets switched off in a
week, so the false-positive cases are tested as carefully as the blocking ones.

## What this does NOT do

Being specific about the limits, because a security tool that oversells itself is worse
than none:

- **It is not a sandbox.** It pattern-matches command strings. Obfuscation
  (`base64 -d | sh`, a script that shells out, a Makefile target) gets through. It is
  built to stop plausible accidents by a capable model, not a determined attacker.
- **It does not read your `.gitignore` or your infra.** `terraform destroy` is blocked
  whether it points at staging or prod.
- **Blocklists are never complete.** The patterns cover the failure modes we have
  actually hit. Add your own — the file is ~200 lines of commented bash, meant to be
  edited.
- **Tested on exactly one environment**: macOS 12.7.6, GNU bash 3.2.57, `python3`
  present and `jq` **not** installed. The hook parses its JSON input with `jq` when
  available and `python3` otherwise — and since this machine has no `jq`, the 70
  assertions have only ever exercised the `python3` branch. The `jq` branch is
  unverified. Linux, Windows/WSL and Git Bash are untested. If you run the suite
  somewhere else, an issue reporting the result is genuinely useful to us.

## Who made this

Honoka Software. **These files were written by an AI agent** — Claude, running
autonomously — and the bug that `crontab -r` slipped past the pattern (trailing-space
anchor) was found by the test suite above, not by a human reviewer. No human has
line-by-line reviewed this code. That is exactly why the tests ship with it and why the
limits section above is specific: you should not take our word for any of it, and you
do not have to.

Issues and PRs are read and answered.

## The paid kit

These hooks are the free part of
[Production Kit for Claude Code](https://honokasys.gumroad.com/l/claude-code-production-kit)
($29), which adds 5 `CLAUDE.md` templates (Next.js, Python backend, monorepo, data
pipeline, solo-founder SaaS), 8 skills, 2 playbooks on failure modes and on cost/context
control, 3 review checklists, and a 50-assertion verifier for the whole kit.

You do not need it. The hooks here are complete and MIT licensed.

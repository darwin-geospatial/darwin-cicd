#!/usr/bin/env bash
# Darwin barrier (PreToolUse hook). Single source: admin-darwin-agents/templates/context/claude-all/.
# While a STOP is open in this repo, it refuses the actions that leave the machine or are hard to undo:
# git commit/push, deploys, gh pr/release, gcloud changes, sending mail. Reading and editing stay free,
# so the problem can be fixed. Stable on purpose; the STOPs themselves come from darwin-tick.sh.
set -euo pipefail
INPUT="$(cat)"
exec python3 - "$INPUT" <<'PY'
import json, os, pathlib, re, subprocess, sys
try:
    event = json.loads(sys.argv[1] or "{}")
except json.JSONDecodeError:
    sys.exit(0)
tool = str(event.get("tool_name") or "")
cmd = str((event.get("tool_input") or {}).get("command") or "")
risky = (
    (tool == "Bash" and re.search(r"\bgit\s+(commit|push)\b|deploy\.sh|\bgcloud\s+(run\s+deploy|.*\b(create|delete|update|set-iam-policy)\b)"
                                  r"|\bgh\s+(pr\s+(create|merge)|release)\b|\bterraform\s+apply\b", cmd))
    or re.search(r"(send_message|send|forward|reply|create_draft|share_file)$", tool)
)
if not risky:
    sys.exit(0)
root = pathlib.Path(os.environ.get("CLAUDE_PROJECT_DIR") or event.get("cwd") or ".")
cache = pathlib.Path(os.environ.get("DARWIN_CACHE") or pathlib.Path.home() / ".cache" / "darwin")
def repo_id() -> str:
    try:
        rj = json.loads((root / ".darwin" / "repo.json").read_text())
        rid = (rj.get("identity") or rj).get("id")
        if rid:
            return rid
    except Exception:
        pass
    r = subprocess.run(["git", "-C", str(root), "remote", "get-url", "origin"], capture_output=True, text=True)
    return re.sub(r"\.git$", "", r.stdout.strip().rstrip("/").split("/")[-1]) if r.returncode == 0 and r.stdout.strip() else root.name
stops_file = cache / "stops" / f"{repo_id()}.json"
stops = json.loads(stops_file.read_text()) if stops_file.exists() else {}
if stops:
    sys.stderr.write("Darwin STOP open (" + ", ".join(stops) + "): fix it first, then run "
                     "`bash .claude/all/darwin-done.sh <check> fixed`. This action is blocked until then.\n")
    sys.exit(2)
PY

#!/usr/bin/env bash
# Darwin checks, counted locally (UserPromptSubmit hook). Single source:
# admin-darwin-agents/templates/context/claude-all/ (copied to every repo's .claude/all/; never edit a copy).
# Stable on purpose: which checks exist, how often and where comes from the center as data
# (GET /api/v1/ticks?repo=<id>), cached once a day in ~/.cache/darwin/. No network on most messages.
set -euo pipefail
INPUT="$(cat)"
exec python3 - "$INPUT" <<'PY'
import json, os, pathlib, random, re, subprocess, sys, time, urllib.request
URL = os.environ.get("DARWIN_CENTER_URL", "https://admin-darwin-agent-center-721070867001.europe-west1.run.app")
try:
    event = json.loads(sys.argv[1] or "{}")
except json.JSONDecodeError:
    event = {}
root = pathlib.Path(os.environ.get("CLAUDE_PROJECT_DIR") or event.get("cwd") or ".")
session = re.sub(r"[^A-Za-z0-9_-]", "", str(event.get("session_id") or "no-session")) or "no-session"
cache = pathlib.Path(os.environ.get("DARWIN_CACHE") or pathlib.Path.home() / ".cache" / "darwin")
(cache / "sessions").mkdir(parents=True, exist_ok=True)
(cache / "stops").mkdir(parents=True, exist_ok=True)

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

repo = repo_id()
table = cache / f"ticks-{repo}.json"
if not table.exists() or time.time() - table.stat().st_mtime > 86400:
    try:
        with urllib.request.urlopen(f"{URL}/api/v1/ticks?repo={repo}", timeout=2) as resp:
            table.write_text(json.dumps(json.load(resp)["data"]))
    except Exception:
        pass  # keep the old copy; never block a message on the network
try:
    rows = json.loads(table.read_text())
except Exception:
    sys.exit(0)

counter = cache / "sessions" / session
count = (int(counter.read_text() or 0) if counter.exists() else 0) + 1
counter.write_text(str(count))

best = {}
for r in rows:
    if r.get("every") and count % int(r["every"]) == 0:
        fam = r.get("family") or r["id"]
        if fam not in best or int(r["every"]) > int(best[fam]["every"]):
            best[fam] = r
due = list(best.values()) + [r for r in rows if r.get("chance") and random.random() < float(r["chance"])]

stops_file = cache / "stops" / f"{repo}.json"
stops = json.loads(stops_file.read_text()) if stops_file.exists() else {}
for r in due:
    if r.get("blocking") == "yes" and r["id"] not in stops:
        stops[r["id"]] = {"since": count, "call": r["call"]}
stops_file.write_text(json.dumps(stops))

lines = [f"- {r['id']}: if {r['applies_when']}, call {r['call']} and do it ({r['description']})" for r in due]
due_ids = {r["id"] for r in due}
lines = [f"- OPEN STOP {sid} (since message {st['since']}): do nothing else until it is fixed, then run "
         f"`bash .claude/all/darwin-done.sh {sid} fixed` (or `clear` if nothing was found)"
         for sid, st in stops.items() if sid not in due_ids] + lines
if lines:
    msg = f"Darwin checks due (message {count}, repo {repo}):\n" + "\n".join(lines)
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": msg}}))
PY

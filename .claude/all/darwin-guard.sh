#!/usr/bin/env bash
# Darwin barrier (PreToolUse hook). Single source: admin-darwin-agents/templates/context/claude-all/.
# While a STOP is open in this repo, it refuses the actions that leave the machine or are hard to undo:
# git commit/push, deploys, gh pr/release, gcloud changes, sending mail. Reading and editing stay free,
# so the problem can be fixed. Stable on purpose; the STOPs themselves come from darwin-tick.sh. It also refuses a
# hand-made report page (Write/Edit of an .html or .pdf anywhere in planning/reports/, or a report page at the repo root)
# and any commit of a report page at the repo root (a review copy stays local, never committed); pages written by
# scripts are caught after the fact by darwin-report.sh.
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
# A report page is built by its workflow's builder from story.md, never written by hand (DS-STD-001-006, kb_robin('report')).
path = str((event.get("tool_input") or {}).get("file_path") or "")
if tool in ("Write", "Edit", "MultiEdit") and path:
    rel = path.replace("\\", "/")
    name = rel.rsplit("/", 1)[-1].lower()
    in_dated = re.search(r"planning/reports/.+\.(html|pdf)$", rel)
    root = pathlib.Path(os.environ.get("CLAUDE_PROJECT_DIR") or event.get("cwd") or ".").resolve()
    at_root = pathlib.Path(path).resolve().parent == root and re.search(r"(report|plan|summary|analytics)[^/]*\.(html|pdf)$", name)
    if in_dated or at_root:
        sys.stderr.write(f"Darwin: {rel} is a hand-made report page. Reports are built by their workflow's builder from "
                         "story.md (kb_robin('report'), kb_planning_workflow('project_report')); put figures in the "
                         "report's assets/ and run the builder. To review it at the root, copy the built page there "
                         "(it is kept out of git).\n")
        sys.exit(2)
    sys.exit(0)
ROOT_PAGE = r"[^/\s]*(report|plan|summary|analytics)[^/\s]*\.(html|pdf)"
if tool == "Bash" and re.search(r"\bgit\s+(add|commit)\b", cmd):
    top = pathlib.Path(os.environ.get("CLAUDE_PROJECT_DIR") or event.get("cwd") or ".")
    staged = subprocess.run(["git", "-C", str(top), "diff", "--cached", "--name-only"], capture_output=True, text=True).stdout
    named = [t for t in cmd.split() if re.fullmatch(r"(\./)?" + ROOT_PAGE, t.lower())]
    loose = [f for f in staged.splitlines() if re.fullmatch(ROOT_PAGE, f.lower())] + named
    if loose:
        sys.stderr.write("Darwin: " + ", ".join(loose) + " is a report page at the repo root: a review copy stays "
                         "local and is never committed (unstage it: git restore --staged <file>); the report lives "
                         "in planning/reports/.\n")
        sys.exit(2)
RISKY = (r"\bgit\s+(-C\s+\S+\s+)?(commit|push)\b|deploy\.sh|\bgcloud\s+(run\s+deploy|.*\b(create|delete|update|set-iam-policy)\b)"
         r"|\bgh\s+(pr\s+(create|merge)|release)\b|\bterraform\s+apply\b")
risky = (
    (tool == "Bash" and re.search(RISKY, cmd))
    or re.search(r"(send_message|send|forward|reply|create_draft|share_file)$", tool)
)
if not risky:
    sys.exit(0)
root = pathlib.Path(os.environ.get("CLAUDE_PROJECT_DIR") or event.get("cwd") or ".")
# The one exemption (051): the whole command is the second brain's own save, nothing else in it.
# Tokens are separated by spaces or tabs only: a newline outside the quoted message would start a second command.
HERE = re.escape(os.path.normpath(str(root)))
SAVE = (r"bash[ \t]+(\.claude/all|" + HERE + r"/\.claude/all)/darwin-brain\.sh[ \t]+admin-second-brain-[a-z0-9-]+[ \t]+--save[ \t]+"
        r"('[^']*'|\"[^\"`$\\]*\")")
if tool == "Bash" and re.fullmatch(SAVE, cmd.strip(" \t")):
    sys.exit(0)  # it passes through an open STOP
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

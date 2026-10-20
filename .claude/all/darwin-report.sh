#!/usr/bin/env bash
# Darwin report watch (PostToolUse hook). Single source: admin-darwin-agents/templates/context/claude-all/.
# After every Bash, Write or Edit call it looks at the files, not at the tool:
#   1. a report page (.html in planning/reports/, or a report-like .html/.pdf at the repo root) changed in the last
#      15 minutes without the planning builders' stamp is refused: whatever wrote it (a repo script, a cp, an
#      editor), it is a hand-made page (DS-STD-001-006 rule 6). A copy of a built page at the repo root (a stamped
#      .html, or a .pdf identical to one in planning/reports/) is a review copy: it may stay there but is never
#      committed, so its path is added to .git/info/exclude;
#   2. the first action of a session that works on planning/ or makes a page calls Robin's report check, even when
#      the person's message had no report words (the work may start from "continue" or from the agent itself).
set -euo pipefail
INPUT="$(cat)"
exec python3 - "$INPUT" <<'PY'
import json, os, pathlib, re, subprocess, sys, time
try:
    event = json.loads(sys.argv[1] or "{}")
except json.JSONDecodeError:
    sys.exit(0)
STAMP = 'name="generator" content="darwin-planning-builder"'
root = pathlib.Path(os.environ.get("CLAUDE_PROJECT_DIR") or event.get("cwd") or ".").resolve()
if not (root / "planning").is_dir():
    sys.exit(0)
cache = pathlib.Path(os.environ.get("DARWIN_CACHE") or pathlib.Path.home() / ".cache" / "darwin")
session = re.sub(r"[^A-Za-z0-9_-]", "", str(event.get("session_id") or "no-session")) or "no-session"
tool = str(event.get("tool_name") or "")
inp = event.get("tool_input") or {}
text = str(inp.get("command") or inp.get("file_path") or "")

# 1. unstamped report pages, by the files themselves
r = subprocess.run(["git", "-C", str(root), "status", "--porcelain", "--untracked-files=all"], capture_output=True, text=True)
now, bad, review = time.time(), [], []
def built_pdf(p: pathlib.Path) -> bool:
    data = p.read_bytes()
    return any(q.stat().st_size == len(data) and q.read_bytes() == data
               for q in (root / "planning" / "reports").rglob("*.pdf"))
for line in r.stdout.splitlines():
    rel = line[3:].strip().strip('"').split(" -> ")[-1]
    p = root / rel
    if not p.is_file() or now - p.stat().st_mtime > 900:
        continue
    page = rel.startswith("planning/reports/") and rel.endswith(".html")
    loose = "/" not in rel and re.search(r"(report|plan|summary|analytics)[^/]*\.(html|pdf)$", rel.lower())
    stamped = rel.endswith(".html") and STAMP in p.read_text(encoding="utf-8", errors="ignore")[:4000]
    if loose and line[:2] == "??" and (stamped or (rel.endswith(".pdf") and built_pdf(p))):
        review.append(rel)
    elif loose or (page and not stamped):
        bad.append(rel)
if review:
    exclude = pathlib.Path(subprocess.run(["git", "-C", str(root), "rev-parse", "--git-path", "info/exclude"],
                                          capture_output=True, text=True).stdout.strip())
    exclude = exclude if exclude.is_absolute() else root / exclude
    exclude.parent.mkdir(parents=True, exist_ok=True)
    with exclude.open("a") as f:
        f.write("".join(f"/{rel}\n" for rel in review))
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext":
        "Darwin: review copy at the repo root (" + ", ".join(review) + "), added to .git/info/exclude: it stays for "
        "review and is never committed; the report itself stays in planning/reports/."}}))
if bad:
    sys.stderr.write("Darwin: hand-made report page(s): " + ", ".join(bad) + ". A report page is built by its workflow's "
                     "builder from story.md (kb_robin('report')); a repo script writes only figures and numbers into the "
                     "report's assets/. Delete or restore the page(s), then build the report with its builder.\n")
    sys.exit(2)

# 2. the first report-like action of the session calls Robin
flag = cache / "sessions" / f"{session}.robin-report"
if not flag.exists() and re.search(r"planning/|\.html\b|\.pdf\b|report|story\.md", text, re.I):
    flag.parent.mkdir(parents=True, exist_ok=True)
    flag.write_text(tool)
    msg = ("Darwin: this action works on planning/ or makes a page. Before the next file of any report, plan, summary "
           "or analysis, call kb_robin('report') and do it (Robin names the workflow and its builder).")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}}))
PY

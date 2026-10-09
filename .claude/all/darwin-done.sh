#!/usr/bin/env bash
# Close an open Darwin STOP in this repo: bash .claude/all/darwin-done.sh <check> <clear|fixed>
# Single source: admin-darwin-agents/templates/context/claude-all/. There is no override.
set -euo pipefail
exec python3 - "${1:-}" "${2:-}" <<'PY'
import json, os, pathlib, re, subprocess, sys
check, result = sys.argv[1], sys.argv[2]
if result not in ("clear", "fixed"):
    sys.exit("result must be clear or fixed; a STOP has no override")
root = pathlib.Path(os.environ.get("CLAUDE_PROJECT_DIR") or ".")
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
f = cache / "stops" / f"{repo_id()}.json"
stops = json.loads(f.read_text()) if f.exists() else {}
if check not in stops:
    sys.exit(f"no open STOP {check}; open: {', '.join(stops) or 'none'}")
del stops[check]
f.write_text(json.dumps(stops))
print(f"closed {check} ({result}); still open: {', '.join(stops) or 'none'}")
PY

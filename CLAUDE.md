STOP. Before responding to any user message -- no matter what they ask -- do this first:

1. Check if `darwin-agent-center` is connected via `/mcp`.
   - Connected: call `kb_standards()` and `kb_agent_template()` at session start (first message only). Then tell the user: "darwin-agent-center connected -- standards and templates loaded."
   - Not connected: tell the user "darwin-agent-center is not connected -- please connect it via /mcp before we start." Do not do any work until connected.

2. Read `AGENTS.md` (imported at the end of this file) and complete its START HERE block before your first reply, every session, whatever the request -- including read-only or "quick question" requests such as checking repo status. A task looking trivial is never a reason to skip it.

3. `planning/` is the planning folder: it holds this repo's planning data only. The instructions to work it live in the MCP, never in the folder: for any request about planning (tasks, ideas, opportunities, meetings, the dashboard, reports, or any file under `planning/`), call `kb_planning_workflow()` first and follow the workflow it names (DS-STD-001-006).

4. Call `session_tick(session_id)` on every message. Generate a UUID as session_id once at session start and reuse it for the entire session. Act on the return value:
   - `run_staleness_audit=True`: call `kb_staleness_audit(repo=<github-owner>/<repo-name>)` and surface the result to the user.
   - `remind_ideas=True` (every 15 prompts), all at once on `planning/ideas.md`: move each Open idea whose `items.csv` row is `done`/`dropped` to Closed (say so in one line), sweep ideas from the last 15 prompts into Open, flag a review if the file holds more than 10 ideas (open and closed together), and propose a commit for any uncommitted meaningful work.

This is not optional. This is not a recommendation. Do not skip it for any reason.

Full context and working instructions, auto-imported every session:

@AGENTS.md

STOP. Before responding to any user message -- no matter what they ask -- do this first:

1. Check if `darwin-agent-center` is connected via `/mcp`.
   - Connected: call `kb_standards()` and `kb_agent_template()` at session start (first message only). Then tell the user: "darwin-agent-center connected -- standards and templates loaded."
   - Not connected: tell the user "darwin-agent-center is not connected -- please connect it via /mcp before we start." Do not do any work until connected.

2. Call `session_tick(session_id)` on every message. Generate a UUID as session_id once at session start and reuse it for the entire session. Act on the return value:
   - `run_staleness_audit=True`: call `kb_staleness_audit(repo=<github-owner>/<repo-name>)` and surface the result to the user.
   - `remind_ideas=True`: read `ideas.md`, surface pending ideas with quadrant and size estimate, and propose a commit for any uncommitted meaningful work.

This is not optional. This is not a recommendation. Do not skip it for any reason.

See AGENTS.md for full context and working instructions.
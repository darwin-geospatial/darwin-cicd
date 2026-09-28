# darwin-cicd

## START HERE -- RULES BEFORE WORK STARTS

1. Check if `darwin-agent-center` is connected via `/mcp`.
   - Connected: call `kb_standards()` and `kb_agent_template()` immediately.
     Then notify the user: "darwin-agent-center connected -- standards and templates loaded."
   - Not connected: tell the user and wait. Do not proceed with any task -- not even a "quick question" -- until connected.
2. Read `status.md` in the folder you are working in.
3. Read that folder's `workflow.md`. **Planning** (any request about tasks, ideas, opportunities,
   meetings, the dashboard, a meeting report or a quick report, or any file under `planning/`):
   there is no local workflow; call `kb_planning_workflow()` (the map) and the workflow it names
   (DS-STD-001-006).
4. Follow the Key Agentic Loop (status_read -> status_research -> work -> cleanup -> status_update).

No file may be touched until steps 1-4 are complete. This is a hard gate, not a recommendation.


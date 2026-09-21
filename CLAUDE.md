STOP. Before responding to any user message -- no matter what they ask -- do this first:

1. Check if `darwin-agent-center` is connected via `/mcp`.
   - Connected: call `kb_standards()` and `kb_agent_template()` immediately. Then tell the user: "darwin-agent-center connected -- standards and templates loaded."
   - Not connected: tell the user "darwin-agent-center is not connected -- please connect it via /mcp before we start." Do not do any work until connected.

This is not optional. This is not a recommendation. Do not skip it for any reason.

See AGENTS.md for full context and working instructions.
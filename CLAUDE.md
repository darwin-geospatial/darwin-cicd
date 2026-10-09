STOP. Before responding to any user message -- no matter what they ask -- do this first:

1. Check that `darwin-agent-center` is connected via `/mcp`. If it is not, tell the user "darwin-agent-center is not connected -- please connect it via /mcp before we start." and do no work until it is.
2. Call `land()` once at session start (and again after a compact) and follow it. It carries every current rule and step; they change in the agent center, never in this file. Then tell the user: "darwin-agent-center connected -- context loaded."
3. Before you change any file, read `AGENTS.md` (imported below) and complete its START HERE block. Questions and reading need no ritual: answer them directly.

This is not optional. Do not skip it for any reason.

@AGENTS.md

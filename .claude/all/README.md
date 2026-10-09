# .claude/all

Darwin's local hooks, the same in every repo. **Do not edit a copy:** the single source is
`admin-darwin-agents/templates/context/claude-all/`, rolled out to every repo.

| File | Hook | What it does |
|---|---|---|
| `darwin-tick.sh` | UserPromptSubmit | counts messages locally and says when a check is due; the table of checks is fetched from the agent center once a day and cached in `~/.cache/darwin/` |
| `darwin-guard.sh` | PreToolUse | while a STOP is open, refuses commits, pushes, deploys and sending; reading and editing stay free |
| `darwin-done.sh` | (run by the session) | closes a STOP once it is fixed: `bash .claude/all/darwin-done.sh <check> fixed` |

The scripts are stable: which checks exist, how often and where is data in the agent center
(ADR-0010), so changing a check never needs a rollout.

# .claude/all

Darwin's local hooks, the same in every repo. **Do not edit a copy:** the single source is
`admin-darwin-agents/templates/context/claude-all/`, rolled out to every repo.

| File | Hook | What it does |
|---|---|---|
| `darwin-tick.sh` | UserPromptSubmit | counts messages locally and says when a check is due (every N messages, by chance, or when the prompt matches a check's `trigger`, e.g. a report or plan calls Robin); the table of checks is fetched from the agent center once a day and cached in `~/.cache/darwin/` |
| `darwin-brain.sh` | UserPromptSubmit (and land() step 0) | the person's second brain tags, at most once every 2 h across all their chats: one clock in `~/.cache/darwin/second-brain.last`, the first chat past 2 h fetches (never pulls), lists the tags not yet handled and resets it, the others stay quiet; nothing pending, nothing said; the chat offers to file them and keeps its job (row 047). land() step 0 runs it with the brain's name, which it records for the hook. In that mode it also says, every time, when the brain is not cloned (ask the person, clone on a yes, rerun) or has unsaved work (uncommitted files or commits not pushed), and on a Thursday or Friday, once a day, offers the weekly report when this week's `report.pdf` is missing locally and on the remote. `darwin-brain.sh <brain> --save "<message>"` saves the brain in one step (row 051): commits everything but `local/` with the person's git identity, pulls with rebase and pushes (a tracked file the exclude rules hide, such as a private report over a saved week, is unstaged and reported as skipped); on a conflict it keeps the commit local, never forces |
| `darwin-guard.sh` | PreToolUse | while a STOP is open, refuses commits, pushes (`git -C` too), deploys and sending, except the second brain save alone (`bash .claude/all/darwin-brain.sh admin-second-brain-<id> --save '<message>'`, nothing chained); always refuses a hand-made report page (an .html or .pdf written by hand anywhere in `planning/reports/` or at the repo root) and any commit of a report page at the repo root; other reading and editing stay free |
| `darwin-report.sh` | PostToolUse | after every Bash, Write or Edit: refuses a report page in `planning/reports/` (or a report page at the repo root) without the planning builders' stamp, whatever wrote it; a copy of a built page at the root is a review copy, added to `.git/info/exclude` (never committed); the first action of a session on `planning/` or a page calls Robin's report check |
| `darwin-done.sh` | (run by the session) | closes a STOP once it is fixed: `bash .claude/all/darwin-done.sh <check> fixed` |

The scripts are stable: which checks exist, how often and where is data in the agent center
(ADR-0010), so changing a check never needs a rollout.

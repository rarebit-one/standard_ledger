---
name: start
description: "Start working on GitHub Issues (in rarebit-one/standard_ledger). Use when the user says 'start working on', 'pick up issue', 'work on #42', 'start #42', '/start', or wants to begin development on a planned issue. Handles context gathering, branch creation, and in-progress signaling."
---

# Start Skill

Begin working on GitHub Issues with proper setup: signal in-progress, create branches, gather context, and track progress.

> **Planning system:** This repo's planning lives in **GitHub Issues in the `rarebit-one/standard_ledger` repo** (its own issues). Code and issues live in the same repo, so PRs that say `Closes #NN` auto-close the issue on merge.

## Prerequisites

This skill uses the `gh` CLI against `rarebit-one/standard_ledger`. If `gh` is unavailable or you lack access, the skill will warn and offer to proceed with git-only setup (branch creation without in-progress signaling — you supply the issue context).

## Scope

This skill sets up local development for GitHub Issues. It does **NOT**:
- Merge PRs to main (merging is a human decision)
- Delete branches or worktrees automatically
- Close or complete issues (a merged PR with `Closes #NN` closes them automatically)

## Usage

```
/start <issue-numbers...>        # Start specific issues (e.g., /start 42 43, /start #42)
/start --mine                    # Show my assigned open issues
/start --backlog                 # Show open, unassigned issues
```

Accepted identifier forms: `42`, `#42`, `standard_ledger-42`, or a full issue URL. All normalize to the issue number.

## Workflow

### 1. Parse Input and Fetch Issues

**If specific issue numbers provided:**

Fetch each issue with `gh`:

```bash
gh api repos/rarebit-one/standard_ledger/issues/<n> \
  --jq '{number, title, state, labels: [.labels[].name], assignees: [.assignees[].login], milestone: .milestone.title, body}'

# Comments often carry decisions and clarifications — read them too
gh api repos/rarebit-one/standard_ledger/issues/<n>/comments \
  --jq '.[] | {user: .user.login, created_at, body}'
```

The title, body, labels, and comments are the context for the work.

**If `--mine` flag:**

```bash
gh issue list -R rarebit-one/standard_ledger --assignee @me --state open --limit 10
```

**If `--backlog` flag (optionally with `--label <name>`):**

```bash
gh issue list -R rarebit-one/standard_ledger --state open --search "no:assignee" --limit 10
```

> "Backlog" here means open + unassigned. If the repo adopts a `backlog` label or triage milestone, prefer `--label backlog` to avoid surfacing untriaged issues.

Present the issues and let the user select which to work on.

### 2. Pre-Work Checks

Before starting, verify:

**Check for blockers:**

GitHub Issues has no native blocking relations — scan the issue body and comments for "blocked by", "depends on", or `#NN` references, and check the state of any referenced issues. This scan is **heuristic**: a bare `#NN` mention may be incidental (e.g. "see discussion in #40"), so read the surrounding context before raising a blocker warning.

```bash
gh api repos/rarebit-one/standard_ledger/issues/<referenced-n> --jq '{number, title, state}'
```

If blocked:
```
Warning: #42 appears blocked by:
  - #40: "Set up middleware" (open)

Options:
1. Start anyway (work may be blocked)
2. Start the blocking issue instead
3. Cancel
```

**Check issue readiness:**
- Has description/acceptance criteria?
- Part of a milestone?

If missing context, warn but allow proceeding.

### 3. Signal In-Progress

**Skip this step if `--no-status` flag is provided.**

Mark the issue in-progress by assigning yourself (and applying an in-progress label if the repo uses one):

```bash
gh issue edit <n> -R rarebit-one/standard_ledger --add-assignee @me
# If the repo uses an in-progress label:
gh issue edit <n> -R rarebit-one/standard_ledger --add-label "in progress"
```

The workflow should not block on GitHub failures — local development can proceed. On a transient `gh` failure (e.g. 401), retry once before surfacing the error.

### 4. Set Up Worktree

**Always create a worktree** to isolate this work from any other state in the repo. This prevents changes from different sessions bleeding into unrelated PRs.

```bash
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
git fetch origin "$DEFAULT_BRANCH"
git worktree add .worktrees/<identifier> -b <branch-name> "origin/$DEFAULT_BRANCH"
```

**`--no-worktree` flag:** If the user explicitly passes `--no-worktree`, check the current state:
- On the default branch with a clean working tree → fall back to a simple branch:
  ```bash
  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@')
  DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
  git fetch origin "$DEFAULT_BRANCH"
  git checkout -b <branch-name> "origin/$DEFAULT_BRANCH"
  ```
- Otherwise → **stop and report why**:
  _"Cannot skip worktree: working tree has uncommitted changes (or is on a feature branch). Stash or commit your changes first, switch to the default branch, then re-run with `--no-worktree`."_

> **Note:** The previous version of this skill offered stash and branch-switch workflows. Those paths have been removed in favor of always using worktrees. If you prefer to stash instead, run `git stash push -m "WIP"` manually before `/start`.

See `/worktree` skill for full worktree conventions.

**Branch name format:**

Derive the branch name from the issue number plus a short slug of the issue title:
`<n>/<short-description>` (e.g., `42/add-feature-name`)

**Worktree naming:** `.worktrees/<identifier>` (e.g., `.worktrees/42`)

### 5. Display Issue Context

```
Starting: #42
Issue: <title>
URL: https://github.com/rarebit-one/standard_ledger/issues/42

Description:
<full description>

Acceptance Criteria:
- [ ] ...

Branch: <branch-name>
```

### 6. Create Initial Todo List

Based on the issue description, create a todo list to track progress.

## Flags Reference

| Flag | Description |
|------|-------------|
| `--mine` | List my assigned open issues in rarebit-one/standard_ledger |
| `--backlog` | List open, unassigned issues |
| `--no-worktree` | Skip worktree if on the default branch + clean; stops with error otherwise |
| `--no-status` | Skip the in-progress signal (just create branch) |
| `--label <name>` | Filter issue lists by label |

## Error Handling

| Error | Solution |
|-------|----------|
| `gh` returns 401 | Retry once (transient token issue); if it persists, check `gh auth status` and ask the user |
| `gh` unavailable / no access | Warn and offer to proceed with just git setup (user supplies issue context) |
| Issue not found | Verify the number; confirm the repo is `rarebit-one/standard_ledger` |
| Issue already assigned / in progress | Ask if user wants to continue anyway |
| Issue is closed | Warn and suggest reopening or selecting a different issue |
| In-progress signal fails | Offer to continue with local setup, retry, or cancel |
| Branch already exists | Offer to checkout existing or create with suffix |
| Worktree already exists | Offer to use existing worktree or create with suffix |

## Integration with Other Skills

- After completing work, create a PR with `gh pr create` (body referencing the issue as `Closes #NN`), or use `/publish-gem` when ready to release
- The `<n>/<slug>` branch naming convention ensures the issue number can be auto-detected from the branch

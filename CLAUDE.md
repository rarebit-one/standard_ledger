# CLAUDE.md

## Worktree-Only Workflow (Enforced)

**All file modifications are blocked in the main checkout.** A PreToolUse hook (`enforce-worktree.sh`) rejects Edit, Write, and NotebookEdit operations targeting files outside a worktree. There are no opt-outs. Do not use Bash to write files in the main checkout either (e.g., `echo >`, `sed -i`, `tee`, `cp`) — the hook cannot intercept shell commands, so this rule is instruction-enforced.

Before writing any code, create a worktree:

```bash
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
git fetch origin "$DEFAULT_BRANCH"
git worktree add .worktrees/<name> -b <branch-name> "origin/$DEFAULT_BRANCH"
```

Then work inside `.worktrees/<name>/` for the rest of the session.

**Naming:** Use a task slug (e.g., `.worktrees/fix-auth-timeout`) or today's date (e.g., `.worktrees/2026-04-01`) as fallback.

**The hook allows modifications only when:**

1. The file is inside a git worktree (detected via `git rev-parse --git-dir` returning a path under `.git/worktrees/`)
2. Running in a CI/automated context where the checkout is already isolated

**Why this matters:** Working directly on the main checkout causes cross-contamination between sessions — uncommitted changes, wrong branches, and dirty state leak into unrelated work. Worktrees eliminate this entirely.

See the `/worktree` and `/start` skills for full conventions and flags.

## Auto-loaded rules (`.claude/rules/`)

- `ledger-entry-contract.md` — the immutability / append-only / idempotency
  invariants of `StandardLedger::Entry` that must be preserved when editing
  `lib/standard_ledger/**` or specs. Loads only when a matching file is touched.

## Consumers

`standard_ledger` is consumed by these apps in the rarebit-one workspace:

- `fundbright-web`
- `luminality-web`
- `sidekick-web`
- `jumpdrive-web` (the control-plane app, formerly `workspace-os`; its `Gemfile`/`Gemfile.lock` live under `control-plane/`, **not** the repo root — a `*/Gemfile` glob misses it. Its local checkout is `~/Workspace/rarebit-one/jumpdrive-web`.)

`nutripod-web` does **not** consume this gem — it is the one app in the estate that doesn't.

Three consumers live in sibling workspaces — `fundbright-web` in `~/Workspace/fundbright/`, `luminality-web` in `~/Workspace/luminalityai/`, `sidekick-web` in `~/Workspace/sidekick-labs/`.

**Consumption is plain rubygems (`gem "standard_ledger", "~> X.Y"`), not git+tag.** This section claimed git+tag until 2026-07-31; that was legacy and is now wrong in every consumer. The gem has been published on RubyGems since 2026-05-07, and the last two git pins were converted in `luminalityai/luminality-web#984` and `rarebit-one/jumpdrive-web#456`. **Don't reintroduce a `git:` reference** — it makes a bare `bundle install` a prerequisite for every other command in a fresh devcontainer (`Bundler::GitError: ... is not yet checked out`), blocking `rubocop`/`rspec`/`srb tc` until it is run.

After publishing a new version via `/publish-gem`, roll it out with the workspace-level `/rollout-gem standard_ledger [<version>]` skill (defined at the rarebit-one workspace root, one directory above this repo). The canonical consumer matrix — including version constraints — lives in that skill's `SKILL.md`; the list here is a summary of it, kept in the bulleted form that `.claude/scripts/check-gem-family-drift.sh` compares against the matrix.

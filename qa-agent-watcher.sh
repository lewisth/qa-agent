#!/bin/bash
set -euo pipefail

# ── Usage ────────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 <workspace-path>"
  echo ""
  echo "  workspace-path   Absolute path to the git repo to watch"
  echo ""
  echo "Environment variables:"
  echo "  AGENT_MODEL      LLM model for Cursor Agent (default: composer-2.5-fast)"
  echo "  POLL_INTERVAL    Seconds between polls when run in loop mode (default: 600)"
  echo "  GITHUB_REPO      owner/repo override (default: auto-detect from workspace)"
  exit 1
}

WORKSPACE="${1:-}"
if [ -z "$WORKSPACE" ] || [ ! -d "$WORKSPACE" ]; then
  usage
fi

# ── Configuration ────────────────────────────────────────────────────
MODEL="${AGENT_MODEL:-composer-2.5-fast}"
DEFAULT_BRANCH="master"
LOCKFILE="/tmp/qa-agent-watcher-$(printf '%s' "$WORKSPACE" | shasum -a 256 | cut -c1-12).lock"
LOG_PREFIX="[qa-agent-watcher]"
REQUIRED_LABELS="qa-verified,ready-for-agent"

LABEL_IN_PROGRESS="agent-in-progress"
LABEL_PR_CREATED="agent-pr-created"
LABEL_FAILED="agent-failed"
LABEL_READY="ready-for-agent"

# ── Logging ──────────────────────────────────────────────────────────
log() {
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $LOG_PREFIX $*"
}

log_error() {
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $LOG_PREFIX [ERROR] $*" >&2
}

# ── Lockfile (prevent concurrent runs) ───────────────────────────────
acquire_lock() {
  if [ -f "$LOCKFILE" ]; then
    local pid
    pid=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log "Another instance is running (PID $pid). Exiting."
      exit 0
    else
      log "Stale lockfile found (PID $pid not running). Removing."
      rm -f "$LOCKFILE"
    fi
  fi
  echo $$ > "$LOCKFILE"
}

release_lock() {
  rm -f "$LOCKFILE"
}

trap release_lock EXIT

# ── Preflight checks ────────────────────────────────────────────────
for cmd in gh jq agent git; do
  if ! command -v "$cmd" &> /dev/null; then
    log_error "'$cmd' is required and must be on PATH."
    exit 1
  fi
done

cd "$WORKSPACE"

acquire_lock

REPO="${GITHUB_REPO:-}"
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  if [ -z "$REPO" ]; then
    log_error "Could not determine repo. Set GITHUB_REPO=owner/repo or ensure gh is authenticated."
    exit 1
  fi
fi

GH_USER=$(gh api user --jq '.login' 2>/dev/null || echo "")
if [ -z "$GH_USER" ]; then
  log "Warning: Could not determine GitHub username. PRs will not be auto-assigned."
fi

log "Starting — Repo: $REPO | Workspace: $WORKSPACE | Model: $MODEL"

# ── Ensure clean working tree ────────────────────────────────────────
ensure_clean_state() {
  log "Ensuring clean state on $DEFAULT_BRANCH..."
  git checkout "$DEFAULT_BRANCH" 2>/dev/null || git checkout -f "$DEFAULT_BRANCH"
  git reset --hard "origin/$DEFAULT_BRANCH"
  git clean -fd
  git pull origin "$DEFAULT_BRANCH"
}

ensure_clean_state

# ── Find the oldest ready issue ──────────────────────────────────────
find_next_issue() {
  gh issue list \
    --repo "$REPO" \
    --state open \
    --label "$REQUIRED_LABELS" \
    --limit 100 \
    --json number,title,body,createdAt \
    --jq 'sort_by(.createdAt) | .[0] // empty' \
    2>/dev/null || echo ""
}

issue_json=$(find_next_issue)

if [ -z "$issue_json" ]; then
  log "No issues found with labels [$REQUIRED_LABELS]. Nothing to do."
  exit 0
fi

ISSUE_NUMBER=$(printf '%s' "$issue_json" | jq -r '.number')
ISSUE_TITLE=$(printf '%s' "$issue_json" | jq -r '.title')
ISSUE_BODY=$(printf '%s' "$issue_json" | jq -r '.body // "No description provided."')

log "Found issue #$ISSUE_NUMBER: $ISSUE_TITLE"

# ── Update labels: remove ready-for-agent, add agent-in-progress ─────
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
  --remove-label "$LABEL_READY" \
  --add-label "$LABEL_IN_PROGRESS" 2>/dev/null || true

# ── Create feature branch ────────────────────────────────────────────
slugified_title=$(printf '%s' "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | cut -c1-50)
BRANCH_NAME="fix/${ISSUE_NUMBER}/${slugified_title}"

log "Creating branch: $BRANCH_NAME"
git branch -D "$BRANCH_NAME" 2>/dev/null || true
git checkout -b "$BRANCH_NAME"

# ── Build agent command ──────────────────────────────────────────────
build_agent_cmd() {
  local cmd="agent --force --trust"
  [ -n "$MODEL" ] && cmd="$cmd --model $MODEL"
  cmd="$cmd -p"
  echo "$cmd"
}

# ── Run the agent ────────────────────────────────────────────────────
prompt="You are working on the GitHub repo: $REPO on branch: $BRANCH_NAME

ISSUE TO FIX — Issue #$ISSUE_NUMBER: $ISSUE_TITLE
$ISSUE_BODY

INSTRUCTIONS (follow in order):
1. Read the issue above carefully. Understand the bug or problem described.
2. Use TDD (Test-Driven Development) to implement the fix:
   - Write a failing test first that reproduces the bug.
   - Implement the minimum code to make the test pass.
   - Refactor while keeping tests green.
   - Use NSubstitute for mocking (NOT Moq) and Shouldly for assertions (NOT FluentAssertions).
3. If the issue requires database schema changes, use the Entity Framework CLI:
   - Run 'dotnet ef migrations add <MigrationName>' to generate migration files.
   - NEVER create migration files by hand — always use the CLI.
4. Run the full build: 'dotnet build' — ensure zero errors.
5. Run all tests: 'dotnet test' — ensure all pass.
6. Stage and commit your changes with a message in the format: fix #$ISSUE_NUMBER: <short description>
   (The 'fix #N' prefix will auto-close the issue when the PR is merged.)
7. Do NOT push. Do NOT create a pull request. Just commit locally.

RULES:
- ONLY work on issue #$ISSUE_NUMBER. Do not touch other issues.
- Use TDD: red-green-refactor for every code change.
- Use 'dotnet ef migrations add' for any database migrations — never hand-write migration files.
- Do not use Moq or FluentAssertions. Use NSubstitute and Shouldly.
- Do not add comments to unit tests.
- Favour ORM over raw SQL — no stored procedures, no raw SQL in source code.
- The build MUST compile and ALL tests MUST pass before you commit.
- If you cannot fix the issue (build fails, tests fail, or the problem is unclear), do NOT commit.
- When finished, output <promise>DONE</promise> if the issue is fully resolved with passing build and tests,
  or <promise>BLOCKED</promise> if you could not complete it (explain why in your output)."

log "Running agent on issue #$ISSUE_NUMBER..."
agent_cmd=$(build_agent_cmd)
result=$($agent_cmd "$prompt" 2>&1) || true

log "Agent finished."

# ── Check for auth failures ──────────────────────────────────────────
if echo "$result" | grep -qi "authentication required\|CURSOR_API_KEY\|agent login"; then
  log_error "Agent authentication failed. Ensure 'agent login' has been run or CURSOR_API_KEY is set."
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
    --remove-label "$LABEL_IN_PROGRESS" \
    --add-label "$LABEL_READY" 2>/dev/null || true
  ensure_clean_state
  exit 1
fi

# ── Evaluate result ──────────────────────────────────────────────────
if [[ "$result" == *"<promise>DONE</promise>"* ]]; then
  commit_count=$(git rev-list --count "$DEFAULT_BRANCH"..HEAD 2>/dev/null || echo "0")

  if [ "$commit_count" -eq 0 ]; then
    log "Agent said DONE but no commits found. Treating as failure."
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "$LABEL_IN_PROGRESS" \
      --add-label "$LABEL_FAILED" 2>/dev/null || true
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "🤖 Agent reported success but produced no commits. Needs manual investigation." 2>/dev/null || true
    ensure_clean_state
    exit 0
  fi

  log "Issue #$ISSUE_NUMBER resolved. Pushing and creating PR..."

  git push -u origin "$BRANCH_NAME"

  # ── Generate PR body via agent ───────────────────────────────────
  pr_body_prompt="You are writing a pull request description for the GitHub repo: $REPO.

The branch '$BRANCH_NAME' fixes issue #$ISSUE_NUMBER: $ISSUE_TITLE

Original issue description:
$ISSUE_BODY

Write a clear pull request description in markdown. Include:
- A summary of the bug and what was fixed.
- Key implementation details or decisions.
- How it was tested (TDD — describe the test that reproduces the bug).
- The line: 'Fixes #$ISSUE_NUMBER'

Output ONLY the markdown body — no preamble, no code fences wrapping the whole thing."

  pr_agent_cmd=$(build_agent_cmd)
  pr_body=$($pr_agent_cmd "$pr_body_prompt" 2>&1) || true

  if [ -z "$pr_body" ] || echo "$pr_body" | grep -qi "authentication required\|CURSOR_API_KEY"; then
    pr_body="## Fix #$ISSUE_NUMBER: $ISSUE_TITLE

Fixes #$ISSUE_NUMBER

*Pull request auto-generated by qa-agent-watcher.*"
  fi

  # ── Create the PR ────────────────────────────────────────────────
  pr_create_args="--repo $REPO --base $DEFAULT_BRANCH --head $BRANCH_NAME"
  pr_create_args="$pr_create_args --title \"Fix #$ISSUE_NUMBER: $ISSUE_TITLE\""
  [ -n "$GH_USER" ] && pr_create_args="$pr_create_args --assignee $GH_USER"

  pr_url=$(gh pr create \
    --repo "$REPO" \
    --base "$DEFAULT_BRANCH" \
    --head "$BRANCH_NAME" \
    --title "Fix #$ISSUE_NUMBER: $ISSUE_TITLE" \
    --body "$pr_body" \
    ${GH_USER:+--assignee "$GH_USER"} \
    2>/dev/null || echo "")

  if [ -n "$pr_url" ]; then
    log "PR created: $pr_url"

    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "$LABEL_IN_PROGRESS" \
      --add-label "$LABEL_PR_CREATED" 2>/dev/null || true

    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "🤖 Agent has created a fix: $pr_url" 2>/dev/null || true
  else
    log_error "Failed to create PR. Branch $BRANCH_NAME has been pushed."
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "$LABEL_IN_PROGRESS" \
      --add-label "$LABEL_FAILED" 2>/dev/null || true
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "🤖 Agent fixed the issue and pushed branch \`$BRANCH_NAME\`, but failed to create the PR. Please create it manually." 2>/dev/null || true
  fi

else
  log "Issue #$ISSUE_NUMBER could not be resolved by the agent."

  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
    --remove-label "$LABEL_IN_PROGRESS" \
    --add-label "$LABEL_FAILED" 2>/dev/null || true

  blocked_reason=""
  if [[ "$result" == *"<promise>BLOCKED</promise>"* ]]; then
    blocked_reason=$(echo "$result" | grep -A5 "BLOCKED" | tail -4 | head -3)
  fi

  comment_body="🤖 Agent could not resolve this issue automatically. Manual intervention needed."
  [ -n "$blocked_reason" ] && comment_body="$comment_body

Agent notes:
\`\`\`
$blocked_reason
\`\`\`"

  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
    --body "$comment_body" 2>/dev/null || true
fi

# ── Return to clean state ────────────────────────────────────────────
ensure_clean_state

log "Done."

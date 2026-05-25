#!/bin/bash
set -euo pipefail

echo "══════════════════════════════════════════════════════"
echo "  QA Agent Watcher — Preflight Check"
echo "══════════════════════════════════════════════════════"
echo ""

PASS=0
FAIL=0

check() {
  local description="$1"
  local result="$2"

  if [ "$result" = "ok" ]; then
    echo "  ✅ $description"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $description — $result"
    FAIL=$((FAIL + 1))
  fi
}

# ── CLI tools ────────────────────────────────────────────────────────
echo "Dependencies:"

if command -v git &> /dev/null; then
  check "git $(git --version | awk '{print $3}')" "ok"
else
  check "git" "not found — install via Xcode CLI tools: xcode-select --install"
fi

if command -v gh &> /dev/null; then
  check "gh $(gh --version | head -1 | awk '{print $3}')" "ok"
else
  check "gh (GitHub CLI)" "not found — install: brew install gh"
fi

if command -v jq &> /dev/null; then
  check "jq $(jq --version 2>&1)" "ok"
else
  check "jq" "not found — install: brew install jq"
fi

if command -v agent &> /dev/null; then
  check "agent (Cursor CLI)" "ok"
else
  check "agent (Cursor CLI)" "not found — ensure Cursor CLI is installed and on PATH"
fi

if command -v md5 &> /dev/null; then
  check "md5 (macOS)" "ok"
else
  check "md5" "not found — expected on macOS"
fi

# ── Authentication ───────────────────────────────────────────────────
echo ""
echo "Authentication:"

gh_auth=$(gh auth status 2>&1 || true)
if echo "$gh_auth" | grep -qi "logged in"; then
  gh_user=$(gh api user --jq '.login' 2>/dev/null || echo "unknown")
  check "GitHub CLI authenticated as @$gh_user" "ok"
else
  check "GitHub CLI" "not authenticated — run: gh auth login"
fi

agent_check=$(agent --version 2>&1 || echo "failed")
if echo "$agent_check" | grep -qi "error\|not found\|login\|auth"; then
  check "Cursor Agent" "may need authentication — run: agent login"
else
  check "Cursor Agent accessible" "ok"
fi

# ── Workspace check ──────────────────────────────────────────────────
echo ""
echo "Workspace:"

WORKSPACE="${1:-}"
if [ -n "$WORKSPACE" ] && [ -d "$WORKSPACE" ]; then
  check "Workspace exists: $WORKSPACE" "ok"

  if [ -d "$WORKSPACE/.git" ]; then
    check "Is a git repo" "ok"

    cd "$WORKSPACE"
    repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
    if [ -n "$repo" ]; then
      check "GitHub repo: $repo" "ok"

      labels=$(gh label list --repo "$repo" --json name --jq '.[].name' 2>/dev/null || echo "")
      for label in "qa-verified" "ready-for-agent" "agent-in-progress" "agent-pr-created" "agent-failed"; do
        if echo "$labels" | grep -qx "$label"; then
          check "Label '$label' exists" "ok"
        else
          check "Label '$label'" "missing — create with: gh label create \"$label\" --repo $repo"
        fi
      done
    else
      check "GitHub repo detection" "could not detect — set GITHUB_REPO env var"
    fi
  else
    check "Is a git repo" "not a git repo"
  fi
elif [ -n "$WORKSPACE" ]; then
  check "Workspace: $WORKSPACE" "directory does not exist"
else
  echo "  ⚠️  No workspace path provided. Pass it as an argument to check repo-specific settings."
  echo "     Usage: $0 /path/to/repo"
fi

# ── launchd ──────────────────────────────────────────────────────────
echo ""
echo "launchd:"

plist_count=$(ls ~/Library/LaunchAgents/com.qa-agent-watcher.* 2>/dev/null | wc -l | xargs)
if [ "$plist_count" -gt 0 ]; then
  check "$plist_count plist(s) found in ~/Library/LaunchAgents/" "ok"
  for plist in ~/Library/LaunchAgents/com.qa-agent-watcher.*; do
    label=$(defaults read "$plist" Label 2>/dev/null || basename "$plist" .plist)
    loaded=$(launchctl list 2>/dev/null | grep "$label" || echo "")
    if [ -n "$loaded" ]; then
      check "  $label — loaded" "ok"
    else
      check "  $label" "not loaded — run: launchctl load $plist"
    fi
  done
else
  check "launchd plists" "none found — follow setup instructions to create one"
fi

# ── Log directory ────────────────────────────────────────────────────
echo ""
echo "Logging:"

if [ -d "$HOME/logs" ]; then
  check "~/logs/ directory exists" "ok"
else
  check "~/logs/ directory" "missing — create with: mkdir -p ~/logs"
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo "  All $PASS checks passed. Ready to go."
else
  echo "  $PASS passed, $FAIL failed. Fix the issues above."
fi
echo "══════════════════════════════════════════════════════"

exit "$FAIL"

#!/bin/bash
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { printf "${CYAN}▸${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}✓${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}!${NC} %s\n" "$*"; }
fail()  { printf "${RED}✗${NC} %s\n" "$*"; exit 1; }

# ── Preflight checks ─────────────────────────────────────────────────
info "Checking prerequisites..."

missing=()
for cmd in agent gh jq git; do
  if ! command -v "$cmd" &>/dev/null; then
    missing+=("$cmd")
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  fail "Missing required tools: ${missing[*]}. Install them and re-run."
fi

if ! gh auth status &>/dev/null; then
  fail "GitHub CLI not authenticated. Run 'gh auth login' first."
fi

ok "All prerequisites met."

# ── Gather inputs ─────────────────────────────────────────────────────
echo ""
printf "${CYAN}Workspace path${NC} (absolute path to the repo the agent should watch):\n> "
read -r WORKSPACE_PATH
WORKSPACE_PATH="${WORKSPACE_PATH/#\~/$HOME}"

if [ -z "$WORKSPACE_PATH" ] || [ ! -d "$WORKSPACE_PATH" ]; then
  fail "Directory does not exist: $WORKSPACE_PATH"
fi

if [ ! -d "$WORKSPACE_PATH/.git" ]; then
  fail "Not a git repo: $WORKSPACE_PATH"
fi

printf "${CYAN}Project name${NC} (short, lowercase, no spaces — used in filenames):\n> "
read -r PROJECT_NAME

if [ -z "$PROJECT_NAME" ]; then
  fail "Project name cannot be empty."
fi

PROJECT_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

printf "${CYAN}Poll interval${NC} in seconds [600]: "
read -r POLL_INTERVAL
POLL_INTERVAL="${POLL_INTERVAL:-600}"

printf "${CYAN}GitHub repo${NC} (owner/repo) — leave blank to auto-detect: "
read -r GITHUB_REPO

# ── Install the watcher script ────────────────────────────────────────
SCRIPT_DIR="$HOME/scripts"
SCRIPT_PATH="$SCRIPT_DIR/qa-agent-watcher.sh"
SOURCE_SCRIPT="$(cd "$(dirname "$0")" && pwd)/qa-agent-watcher.sh"

if [ ! -f "$SOURCE_SCRIPT" ]; then
  fail "Cannot find qa-agent-watcher.sh alongside this setup script."
fi

info "Installing watcher script to $SCRIPT_PATH..."
mkdir -p "$SCRIPT_DIR"
cp "$SOURCE_SCRIPT" "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"
ok "Watcher script installed."

# ── Create log directory ──────────────────────────────────────────────
LOG_DIR="$HOME/logs"
LOG_FILE="$LOG_DIR/qa-agent-watcher-${PROJECT_NAME}.log"
mkdir -p "$LOG_DIR"
ok "Log directory ready: $LOG_DIR"

# ── Generate the launchd plist ────────────────────────────────────────
PLIST_LABEL="com.qa-agent-watcher.${PROJECT_NAME}"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

info "Creating launchd plist at $PLIST_PATH..."

ENV_VARS="        <key>AGENT_MODEL</key>
        <string>composer-2.5-fast</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>"

if [ -n "$GITHUB_REPO" ]; then
  ENV_VARS="$ENV_VARS
        <key>GITHUB_REPO</key>
        <string>$GITHUB_REPO</string>"
fi

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${SCRIPT_PATH}</string>
        <string>${WORKSPACE_PATH}</string>
    </array>

    <key>StartInterval</key>
    <integer>${POLL_INTERVAL}</integer>

    <key>EnvironmentVariables</key>
    <dict>
${ENV_VARS}
    </dict>

    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>

    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>

    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

ok "Plist created."

# ── Create GitHub labels ──────────────────────────────────────────────
REPO_FOR_LABELS="${GITHUB_REPO:-}"
if [ -z "$REPO_FOR_LABELS" ]; then
  REPO_FOR_LABELS=$(cd "$WORKSPACE_PATH" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
fi

if [ -n "$REPO_FOR_LABELS" ]; then
  info "Creating GitHub labels on $REPO_FOR_LABELS (skipping any that exist)..."
  gh label create "ready-for-agent"    --color "0E8A16" --description "Issue is ready for the agent to pick up"  --repo "$REPO_FOR_LABELS" 2>/dev/null || true
  gh label create "agent-in-progress"  --color "FBCA04" --description "Agent is currently working on this"       --repo "$REPO_FOR_LABELS" 2>/dev/null || true
  gh label create "agent-pr-created"   --color "1D76DB" --description "Agent has created a PR for this fix"      --repo "$REPO_FOR_LABELS" 2>/dev/null || true
  gh label create "agent-failed"       --color "D93F0B" --description "Agent could not resolve this issue"       --repo "$REPO_FOR_LABELS" 2>/dev/null || true
  ok "Labels created."
else
  warn "Could not detect repo — skipping label creation. Create them manually (see setup docs)."
fi

# ── Load the agent ────────────────────────────────────────────────────
info "Loading the launch agent..."
launchctl load "$PLIST_PATH" 2>/dev/null || true
ok "Launch agent loaded."

# ── Verify ────────────────────────────────────────────────────────────
echo ""
if launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"; then
  ok "Setup complete! The watcher is running."
else
  warn "Plist loaded but not showing in launchctl. Check: launchctl list | grep qa-agent-watcher"
fi

echo ""
info "Useful commands:"
echo "  View logs:    tail -f $LOG_FILE"
echo "  Stop:         launchctl unload $PLIST_PATH"
echo "  Restart:      launchctl unload $PLIST_PATH && launchctl load $PLIST_PATH"

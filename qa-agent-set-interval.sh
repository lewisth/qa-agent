#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { printf "${CYAN}▸${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}✓${NC} %s\n" "$*"; }
fail() { printf "${RED}✗${NC} %s\n" "$*"; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [interval] [project]

Change how often the QA agent watcher runs (launchd StartInterval).

  interval   Seconds between runs, or a preset:
               hourly   → 3600 (default)
               10m      → 600
               30m      → 1800
               daily    → 86400
  project    Optional project name (e.g. vanguard). Updates all watchers if omitted.
             Run without a project name to list available watchers.

Examples:
  $(basename "$0")              # all watchers, hourly
  $(basename "$0") hourly       # same as above
  $(basename "$0") list         # show installed watchers
  $(basename "$0") 600 myproject # every 10 minutes for one project
EOF
}

list_projects() {
  shopt -s nullglob
  local plists=("$HOME/Library/LaunchAgents/com.qa-agent-watcher."*.plist)
  shopt -u nullglob

  if [ ${#plists[@]} -eq 0 ]; then
    echo "  (none)"
    return 1
  fi

  for plist in "${plists[@]}"; do
    local project="${plist##*/com.qa-agent-watcher.}"
    project="${project%.plist}"
    local interval
    interval=$(/usr/libexec/PlistBuddy -c "Print StartInterval" "$plist" 2>/dev/null || echo "?")
    echo "  - $project (${interval}s)"
  done
}

resolve_interval() {
  case "$1" in
    hourly|hour|1h) echo 3600 ;;
    10m|10min)      echo 600 ;;
    30m|30min)      echo 1800 ;;
    daily|day|1d)   echo 86400 ;;
    ''|help|-h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]; then
        echo "$1"
      else
        fail "Invalid interval: $1 (use seconds or hourly, 10m, 30m, daily)"
      fi
      ;;
  esac
}

INTERVAL_ARG="${1:-hourly}"
PROJECT="${2:-}"

if [ "$INTERVAL_ARG" = "help" ] || [ "$INTERVAL_ARG" = "-h" ] || [ "$INTERVAL_ARG" = "--help" ]; then
  usage
  exit 0
fi

if [ "$INTERVAL_ARG" = "list" ]; then
  info "Installed QA agent watchers:"
  list_projects || fail "No plists found in ~/Library/LaunchAgents/com.qa-agent-watcher.*"
  exit 0
fi

INTERVAL=$(resolve_interval "$INTERVAL_ARG")

if [ -n "$PROJECT" ]; then
  PLIST_PATH="$HOME/Library/LaunchAgents/com.qa-agent-watcher.${PROJECT}.plist"
  if [ ! -f "$PLIST_PATH" ]; then
    {
      echo "Plist not found: $PLIST_PATH"
      echo ""
      echo "Available projects:"
      list_projects
    } >&2
    exit 1
  fi
  PLISTS=("$PLIST_PATH")
else
  shopt -s nullglob
  PLISTS=("$HOME/Library/LaunchAgents/com.qa-agent-watcher."*.plist)
  shopt -u nullglob
  if [ ${#PLISTS[@]} -eq 0 ]; then
    fail "No plists found in ~/Library/LaunchAgents/com.qa-agent-watcher.*"
  fi
fi

for PLIST in "${PLISTS[@]}"; do
  LABEL=$(/usr/libexec/PlistBuddy -c "Print Label" "$PLIST" 2>/dev/null || basename "$PLIST" .plist)
  OLD=$(/usr/libexec/PlistBuddy -c "Print StartInterval" "$PLIST" 2>/dev/null || echo "unknown")

  info "Updating $LABEL: ${OLD}s → ${INTERVAL}s"
  /usr/libexec/PlistBuddy -c "Set :StartInterval $INTERVAL" "$PLIST"

  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"

  ok "$LABEL now runs every ${INTERVAL}s"
done

# QA Agent Watcher — Setup Instructions

## Prerequisites

On the host machine, ensure the following are installed and authenticated:

```bash
# Cursor Agent CLI
agent login

# GitHub CLI (authenticated)
gh auth status

# Required tools
which agent gh jq git
```

## 1. Move the script

```bash
mkdir -p ~/scripts
cp qa-agent-watcher.sh ~/scripts/qa-agent-watcher.sh
chmod +x ~/scripts/qa-agent-watcher.sh
```

## 2. Create the launchd plist

Create a file at `~/Library/LaunchAgents/com.qa-agent-watcher.myproject.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.qa-agent-watcher.myproject</string>

    <key>ProgramArguments</key>
    <array>
        <string>/Users/yourname/scripts/qa-agent-watcher.sh</string>
        <string>/Users/yourname/Developer/MyProject</string>
    </array>

    <key>StartInterval</key>
    <integer>600</integer>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>/Users/yourname</string>
        <key>AGENT_MODEL</key>
        <string>composer-2.5-fast</string>
        <key>PATH</key>
        <string>/Users/yourname/.local/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>

    <key>StandardOutPath</key>
    <string>/Users/yourname/logs/qa-agent-watcher-myproject.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/yourname/logs/qa-agent-watcher-myproject.log</string>

    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

## 3. Create the log directory

```bash
mkdir -p ~/logs
```

## 4. Load the agent

```bash
launchctl load ~/Library/LaunchAgents/com.qa-agent-watcher.myproject.plist
```

## 5. Verify it's running

```bash
launchctl list | grep qa-agent-watcher
```

## Managing the agent

```bash
# Stop it
launchctl unload ~/Library/LaunchAgents/com.qa-agent-watcher.myproject.plist

# Start it again
launchctl load ~/Library/LaunchAgents/com.qa-agent-watcher.myproject.plist

# View logs
tail -f ~/logs/qa-agent-watcher-myproject.log
```

## Adding another repo

1. Create a new plist with a different label and workspace path:

```bash
cp ~/Library/LaunchAgents/com.qa-agent-watcher.myproject.plist \
   ~/Library/LaunchAgents/com.qa-agent-watcher.otherproject.plist
```

2. Edit the new plist — change:
   - `Label` → `com.qa-agent-watcher.otherproject`
   - The workspace path argument → `/path/to/other/repo`
   - Log file paths → `qa-agent-watcher-otherproject.log`

3. Load it:

```bash
launchctl load ~/Library/LaunchAgents/com.qa-agent-watcher.otherproject.plist
```

Each repo runs independently with its own lockfile, log, and polling cycle.

## GitHub labels to create

Ensure these labels exist in your repo:

```bash
gh label create "ready-for-agent" --color "0E8A16" --description "Issue is ready for the agent to pick up" --repo owner/repo
gh label create "agent-in-progress" --color "FBCA04" --description "Agent is currently working on this" --repo owner/repo
gh label create "agent-pr-created" --color "1D76DB" --description "Agent has created a PR for this fix" --repo owner/repo
gh label create "agent-failed" --color "D93F0B" --description "Agent could not resolve this issue" --repo owner/repo
```

## Workflow

1. QA raises an issue and adds labels: `qa-verified` + `ready-for-agent`
2. The watcher picks it up (within ~10 minutes), removes `ready-for-agent`, adds `agent-in-progress`
3. Agent fixes the bug using TDD, creates a branch and PR
4. Issue gets `agent-pr-created` label and a comment linking the PR
5. You review and merge the PR next morning — merging auto-closes the issue via `Fixes #N`

If the agent fails, the issue gets `agent-failed` + a comment explaining why. You handle it manually.

#!/usr/bin/env bash
set -euo pipefail

# spawn-worker.sh - Spawn a Claude worker in a new Zellij tab
#
# Called by the orchestrator Claude instance to delegate work to sub-repos.
# The worker gets its own tab, runs in the sub-repo's directory, and receives
# all yx instructions inline -- no CLAUDE.md needed in the sub-repo.
#
# Usage:
#   spawn-worker.sh --cwd <dir> --name <tab-name> "<prompt>"
#   spawn-worker.sh --cwd ./api --name "api-auth" "Work on auth/api/* tasks..."
#
# Options:
#   --cwd <dir>       Working directory for the worker (required)
#   --name <name>     Zellij tab name (required)
#   --yak-path <dir>  Path to .yaks directory (default: $PWD/.yaks)

YAK_PATH="${YAK_PATH:-$PWD/.yaks}"
CWD=""
TAB_NAME=""
PROMPT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cwd)      CWD="$2";      shift 2 ;;
        --name)     TAB_NAME="$2";  shift 2 ;;
        --yak-path) YAK_PATH="$2"; shift 2 ;;
        *)
            if [[ -z "$PROMPT" ]]; then
                PROMPT="$1"
            else
                PROMPT="$PROMPT $1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$CWD" || -z "$TAB_NAME" || -z "$PROMPT" ]]; then
    echo "Usage: spawn-worker.sh --cwd <dir> --name <tab-name> \"<prompt>\"" >&2
    exit 1
fi

# Resolve to absolute path
CWD="$(cd "$CWD" && pwd)"

# Build the inline system prompt that teaches the worker about yx.
# This is the key design choice: sub-repos have NO CLAUDE.md about orchestration.
# Everything the worker needs to know comes in this prompt.
WORKER_PROMPT="$(cat <<PROMPT_EOF
${PROMPT}

---
TASK TRACKER (yx)

You have access to a task tracker called yx. The task state lives in ${YAK_PATH}.

Commands:
  yx ls                     Show all tasks and their states
  yx context <name>         Read the context/requirements for a task
  yx done <name>            Mark a task as complete
  yx state <name> wip       Mark a task as in-progress

Workflow:
1. Run 'yx ls' to see available tasks
2. Pick a task, read its context with 'yx context <name>'
3. Set it to wip: 'yx state <name> wip'
4. Do the work
5. When done: 'yx done <name>'
6. If blocked, write notes: echo "blocked: <reason>" > ${YAK_PATH}/<name>/agent-status

Focus on the tasks assigned to you. Do not modify tasks outside your scope.
PROMPT_EOF
)"

# Spawn the worker in a new Zellij tab
zellij action new-tab --name "$TAB_NAME" --cwd "$CWD" -- \
    claude --print "$WORKER_PROMPT"

echo "Spawned worker '${TAB_NAME}' in ${CWD}"

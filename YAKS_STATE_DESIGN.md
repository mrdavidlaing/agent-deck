# Using Yaks for Agent Deck State Management

How [mattwynne/yaks](https://github.com/mattwynne/yaks) (`yx`) could replace
SQLite as the persistence layer for Agent Deck on Zellij.

---

## Why Yaks Fits

Yaks is a DAG-based task manager that stores hierarchical items as a directory
tree (`.yaks/`), event-sourced to git refs (`refs/notes/yaks`). Three
properties make it a natural fit for Agent Deck's state:

1. **Hierarchical paths** -- Yaks uses `/`-delimited paths (`work/frontend`,
   `work/backend`) with automatic parent creation. This directly maps to
   Agent Deck's group/session hierarchy.

2. **Custom fields** -- Beyond the built-in `state` and `context.md`, each
   yak supports arbitrary named files. Session metadata (tool, command,
   project path, etc.) maps to custom fields.

3. **Git-native sync** -- State synchronizes across machines via hidden git
   refs, not by committing files to the repo's main branch. This gives Agent
   Deck team collaboration for free -- share session layouts and plans
   across developers without polluting the working tree.

---

## What Yaks Replaces

| Current (SQLite)                   | Yaks Equivalent                           |
|------------------------------------|-------------------------------------------|
| `instances` table (sessions)       | Child yaks with custom fields             |
| `groups` table (hierarchy)         | Parent yaks (directory nesting)           |
| `metadata` table                   | Not needed (Yaks manages its own schema)  |
| `instance_heartbeats` table        | Not needed (Zellij manages single session)|
| JSON session file backup           | Not needed (`.yaks/` is the source)       |

## What Yaks Does NOT Replace

| Concern                            | Why Not                                   |
|------------------------------------|-------------------------------------------|
| `config.toml` (user preferences)   | Config ≠ state. Keep as-is.               |
| Runtime state (pane IDs, caches)   | Ephemeral. In-memory in the Zellij plugin.|
| MCP definitions                    | Config concern, stays in `config.toml`.   |
| Notification manager               | Runtime concern, stays in plugin memory.  |

---

## State Mapping

### Directory Structure

```
.yaks/
├── work/                               # Group
│   ├── state                           # "wip" (auto: a child is active)
│   ├── context.md                      # Group description / notes
│   ├── default-path                    # Custom field: default project directory
│   ├── expanded                        # Custom field: "true" / "false" (UI state)
│   │
│   ├── frontend/                       # Session
│   │   ├── state                       # "wip" (active) / "todo" (stopped) / "done" (archived)
│   │   ├── context.md                  # Latest prompt, session notes
│   │   ├── agent-status                # "running" | "waiting" | "idle" | "error" | "starting"
│   │   ├── tool                        # "claude"
│   │   ├── command                     # "claude --resume abc123"
│   │   ├── project-path                # "/home/user/frontend"
│   │   ├── order                       # "1" (sort position within group)
│   │   ├── wrapper                     # (optional) "direnv exec . {command}"
│   │   ├── tool-data.json              # Tool-specific blob (session IDs, model, etc.)
│   │   ├── mcp-names                   # "exa-search,filesystem" (loaded MCPs)
│   │   ├── worktree-path               # (optional) "/home/user/frontend-wt"
│   │   ├── worktree-repo               # (optional) "/home/user/frontend"
│   │   ├── worktree-branch             # (optional) "feature/xyz"
│   │   └── parent-session              # (optional) "work/frontend" (for sub-sessions)
│   │
│   └── backend/                        # Another session
│       ├── state
│       ├── context.md
│       ├── agent-status
│       ├── tool                        # "gemini"
│       ├── command
│       ├── project-path
│       ├── order
│       └── tool-data.json
│
├── experiments/                        # Another group
│   ├── state
│   ├── context.md
│   ├── expanded
│   │
│   └── llm-comparison/                 # Session
│       ├── state
│       ├── context.md
│       ├── agent-status
│       ├── tool
│       └── ...
│
└── my-sessions/                        # Default group
    ├── state
    └── context.md
```

### State Mapping: Yaks States → Agent Deck Statuses

Yaks enforces exactly three states: `todo`, `wip`, `done`. Agent Deck needs
five: `running`, `waiting`, `idle`, `error`, `starting`. The mapping uses
Yaks states for lifecycle and a custom `agent-status` field for detail:

| Agent Deck Status | Yaks `state` | `agent-status` field | Meaning                        |
|-------------------|-------------|----------------------|--------------------------------|
| Starting          | `wip`       | `starting`           | Pane created, tool loading     |
| Running           | `wip`       | `running`            | Tool actively processing       |
| Waiting           | `wip`       | `waiting`            | Tool waiting for user input    |
| Idle              | `todo`      | `idle`               | Session exists, not started    |
| Error             | `todo`      | `error`              | Session broken / pane gone     |
| Archived          | `done`      | --                   | Session complete, kept in log  |

This preserves Yaks' parent auto-propagation: when any session is `wip`,
its group automatically becomes `wip` too. A `yx ls` tree view immediately
shows which groups have active sessions.

### The `tool-data.json` Custom Field

Tool-specific metadata goes in a single JSON file per session, mirroring
the current SQLite `tool_data` column:

```json
{
  "claude_session_id": "abc123",
  "claude_detected_at": 1707700000,
  "gemini_session_id": null,
  "gemini_model": "gemini-2.5-pro",
  "gemini_yolo_mode": true,
  "opencode_session_id": null,
  "codex_session_id": null,
  "latest_prompt": "Fix the authentication bug in login.ts",
  "tool_options": { "model": "opus" }
}
```

### The `context.md` Field

Yaks' built-in context field serves double duty:

1. **For groups**: Free-form description of the project or workstream.
2. **For sessions**: The latest prompt, session notes, or a summary of
   what the agent is working on. This content is visible via `yx ls`
   and in the Zellij plugin's preview panel.

```markdown
## Frontend Session

Working on the authentication flow refactor.

### Latest Prompt
Fix the login redirect bug where users get sent to /dashboard
before the token is validated.

### Notes
- Started from branch `fix/auth-redirect`
- Using worktree at `/home/user/frontend-wt`
```

---

## Interaction Patterns

### From the Zellij Plugin (WASM)

Yaks is not WASM-compatible (depends on `git2`/`libc`), so the plugin
interacts through two channels:

#### 1. Read: Direct Filesystem Access (Fast Path)

The Zellij plugin reads `.yaks/` files directly via the WASI `/host`
mount. This is synchronous, fast, and requires no process spawn:

```rust
fn load_sessions(&mut self) {
    // Read the .yaks directory structure
    let entries = scan_host_folder(".yaks");
    // Parse each session's custom fields
    for entry in entries {
        if is_session_dir(&entry) {
            let state = read_file(&format!(".yaks/{}/state", entry));
            let tool = read_file(&format!(".yaks/{}/tool", entry));
            let status = read_file(&format!(".yaks/{}/agent-status", entry));
            let project = read_file(&format!(".yaks/{}/project-path", entry));
            // ...
            self.sessions.push(Session { /* ... */ });
        }
    }
}
```

#### 2. Write: `yx` CLI via `run_command()` (Event-Sourced Path)

Mutations go through the `yx` binary to maintain the event log and
git-ref source of truth:

```rust
fn create_session(&self, group: &str, name: &str, tool: &str, project: &str) {
    // Create the yak
    run_command(
        &["yx", "add", &format!("{}/{}", group, name)],
        BTreeMap::new(),
        project_cwd,
        BTreeMap::from([("op".into(), "create_session".into())]),
    );
    // Set custom fields
    run_command(
        &["yx", "field", &format!("{}/{}", group, name), "tool", "--write"],
        // stdin will contain the tool value
        // ...
    );
}

fn archive_session(&self, path: &str) {
    run_command(&["yx", "done", path], /* ... */);
}

fn delete_session(&self, path: &str) {
    run_command(&["yx", "rm", path], /* ... */);
}

fn move_session(&self, from: &str, to_group: &str) {
    run_command(&["yx", "mv", from, &format!("{}/{}", to_group, leaf(from))], /* ... */);
}
```

#### 3. Watch: Filesystem Monitoring for External Changes

The plugin watches `.yaks/` for changes made externally (e.g., `yx sync`
in another terminal, or a teammate pushing changes):

```rust
fn load(&mut self, _config: BTreeMap<String, String>) {
    watch_filesystem(".yaks");
    subscribe(&[EventType::FileSystemUpdate, EventType::FileSystemCreate,
                EventType::FileSystemDelete]);
}

fn update(&mut self, event: Event) -> bool {
    match event {
        Event::FileSystemUpdate(paths) | Event::FileSystemCreate(paths) => {
            if paths.iter().any(|p| p.starts_with(".yaks/")) {
                self.reload_sessions();
                true // re-render
            } else { false }
        }
        Event::FileSystemDelete(paths) => {
            // Session or group deleted externally
            self.reload_sessions();
            true
        }
        _ => false
    }
}
```

### From the CLI (Companion Binary or Direct `yx`)

Users and scripts interact with session state using plain `yx` commands:

```bash
# See all sessions grouped hierarchically
yx ls

# Output:
# ○ my-sessions
# ● work
#   ● frontend [wip]
#   ● backend [wip]
#   ○ docs [todo]
# ○ experiments
#   ✓ llm-comparison [done]

# Create a new session
yx add work/api-gateway
yx field work/api-gateway tool --write <<< "claude"
yx field work/api-gateway project-path --write <<< "/home/user/api"
yx field work/api-gateway command --write <<< "claude"

# Archive a completed session
yx done work/docs

# Share session layout with the team
yx sync

# See who changed what
yx log
```

### From CI/Scripts (Automation)

Because state is plain files, shell scripts work naturally:

```bash
#!/bin/bash
# Start all "todo" sessions in the "work" group
for session in .yaks/work/*/; do
    state=$(cat "$session/state")
    if [ "$state" = "todo" ]; then
        tool=$(cat "$session/tool")
        path=$(cat "$session/project-path")
        echo "Starting $session with $tool in $path"
        # Signal the Zellij plugin to start this session
        zellij pipe --plugin agent-deck-manager -- \
            start "$(basename $session)"
    fi
done
```

---

## Team Collaboration (The Killer Feature)

Yaks' git sync gives Agent Deck a capability it doesn't have today:
**shared session plans**.

### Workflow

```
Developer A                          Developer B
─────────────                        ─────────────
yx add work/frontend                     │
yx add work/backend                      │
yx add work/api                          │
yx sync  ──────────────────────────►  yx sync
                                      # Sees all 3 sessions
                                      yx state work/frontend wip
                                      # "I'll take frontend"
                                      yx sync  ──────────────►  yx sync
# Sees frontend is wip                  │
# (someone's on it)                     │
yx state work/backend wip                │
# "I'll take backend"                   │
```

### What Syncs vs What Doesn't

| Syncs (via `refs/notes/yaks`)     | Stays Local (runtime only)              |
|-----------------------------------|-----------------------------------------|
| Session names and hierarchy       | Zellij pane IDs                         |
| Group structure                   | Agent status polling caches             |
| Tool type and command             | Notification manager state              |
| Project paths                     | Last-accessed timestamps                |
| Context/notes                     | MCP runtime connections                 |
| Worktree configuration            | Plugin UI state (scroll position, etc.) |
| Session state (todo/wip/done)     |                                         |
| Tool-specific session IDs         |                                         |

The `agent-status` field (running/waiting/idle) is inherently local -- it
reflects the live state of a pane that only exists on one machine. The Yaks
`state` (todo/wip/done) is the shareable lifecycle: "this session exists and
someone is working on it."

---

## Runtime-Only State

Some Agent Deck state is ephemeral and should NOT go into Yaks:

```rust
struct RuntimeState {
    // Zellij pane tracking (local to this Zellij instance)
    pane_ids: HashMap<String, u32>,        // session_path → pane_id

    // Status detection cache (rebuilt from scrollback polling)
    last_status: HashMap<String, Status>,  // session_path → detected status
    last_poll: HashMap<String, Instant>,   // session_path → last poll time

    // Notification manager (derived from status)
    notifications: Vec<NotificationEntry>, // waiting sessions, ordered

    // UI state
    selected_index: usize,
    scroll_offset: usize,
    search_query: String,
    dialog_state: Option<DialogState>,

    // Polling optimization
    idle_check_cache: HashMap<String, Instant>,
    activity_cache: HashMap<String, i64>,
}
```

This state lives in the plugin's WASM memory. On plugin restart, pane IDs
are recovered from `PaneUpdate` events, and statuses are re-detected from
scrollback.

---

## Status Detection Flow

The status watcher worker updates both Yaks state and runtime state:

```
┌──────────┐    poll     ┌──────────────┐   scrollback    ┌───────────┐
│  Timer   │───────────►│ StatusWatcher │──────────────►  │ Agent     │
│ (2s)     │            │ (WASM worker) │   patterns      │ Panes     │
└──────────┘            └───────┬───────┘                 └───────────┘
                                │
                    ┌───────────┴───────────┐
                    │                       │
              ▼ runtime update        ▼ persistent update
        ┌──────────────┐         ┌──────────────┐
        │ Plugin Memory│         │ .yaks/ files  │
        │ (pane_ids,   │         │ (agent-status,│
        │  last_status)│         │  state)       │
        └──────────────┘         └──────────────┘
                                        │
                                  ▼ (periodic)
                               ┌──────────┐
                               │ yx sync  │
                               │ (git)    │
                               └──────────┘
```

The worker writes `agent-status` directly to `.yaks/` files (fast path,
no CLI spawn), and only calls `yx state` when the lifecycle state changes
(todo ↔ wip ↔ done) to maintain the event log.

---

## Migration From SQLite

### Data Migration Script

```bash
#!/bin/bash
# Migrate Agent Deck SQLite state to Yaks format

DB="$HOME/.agent-deck/profiles/default/state.db"

# Export groups
sqlite3 "$DB" "SELECT path, name, expanded, sort_order, default_path FROM groups" | \
while IFS='|' read -r path name expanded order default_path; do
    yx add "$path" 2>/dev/null || true
    echo "$expanded" > ".yaks/$path/expanded"
    echo "$order" > ".yaks/$path/order"
    [ -n "$default_path" ] && echo "$default_path" > ".yaks/$path/default-path"
done

# Export sessions
sqlite3 "$DB" "SELECT id, title, project_path, group_path, sort_order, command, \
    wrapper, tool, status, tool_data FROM instances" | \
while IFS='|' read -r id title project group order cmd wrapper tool status data; do
    session_path="$group/$title"
    yx add "$session_path"

    echo "$tool" > ".yaks/$session_path/tool"
    echo "$cmd" > ".yaks/$session_path/command"
    echo "$project" > ".yaks/$session_path/project-path"
    echo "$order" > ".yaks/$session_path/order"
    [ -n "$wrapper" ] && echo "$wrapper" > ".yaks/$session_path/wrapper"
    [ -n "$data" ] && echo "$data" > ".yaks/$session_path/tool-data.json"
    echo "$id" > ".yaks/$session_path/original-id"

    # Map status
    case "$status" in
        running|waiting|starting) yx state "$session_path" wip ;;
        idle|error)               ;; # default is "todo"
    esac
    echo "$status" > ".yaks/$session_path/agent-status"
done
```

---

## Trade-Offs

### Gains

| Gain                           | Impact                                          |
|--------------------------------|-------------------------------------------------|
| **Team sync**                  | Share session plans across developers via git    |
| **Human-readable state**       | `.yaks/` is inspectable, scriptable, `cat`-able  |
| **Event history**              | `yx log` shows who changed what when             |
| **No database dependency**     | Eliminates SQLite, WAL mode, busy timeouts       |
| **CLI composability**          | Standard Unix tools work on the state files      |
| **Conflict resolution**        | Yaks handles merge at the yak level              |
| **Discoverable state**         | `yx ls` in any terminal shows session layout     |

### Costs

| Cost                           | Mitigation                                      |
|--------------------------------|-------------------------------------------------|
| **3 states vs 5**              | `agent-status` custom field for detail           |
| **No SQL queries**             | Directory scanning + in-memory filtering         |
| **Not WASM-native**            | Read files directly, `run_command()` for writes  |
| **Async writes**               | `run_command()` results arrive via callback      |
| **No concurrent write safety** | Plugin is single-threaded; git handles the rest  |
| **No transactions**            | Acceptable: operations are small & independent   |
| **Git repo required**          | Agent Deck is dev-focused; git is always present  |
| **Extra binary**               | `yx` must be installed alongside Zellij          |
| **Leaf-only move/delete**      | Must remove sessions before removing groups      |

### Net Assessment

The team sync capability alone justifies the architectural shift. The
filesystem projection means state is no longer locked inside a binary
database format. The 3-state limitation is real but manageable with custom
fields. The git dependency is a non-issue for the target audience
(developers managing AI coding agents).

---

## Updated Component Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Zellij Session                           │
│                                                                 │
│  ┌──────────────┐  ┌──────────────────────────────────────────┐ │
│  │  agent-deck  │  │              Agent Panes                 │ │
│  │   manager    │  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ │ │
│  │   (plugin)   │  │  │ Claude   │ │ Gemini   │ │ Codex    │ │ │
│  │              │──┤  │ session  │ │ session  │ │ session  │ │ │
│  │  Reads:      │  │  │ (pane)   │ │ (pane)   │ │ (pane)   │ │ │
│  │  .yaks/*     │  │  └──────────┘ └──────────┘ └──────────┘ │ │
│  │              │  └──────────────────────────────────────────┘ │
│  │  Writes:     │                                               │
│  │  yx add/done │     ┌──────────────────────────────────┐      │
│  │  yx mv/rm    │     │         .yaks/ directory         │      │
│  │              │────►│  (filesystem projection of state)│      │
│  │  Watches:    │     │                                  │◄──── git sync
│  │  .yaks/*     │◄────│  work/frontend/state             │      │
│  └──────────────┘     │  work/frontend/tool              │      │
│                       │  work/frontend/agent-status      │      │
│  ┌─────────────────┐  │  work/backend/state              │      │
│  │ agent-deck-bar  │  │  experiments/llm-test/state      │      │
│  │ (status bar)    │  └──────────────────────────────────┘      │
│  └─────────────────┘                    │                       │
│                              ┌──────────┴──────────┐            │
│  ┌─────────────────┐         │   refs/notes/yaks   │            │
│  │  config.toml    │         │   (git event store)  │            │
│  │  (unchanged)    │         └─────────────────────┘            │
│  └─────────────────┘                                            │
└─────────────────────────────────────────────────────────────────┘
```

---

## Yaks Feature Requests

To make this integration smoother, these Yaks enhancements would help:

1. **`yx field --batch`** -- Set multiple custom fields in one command to
   reduce process spawns when creating a session (currently one `yx field`
   call per field).

2. **`yx ls --format json`** -- Machine-readable output for the plugin to
   parse instead of scanning the directory tree.

3. **`yx add --field key=value`** -- Set custom fields at creation time
   instead of requiring separate `yx field` calls.

4. **`yx watch`** -- A long-running process that emits events on state
   changes, as an alternative to filesystem polling.

5. **Custom state values** -- Allow states beyond `todo/wip/done` (or at
   least a `--custom-states` flag) so `agent-status` can be a first-class
   state rather than a custom field.

6. **Non-git mode** -- Allow Yaks to work without a git repo for cases
   where sessions are managed in a non-repo directory (fallback to
   filesystem-only, no event sourcing).

# Agent Deck on Zellij: Architecture Design

How Agent Deck's functionality could be reimplemented as Zellij configuration
and plugins, replacing tmux as the underlying multiplexer.

---

## Executive Summary

Agent Deck's core value -- managing multiple AI coding agent sessions with
status detection, grouping, notifications, and MCP integration -- maps
surprisingly well onto Zellij's plugin system. The WASM plugin API provides
pane scrollback reading, programmatic pane creation, keystroke injection,
persistent storage, HTTP requests, file watching, and timer-based polling.
These capabilities cover ~90% of what Agent Deck needs. The remaining ~10%
(SQLite, Unix socket MCP pooling, raw network access) requires architectural
adaptation rather than compromise.

**Proposed architecture**: 3 plugins + 1 layout + 1 status bar configuration.

---

## Component Map

```
┌─────────────────────────────────────────────────────────────────┐
│                        Zellij Session                           │
│                                                                 │
│  ┌──────────────┐  ┌──────────────────────────────────────────┐ │
│  │  agent-deck  │  │              Agent Panes                 │ │
│  │   manager    │  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ │ │
│  │   (plugin)   │  │  │ Claude   │ │ Gemini   │ │ Codex    │ │ │
│  │              │  │  │ session  │ │ session  │ │ session  │ │ │
│  │  - Tree UI   │  │  │ (pane)   │ │ (pane)   │ │ (pane)   │ │ │
│  │  - Preview   │  │  └──────────┘ └──────────┘ └──────────┘ │ │
│  │  - Dialogs   │  │  ┌──────────┐ ┌──────────┐              │ │
│  │  - Search    │  │  │ Aider    │ │ Custom   │              │ │
│  │              │  │  │ session  │ │ tool     │              │ │
│  │  Workers:    │  │  │ (pane)   │ │ (pane)   │              │ │
│  │  - watcher   │  │  └──────────┘ └──────────┘              │ │
│  │  - mcp_mgr   │  └──────────────────────────────────────────┘ │
│  └──────────────┘                                               │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────────┐│
│  │  agent-deck-bar (status bar plugin)                         ││
│  │  ⚡ [1] frontend [2] api [3] backend  │ 3● 1◐ 2○  │ v0.13 ││
│  └──────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

---

## Plugin 1: `agent-deck-manager` (Main Plugin)

The primary UI surface. Renders in a fixed-width side pane (or floating pane
toggled by keybinding). Manages all session state and user interaction.

### Responsibilities

| Feature | Zellij API Used |
|---|---|
| Session list (tree view) | `render()` with ANSI output |
| Preview panel | `render()` second region |
| Create session | `open_command_pane()` with tool command |
| Delete session | `close_pane_with_id()` + state cleanup |
| Attach to session | `focus_pane_with_id()` |
| Send message | `write_to_pane_id(bytes, pane_id)` |
| Restart session | `close_pane_with_id()` then `open_command_pane()` |
| Fork session | Tool-specific: `run_command()` to invoke fork logic |
| Search/filter | Internal fuzzy match on session metadata |
| Keybindings | `Event::Key` handling in `update()` |
| Session groups | Tabs as top-level groups, in-plugin state for nesting |

### State Management

Since WASM plugins cannot use SQLite, state persists as JSON files in the
`/cache` directory (survives across Zellij sessions):

```
/cache/
├── sessions.json        # All session metadata
├── groups.json          # Group hierarchy and expansion state
├── config.json          # Plugin configuration (migrated from TOML)
└── mcp_state.json       # MCP attachment state per session
```

The `/cache` directory is shared across all instances of the same plugin,
providing the same cross-session persistence that Agent Deck's SQLite database
provides today.

### Session-to-Pane Mapping

Each AI agent session maps to a Zellij **command pane**. The plugin tracks
the mapping:

```rust
struct Session {
    id: String,
    pane_id: Option<u32>,       // Zellij pane ID (None if stopped)
    title: String,
    group: String,
    tool: String,
    command: Vec<String>,
    status: Status,
    // ... same fields as current Instance
}
```

When creating a session:

```rust
// Plugin creates a command pane for the AI tool
open_command_pane_floating(CommandToRun {
    path: "/usr/bin/claude".into(),
    args: vec!["--resume".into(), session_id.clone()],
    cwd: Some(project_path.clone()),
}, FloatingPaneCoordinates { /* hidden initially */ });
```

The `CommandPaneOpened` event returns the `pane_id`, which the plugin stores
in its session state. The pane can be hidden (`hide_pane_with_id`) when not
attached and shown (`show_pane_with_id` + `focus_pane_with_id`) when the
user selects it.

### UI Rendering

The plugin renders its TUI using ANSI escape codes in `render()`. Zellij
provides the pane dimensions (`rows`, `cols`). The same responsive layout
logic applies:

```rust
fn render(&mut self, rows: usize, cols: usize) {
    if cols < 50 {
        self.render_list_only(rows, cols);
    } else if cols < 80 {
        self.render_stacked(rows, cols);
    } else {
        self.render_dual_panel(rows, cols);
    }
}
```

Zellij's built-in DCS components can supplement this:
- **Nested lists** for the session tree (groups with expand/collapse)
- **Ribbons** for tab-like mode indicators

For more sophisticated rendering, the plugin can use a Rust TUI library
like `ratatui` compiled to WASM, which outputs ANSI sequences.

### Dialogs and Overlays

Floating panes serve as dialogs. When the user presses `n` (new session):

```rust
// Open a plugin instance configured for "new session" mode
open_floating_plugin_pane(
    PluginUrl::new("file:agent-deck-manager.wasm"),
    FloatingPaneCoordinates { width: 60, height: 20, .. },
    context: { "mode": "new_session_dialog" },
);
```

Alternatively, dialogs render inline within the plugin pane itself (simpler,
avoids spawning additional plugin instances).

### Background Workers

Two WASM workers handle async tasks without blocking the render loop:

#### Worker 1: `status_watcher`

Polls pane scrollback for status detection:

```rust
struct StatusWatcher;
register_worker!(StatusWatcher, status_watcher);

impl ZellijWorker for StatusWatcher {
    fn on_message(&self, message: String, payload: String) {
        match message.as_str() {
            "poll" => {
                // For each tracked pane, read scrollback
                // Parse tool-specific patterns
                // Post status updates back to plugin
                post_message_to_plugin(PluginMessage {
                    name: "status_update".into(),
                    payload: serde_json::to_string(&updates).unwrap(),
                    ..Default::default()
                });
            }
            _ => {}
        }
    }
}
```

The main plugin sets a timer to trigger polling:

```rust
fn load(&mut self, _config: BTreeMap<String, String>) {
    subscribe(&[EventType::Timer, EventType::PaneUpdate, ...]);
    set_timeout(2.0); // 2-second tick, same as current Agent Deck
}

fn update(&mut self, event: Event) -> bool {
    match event {
        Event::Timer(_) => {
            post_message_to("status_watcher", "poll", "");
            set_timeout(2.0); // Re-arm timer
            false
        }
        Event::CustomMessage(src, msg) if src == "status_watcher" => {
            self.apply_status_updates(&msg);
            true // re-render
        }
        _ => false
    }
}
```

#### Worker 2: `mcp_manager`

Handles MCP lifecycle via `run_command()`:

```rust
struct McpManager;
register_worker!(McpManager, mcp_manager);

impl ZellijWorker for McpManager {
    fn on_message(&self, message: String, payload: String) {
        match message.as_str() {
            "start_mcp" => {
                // Launch MCP server process
                run_command_with_env_variables_and_cwd(
                    &["npx", "-y", "exa-mcp-server"],
                    env_vars,
                    cwd,
                    BTreeMap::from([("mcp_name".into(), name.clone())]),
                );
            }
            "stop_mcp" => { /* kill process */ }
            _ => {}
        }
    }
}
```

---

## Plugin 2: `agent-deck-bar` (Status Bar)

A thin status bar plugin replacing the default `zellij:status-bar`. Renders
the notification bar showing waiting sessions and session counts.

### Rendering

```rust
fn render(&mut self, rows: usize, cols: usize) {
    // Left: waiting session notifications
    // "⚡ [1] frontend [2] api [3] backend"
    let notifications = self.format_notifications();

    // Right: session status counts
    // "3● 1◐ 2○ | v0.13.0"
    let counts = self.format_counts();

    let space = cols - visible_width(&notifications) - visible_width(&counts);
    print!("{}{:>width$}{}", notifications, "", counts, width = space);
}
```

### Communication with Manager Plugin

The status bar receives updates via Zellij's pipe system:

```rust
fn pipe(&mut self, pipe_message: PipeMessage) -> bool {
    match pipe_message.name.as_str() {
        "session_status" => {
            self.sessions = serde_json::from_str(&pipe_message.payload).unwrap();
            true // re-render
        }
        "notification" => {
            self.notifications = serde_json::from_str(&pipe_message.payload).unwrap();
            true
        }
        _ => false
    }
}
```

The manager plugin sends updates whenever session state changes:

```rust
pipe_message_to_plugin(
    MessageToPlugin {
        plugin_url: "file:agent-deck-bar.wasm",
        plugin_config: Default::default(),
        message_name: "session_status",
        message_payload: serde_json::to_string(&self.sessions).unwrap(),
        ..Default::default()
    }
);
```

---

## Plugin 3: `agent-deck-conductor` (Optional)

A headless plugin (hidden pane, `size=0` or background) that implements
the conductor/orchestrator pattern. Monitors session statuses and can
auto-respond or escalate.

### Design

```rust
fn update(&mut self, event: Event) -> bool {
    match event {
        Event::Timer(_) => {
            // Check for sessions needing attention
            for session in &self.watched_sessions {
                if session.status == Status::Waiting {
                    self.evaluate_and_respond(session);
                }
            }
            set_timeout(5.0);
            false
        }
        Event::WebRequestResult(status, headers, body, context) => {
            // Handle Telegram API responses (for mobile bridge)
            self.handle_telegram_response(status, body, context);
            false
        }
        _ => false
    }
}

fn evaluate_and_respond(&self, session: &Session) {
    // Read scrollback to understand what the agent is asking
    // If confident, send response via write_to_pane_id()
    // If uncertain, notify user via Telegram (web_request to Telegram API)
}
```

The Telegram bridge becomes a direct HTTP integration rather than a
separate Python daemon, since `web_request()` can call the Telegram Bot API
directly.

---

## Layout: `agent-deck.kdl`

The default layout positions the manager plugin, a content area for agent
panes, and the custom status bar:

```kdl
layout {
    default_tab_template {
        // Top: tab bar
        pane size=1 borderless=true {
            plugin location="zellij:tab-bar"
        }

        // Main content
        pane split_direction="vertical" {
            // Left sidebar: agent-deck manager
            pane size="25%" borderless=true {
                plugin location="file:~/.config/zellij/plugins/agent-deck-manager.wasm" {
                    // Plugin config passed to load()
                    config_path "~/.agent-deck/config.toml"
                    theme "dark"
                }
            }

            // Right: agent panes appear here
            // The plugin creates command panes in this area
            pane name="agents" focus=true
        }

        // Bottom: custom status bar
        pane size=1 borderless=true {
            plugin location="file:~/.config/zellij/plugins/agent-deck-bar.wasm"
        }
    }

    // Groups map to tabs
    tab name="my-sessions" focus=true
    tab name="work"
    tab name="experiments"

    // Swap layouts for different arrangements
    swap_tiled_layout name="stacked" {
        tab {
            pane split_direction="horizontal" {
                pane size="40%" borderless=true {
                    plugin location="file:agent-deck-manager.wasm"
                }
                pane name="agents"
            }
        }
    }
}
```

### Groups as Tabs

Zellij tabs naturally map to Agent Deck's top-level groups. Nested groups
(e.g., `work/frontend`, `work/backend`) remain managed within the plugin's
internal state. The plugin can create new tabs dynamically:

```rust
// When user creates a new top-level group
new_tabs_with_layout(&format!(r#"
    layout {{
        tab name="{group_name}" {{
            pane split_direction="vertical" {{
                pane size="25%" borderless=true {{
                    plugin location="file:agent-deck-manager.wasm"
                }}
                pane name="agents" focus=true
            }}
        }}
    }}
"#));
```

---

## Keybindings: `config.kdl`

Global keybindings to toggle the manager and navigate sessions:

```kdl
keybinds {
    shared_except "locked" {
        // Toggle manager sidebar
        bind "Alt a" {
            MessagePlugin "file:agent-deck-manager.wasm" {
                name "toggle_visibility"
            };
        }

        // Quick-jump to waiting sessions (like Ctrl+b 1-6 in tmux)
        bind "Alt 1" {
            MessagePlugin "file:agent-deck-manager.wasm" {
                name "jump_to_waiting"
                payload "1"
            };
        }
        bind "Alt 2" {
            MessagePlugin "file:agent-deck-manager.wasm" {
                name "jump_to_waiting"
                payload "2"
            };
        }
        // ... Alt 3-6

        // New session
        bind "Alt n" {
            MessagePlugin "file:agent-deck-manager.wasm" {
                name "new_session"
            };
        }

        // Search sessions
        bind "Alt /" {
            MessagePlugin "file:agent-deck-manager.wasm" {
                name "search"
            };
        }

        // Focus manager panel
        bind "Alt h" {
            MessagePlugin "file:agent-deck-manager.wasm" {
                name "focus_manager"
            };
        }
    }
}
```

---

## Feature-by-Feature Mapping

### Status Detection

| Current (tmux) | Zellij Equivalent |
|---|---|
| `tmux capture-pane` | `get_pane_scrollback()` via worker |
| Poll at 2s interval | `set_timeout(2.0)` + `Event::Timer` |
| JSONL tail-reading | Read scrollback, parse from end |
| Pattern matching (regex) | Same Rust regex crate in WASM |
| Status cache (5s TTL) | In-memory `HashMap` in plugin state |

**Key difference**: `get_pane_scrollback()` returns the full scrollback
buffer, not just the last N lines. The worker would need to track
a cursor position and only process new content since last poll.

### MCP Integration

| Current (tmux) | Zellij Equivalent |
|---|---|
| Stdio transport | `run_command()` to spawn MCP process |
| Socket pooling | HTTP-based pooling via `web_request()` |
| `.mcp.json` reading | `scan_host_folder()` + file I/O on `/host` |
| Per-session attach | Modify config files, restart pane |

**Adaptation**: The Unix socket pool (`mcppool`) cannot be directly
replicated since WASM plugins lack raw socket access. Two alternatives:

1. **HTTP proxy**: MCP servers expose HTTP endpoints. The plugin uses
   `web_request()` to communicate. An external helper binary (launched via
   `run_command()`) manages the MCP process pool and exposes an HTTP API.

2. **Config-file injection**: Write MCP configuration to `.mcp.json`
   files in the project directory before starting each session pane.
   The AI tool reads its own config on startup. This is simpler and
   matches how users configure MCPs manually.

Option 2 is recommended for simplicity. The plugin writes the appropriate
config files and then starts the command pane:

```rust
fn attach_mcp(&self, session: &Session, mcp_name: &str) {
    // Read current .mcp.json for the session's project path
    let mcp_config = self.read_mcp_config(&session.project_path);

    // Add the MCP server definition
    mcp_config.servers.insert(mcp_name, self.mcp_definitions[mcp_name].clone());

    // Write back
    self.write_mcp_config(&session.project_path, &mcp_config);

    // Restart the session pane to pick up new MCPs
    self.restart_session(session);
}
```

### Git Worktree

| Current | Zellij Equivalent |
|---|---|
| `git worktree add` | `run_command(&["git", "worktree", "add", ...])` |
| `git worktree remove` | `run_command(&["git", "worktree", "remove", ...])` |
| Branch validation | `run_command(&["git", "check-ref-format", ...])` |
| Repo detection | `run_command(&["git", "rev-parse", "--git-dir"])` |

All git operations use `run_command()` with results arriving via
`RunCommandResult` events. This is asynchronous but functionally identical.

### Persistence

| Current | Zellij Equivalent |
|---|---|
| SQLite + WAL | JSON files in `/cache` |
| `statedb.StateDB` | `serde_json` + `std::fs` |
| Primary election | Zellij manages single-session; not needed |
| Schema migrations | JSON versioning field + migration logic |

**Trade-off**: JSON lacks SQLite's concurrent-write safety, but Zellij
plugins run single-threaded per instance, and only one manager plugin
instance exists per session. The `/cache` directory provides persistence
across Zellij restarts.

For robustness, writes use the atomic rename pattern:
```rust
fn save_state(&self) {
    let tmp = "/cache/sessions.json.tmp";
    let target = "/cache/sessions.json";
    std::fs::write(tmp, serde_json::to_string_pretty(&self.sessions)?)?;
    std::fs::rename(tmp, target)?;
}
```

### Session Forking

```rust
fn fork_session(&mut self, source: &Session, new_title: &str) {
    match source.tool.as_str() {
        "claude" => {
            // Claude fork: create new session with --resume pointing to source
            let mut new_session = source.clone();
            new_session.id = generate_id();
            new_session.title = new_title.into();
            new_session.command = vec![
                "claude".into(),
                "--resume".into(),
                source.claude_session_id.clone(),
            ];
            self.create_session_pane(&new_session);
        }
        "gemini" => {
            // Gemini: copy session directory, start with new copy
            run_command(&["cp", "-r", &source.session_dir(), &new_dir]);
            // Then open new pane with new session dir
        }
        _ => {
            // Generic: just create a new session in the same directory
            self.create_session_pane(&Session {
                title: new_title.into(),
                project_path: source.project_path.clone(),
                tool: source.tool.clone(),
                ..Default::default()
            });
        }
    }
}
```

### Notifications

The current tmux status bar notifications translate directly to the
`agent-deck-bar` plugin:

| Current | Zellij Equivalent |
|---|---|
| Tmux status-right | `agent-deck-bar` plugin pane |
| `Ctrl+b 1-6` jump | `Alt 1-6` keybindings via `MessagePlugin` |
| NotificationManager | In-plugin state, piped to bar |
| Max 6 slots | Same logic, rendered in bar plugin |

### Update Checking

```rust
fn check_for_updates(&self) {
    web_request(
        "https://api.github.com/repos/asheshgoplani/agent-deck/releases/latest",
        HttpVerb::Get,
        headers,
        vec![],
        BTreeMap::from([("purpose".into(), "update_check".into())]),
    );
}

// In update():
Event::WebRequestResult(200, _, body, ctx) if ctx["purpose"] == "update_check" => {
    let release: GitHubRelease = serde_json::from_slice(&body)?;
    if release.tag_name != self.version {
        self.update_available = Some(release.tag_name);
        // Notify status bar
        pipe_message_to_plugin(/* ... */);
    }
}
```

---

## What Gets Simpler

| Aspect | Why |
|---|---|
| **No tmux dependency** | Zellij is the multiplexer. No shelling out to `tmux` commands, no control pipe management, no tmux session naming conventions. |
| **No TUI framework** | No Bubble Tea dependency. Plugin renders directly via ANSI. Zellij handles terminal input, resize, focus. |
| **No primary election** | Zellij manages exactly one session. No SQLite heartbeat table or PID tracking needed. |
| **No process management** | Zellij manages pane processes. No `exec.Command` lifecycle, no signal handling, no orphan cleanup. |
| **Simpler notifications** | Direct pipe from manager to bar plugin. No tmux status-line scripting. |
| **Session resurrection** | Zellij has built-in session serialization. Layout and pane state survive crashes. |
| **Attach/detach** | `focus_pane_with_id()` replaces the tmux attach/detach dance. |

## What Gets Harder

| Aspect | Why |
|---|---|
| **MCP socket pooling** | No raw sockets in WASM. Must use HTTP proxy or config-file injection. |
| **Rich structured storage** | JSON files instead of SQLite. Lose query capabilities, concurrent write safety. |
| **Cross-session state** | Zellij sessions are isolated. Sharing state across Zellij sessions requires `/cache` files. |
| **CLI commands** | Current `agent-deck add`, `agent-deck list` etc. would need a companion CLI binary that communicates with the plugin via `zellij pipe`. |
| **Plugin development** | Rust + WASM toolchain is heavier than pure Go. Compile-test cycle is slower. |
| **Raw terminal control** | Plugins render to their own pane only. Cannot overlay UI on top of agent panes (no true modal dialogs spanning the whole terminal). |

---

## Development Plan

### Phase 1: Core Manager Plugin

1. Session CRUD (create/delete/rename command panes)
2. Tree-view UI with group hierarchy
3. Status detection via scrollback polling
4. JSON persistence in `/cache`
5. Keybinding integration

### Phase 2: Status Bar + Notifications

1. Custom bar plugin with session counts
2. Pipe-based communication from manager
3. Waiting session indicators
4. Jump-to-session keybindings

### Phase 3: Tool Integration

1. Claude Code: session ID detection, fork, resume
2. Gemini CLI: model detection, YOLO mode
3. OpenCode, Codex, Aider: status patterns
4. MCP config-file injection
5. Git worktree via `run_command()`

### Phase 4: Advanced Features

1. Conductor plugin for orchestration
2. Telegram bridge via `web_request()`
3. Global search across conversations
4. Update checking
5. CLI companion binary (communicates via `zellij pipe`)

### Phase 5: Polish

1. Swap layouts for responsive design
2. Theme integration with Zellij themes
3. Session serialization (survive Zellij restarts)
4. Configuration migration from TOML to KDL plugin config

---

## File Structure

```
agent-deck-zellij/
├── Cargo.toml                    # Workspace
├── plugins/
│   ├── manager/
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── main.rs           # Plugin entry, event loop
│   │       ├── state.rs          # Session/group state management
│   │       ├── ui/
│   │       │   ├── mod.rs
│   │       │   ├── tree.rs       # Session tree rendering
│   │       │   ├── preview.rs    # Preview panel rendering
│   │       │   ├── dialog.rs     # Inline dialog rendering
│   │       │   └── search.rs     # Fuzzy search UI
│   │       ├── detection/
│   │       │   ├── mod.rs
│   │       │   ├── claude.rs     # Claude status patterns
│   │       │   ├── gemini.rs     # Gemini status patterns
│   │       │   └── generic.rs    # Generic tool patterns
│   │       ├── workers/
│   │       │   ├── watcher.rs    # Status polling worker
│   │       │   └── mcp.rs        # MCP management worker
│   │       ├── persistence.rs    # JSON file storage
│   │       └── config.rs         # Configuration parsing
│   ├── bar/
│   │   ├── Cargo.toml
│   │   └── src/
│   │       └── main.rs           # Status bar plugin
│   └── conductor/
│       ├── Cargo.toml
│       └── src/
│           └── main.rs           # Orchestrator plugin
├── layouts/
│   └── agent-deck.kdl            # Default layout
├── config/
│   └── agent-deck-keys.kdl       # Keybinding fragment
└── cli/
    ├── Cargo.toml
    └── src/
        └── main.rs               # Companion CLI (zellij pipe bridge)
```

---

## Summary

Zellij's plugin system is mature enough to host Agent Deck's core
functionality. The key APIs -- `get_pane_scrollback()`, `open_command_pane()`,
`write_to_pane_id()`, `web_request()`, `run_command()`, timer events, pipe
messaging, and `/cache` persistence -- cover the essential building blocks.

The main architectural shifts are:
- **tmux commands** become **Zellij plugin API calls** (cleaner, type-safe)
- **SQLite** becomes **JSON files** (simpler, sufficient for the data volume)
- **Bubble Tea TUI** becomes **ANSI rendering in a plugin pane** (native to Zellij)
- **MCP socket pool** becomes **HTTP proxy or config injection** (trade-off)
- **CLI commands** route through **`zellij pipe`** to the plugin (new pattern)

The result would be a tighter integration with the multiplexer, eliminating
the tmux dependency and the standalone binary architecture in favor of a
native Zellij experience.

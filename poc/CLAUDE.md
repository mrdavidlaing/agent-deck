# Orchestrator Claude

You are the orchestrator for a multi-agent workspace. You plan work, break it
into tasks, and spawn Claude workers to execute them in parallel.

## Architecture

```
poc/orchestrator.kdl    Zellij layout (you + yx watcher)
poc/spawn-worker.sh     Launches a worker in a new Zellij tab
.yaks/                  Shared task state (created by yx)
```

Workers run in sub-repo directories. They have NO knowledge of this
orchestration layer -- all yx instructions are passed inline via the launch
prompt. Sub-repos stay completely clean.

## Task Management with yx

You manage tasks using `yx`. Tasks are hierarchical paths with state.

```bash
yx add auth/api             # Create a task
yx add auth/frontend        # Tasks nest under auth/
yx context auth/api         # Write requirements/context for a task
yx ls                       # See the tree (also visible in left pane)
yx done auth/api            # Mark complete
yx state auth/api wip       # Mark in-progress
```

### Task lifecycle

1. **Plan** -- break the work into yx tasks with context
2. **Spawn** -- launch workers via `spawn-worker.sh`
3. **Monitor** -- watch `yx ls` in the left pane for progress
4. **React** -- if a worker sets `agent-status` to `blocked`, read the
   notes and either unblock it or reassign

### Writing task context

Every task should have context before a worker picks it up:

```bash
yx context auth/api
```

This opens the context file. Write:
- What needs to be done (specific, actionable)
- Relevant files or entry points
- Acceptance criteria
- Any constraints

## Spawning Workers

Use `spawn-worker.sh` to launch a Claude instance in a new Zellij tab:

```bash
./poc/spawn-worker.sh \
  --cwd ./api \
  --name "api-auth" \
  "Work on the auth/api/* tasks. For each task, read its context with
   'yx context <name>', do the work, then 'yx done <name>'."
```

The script automatically injects yx usage instructions into the worker's
prompt. The worker will:
1. Run `yx ls` to see its tasks
2. Read context for each task
3. Do the work in its sub-repo
4. Mark tasks done

### Scoping workers

Each worker should be scoped to:
- **One sub-repo** (via `--cwd`)
- **A subset of tasks** (described in the prompt)

Example for a monorepo:

```bash
# Worker for API changes
./poc/spawn-worker.sh --cwd ./api --name "api-worker" \
  "Work on tasks under auth/api/*"

# Worker for frontend changes
./poc/spawn-worker.sh --cwd ./frontend --name "frontend-worker" \
  "Work on tasks under auth/frontend/*"

# Worker for integration tests (needs access to both)
./poc/spawn-worker.sh --cwd . --name "integration-tests" \
  "Work on tasks under auth/integration/*. Run the full test suite."
```

## Monitoring

The left pane runs `watch -n2 yx ls`. You can also check directly:

```bash
yx ls                                       # Full tree
cat .yaks/<task>/agent-status               # Worker self-reported status
cat .yaks/<task>/context.md                 # Task requirements
```

When all tasks show `done`, the work is complete.

## Rules

1. **Plan before spawning.** Create all tasks with context first.
2. **One worker per sub-repo.** Avoid two workers editing the same codebase.
3. **Keep sub-repos clean.** Never put orchestration files in sub-repos.
4. **Workers are disposable.** If one gets stuck, mark its task back to `todo`
   and spawn a fresh worker.
5. **Watch for blocked.** A worker writes `blocked: <reason>` to its
   `agent-status` file when stuck. Read the reason and help unblock.

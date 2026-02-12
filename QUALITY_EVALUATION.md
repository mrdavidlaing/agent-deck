# Codebase Quality Evaluation: Agent Deck

**Evaluated:** 2026-02-12
**Version:** 0.13.0
**Language:** Go 1.24.0

---

## Overall Rating: **B+** (Strong)

Agent Deck is a well-engineered Go project with professional practices, comprehensive
testing, and clear architecture. It demonstrates maturity and care in most areas, with
a few notable areas for improvement.

---

## Dimension Scores

| Dimension                  | Score  | Weight | Notes                                        |
|----------------------------|--------|--------|----------------------------------------------|
| Architecture & Design      | 8/10   | 20%    | Clean layers; some god-files                 |
| Code Quality & Consistency | 8.5/10 | 20%    | Well-formatted, consistent conventions       |
| Testing                    | 8/10   | 15%    | Strong coverage; some superficial UI tests   |
| Error Handling             | 8.5/10 | 10%    | Comprehensive; proper wrapping               |
| Security                   | 9/10   | 10%    | crypto/rand IDs, no injection risks          |
| Documentation              | 8/10   | 10%    | Good user docs; complex internals sparse     |
| Build & DevEx              | 9/10   | 10%    | Excellent Makefile, hooks, release pipeline  |
| Dependencies               | 9/10   | 5%     | Current, well-chosen, minimal                |

**Weighted Score: 8.4/10**

---

## 1. Architecture & Design (8/10)

### Strengths

- **Clean layered architecture** with well-defined package boundaries:
  - `cmd/agent-deck/` - CLI entry point and command routing
  - `internal/session/` - Core business logic
  - `internal/ui/` - TUI presentation (Bubble Tea)
  - `internal/tmux/` - Terminal multiplexer integration
  - `internal/statedb/` - SQLite persistence
  - `internal/mcppool/` - MCP socket pooling

- **No circular dependencies** detected across the package graph.

- **Good design patterns** employed:
  - Event-driven TUI via Bubble Tea message passing
  - Status detection via pattern matching (extensible, tool-agnostic)
  - MCP socket pooling for resource efficiency (85-90% memory reduction)
  - Conductor architecture for agent orchestration

- **Thread-safety** properly handled with WAL-mode SQLite, sync.Mutex where
  needed, and channel-based communication in mcppool.

### Weaknesses

- **God-files**: `home.go` (7,920 lines) and `instance.go` (3,321 lines) are
  excessively large. These concentrate too much responsibility into single files
  and harm navigability.

- **Limited interface usage**: Most code uses concrete types. Adding interfaces
  at key boundaries (e.g., session storage, tmux operations) would improve
  testability and enable cleaner mocking.

---

## 2. Code Quality & Consistency (8.5/10)

### Strengths

- **Enforced formatting**: `gofmt` checked in pre-commit hooks via lefthook.
- **Linting**: `golangci-lint` runs on pre-push and in local CI.
- **Consistent naming**: Functions follow clear prefixes (`Get*`, `Create*`,
  `Handle*`, `Is*`). Types use CamelCase. Constants use descriptive names.
- **Well-defined constants**: Magic numbers are extracted into named constants
  with comments explaining rationale (timing intervals, layout breakpoints,
  spacing grid).
- **Structured logging**: Uses `log/slog` with component-scoped loggers
  (`logging.ForComponent()`).

### Weaknesses

- **No `.golangci.yml`**: Linter runs with default config. Explicit
  configuration would document which rules the project follows.
- Only **7 TODO/FIXME** markers in the codebase -- these are well-managed and
  reflect awareness of known issues.
- **21 files use `interface{}`**: Mostly for JSON/TOML marshaling and MCP
  config, which is reasonable in Go, but some could benefit from typed
  alternatives.

---

## 3. Testing (8/10)

### Metrics

| Metric              | Value    |
|---------------------|----------|
| Test files           | 67       |
| Lines of test code   | 23,926   |
| Test-to-code ratio   | 50.3%    |
| Test types           | Unit, integration, e2e |
| Race detector        | Enabled (`-race` flag) |
| Assertion library    | testify (assert/require) |

### Strengths

- **Excellent test-to-code ratio** (~50%) demonstrating significant investment
  in testing.
- **Multiple test levels**: Unit tests colocated with source, integration tests
  (`*_integration_test.go`), and e2e tests (`*_e2e_test.go`).
- **Proper test infrastructure**: `testmain_test.go` for environment setup,
  `t.TempDir()` for isolation, `t.Helper()` for readable failures, deferred
  cleanup patterns.
- **Race detector** enabled by default catches concurrency bugs.
- **Table-driven tests** in many packages follow Go best practices.
- **Test isolation**: `AGENTDECK_PROFILE=_test` prevents production data
  contamination.

### Weaknesses

- **UI tests are superficial**: Many UI component tests only verify that
  `View()` returns a non-empty string without validating content.
- **No coverage reporting**: No `coverprofile` generation or coverage thresholds
  in CI.
- **Limited mocking**: Tests tend to use real implementations, which is good for
  integration confidence but means some "unit" tests exercise more than their
  target.

---

## 4. Error Handling (8.5/10)

### Strengths

- **~2,143 `if err != nil` checks**: Consistent, idiomatic Go error handling
  throughout.
- **Error wrapping** with `fmt.Errorf("context: %w", err)` preserves error
  chains.
- **Graceful degradation**: Sensible fallbacks when features are unavailable
  (e.g., disabled logging writes to `io.Discard`).
- **Zero `panic()` calls** in production code.

### Weaknesses

- Some instances of `_ = err` swallowing errors silently where logging would be
  preferable.

---

## 5. Security (9/10)

### Strengths

- **Secure ID generation**: `crypto/rand.Read()` for session IDs -- no
  predictable identifiers.
- **No command injection**: All `exec.Command()` calls use separate argument
  slicing rather than shell string interpolation.
- **Input validation**: Branch names checked for `..`, `.lock`, leading/trailing
  spaces.
- **Path construction**: Consistent use of `filepath.Join()` preventing path
  traversal.
- **Parameterized queries**: SQLite via modernc.org uses proper parameterization.
- **No hardcoded credentials** found anywhere in the codebase.
- **CGO disabled**: Static binaries (`CGO_ENABLED=0`) reduce attack surface.

### Minor Observations

- Debug log file permissions not explicitly restricted (follows OS defaults).

---

## 6. Documentation (8/10)

### Strengths

- **README.md**: Feature overview, quick start, key shortcuts, FAQ.
- **CONTRIBUTING.md**: Development setup, code style guidelines, PR process.
- **CHANGELOG.md**: Detailed version history from 0.1.0 to 0.13.0.
- **Skills documentation**: CLI reference, config reference, TUI reference,
  troubleshooting guide.
- **Code comments**: Exported functions have proper doc comments. Constants
  include rationale.

### Weaknesses

- **Complex internal algorithms** (status detection engine, storage watching,
  MCP pool management) lack detailed inline documentation.
- Some test helpers could use more documentation for contributors.

---

## 7. Build & Developer Experience (9/10)

### Strengths

- **Comprehensive Makefile** with targets: build, test, lint, fmt, dev, ci,
  release-local, install, clean.
- **Pre-commit hooks** (lefthook): fast format + vet checks.
- **Pre-push hooks**: parallel lint, test (with race detector), and build.
- **Hot reload**: `make dev` uses `air` for rapid iteration.
- **Release pipeline**: GoReleaser with version validation against git tags,
  Homebrew tap, cross-platform builds (Linux/macOS, amd64/arm64).
- **Version embedding**: `git describe --tags` injected via `-ldflags`.
- **Multiple install methods**: Homebrew, shell script, go install, from source.

### Minor Gaps

- No explicit `.golangci.yml` configuration committed.
- No `.air.toml` committed (uses defaults).

---

## 8. Dependencies (9/10)

- **15 direct dependencies** -- lean and well-chosen.
- All from well-maintained, reputable sources (Charmbracelet, testify,
  modernc.org, golang.org/x).
- **Zero C dependencies** (pure Go SQLite via modernc.org).
- **Go 1.24.0**: Current version.
- Dependencies tracked with proper versions in `go.mod` and `go.sum`.

---

## Key Recommendations

1. **Break up god-files**: Split `home.go` (7,920 lines) and `instance.go`
   (3,321 lines) into focused sub-modules by responsibility.

2. **Add coverage reporting**: Generate `coverprofile` in CI and set minimum
   thresholds to prevent regression.

3. **Strengthen UI tests**: Move beyond "View() is non-empty" to asserting
   expected content, state transitions, and edge cases.

4. **Introduce key interfaces**: Define interfaces at package boundaries
   (session storage, tmux operations) to improve testability.

5. **Add `.golangci.yml`**: Document which linter rules the project enforces
   explicitly.

6. **Document complex algorithms**: Add explanatory comments to status
   detection, MCP pool management, and storage watching logic.

---

## Summary

Agent Deck is a **high-quality, production-ready** Go codebase that demonstrates
strong engineering practices. The 50% test-to-code ratio, enforced linting/formatting,
secure coding patterns, and comprehensive build pipeline place it well above average
for open-source Go projects. The main areas holding it back from an A rating are the
oversized files that concentrate too much responsibility and the absence of coverage
reporting. These are addressable and do not indicate fundamental design issues.

# Claude Usage & Quota CLI

Two lightweight macOS CLI tools for tracking Claude usage:

- **`claude-usage`** -- token usage & costs from local logs
- **`claude-quota`** -- live session/weekly quotas from API

## Requirements

- macOS 14+, Swift 6.0+

## Build & Install

```bash
make build              # compile both
make install            # /usr/local/bin (sudo)
make install-local      # ~/bin (no sudo)
```

## claude-usage

Scans `~/.config/claude/projects` and `~/.claude/projects` for JSONL logs.
Deduplicates streaming responses, calculates costs per model.

```bash
claude-usage                        # 30-day summary
claude-usage -d 7 --daily           # last 7 days, daily breakdown
claude-usage --daily --models       # per-model breakdown
claude-usage --json                 # JSON output
claude-usage --vertex-only          # only Vertex AI
claude-usage --exclude-vertex       # exclude Vertex AI
```

Override log path: `export CLAUDE_CONFIG_DIR="/custom/path"`

| Flag | Description |
|------|-------------|
| `--days, -d N` | Last N days (default: 30) |
| `--json` | JSON output |
| `--daily` | Daily breakdown |
| `--models` | Per-model breakdown |
| `--vertex-only` | Vertex AI only |
| `--exclude-vertex` | Exclude Vertex AI |

## claude-quota

Fetches live quota via Claude's OAuth API. Requires `claude /login`.

```bash
claude-quota                # quota summary with progress bars
claude-quota --used         # show percent used
claude-quota --json         # JSON output
claude-quota --no-bars      # hide progress bars
```

Shows session (5h), weekly (7d), model-specific (Opus/Sonnet), and extra usage windows.

```
Claude Quota Summary
==================================================

Session (5h): 45.3% remaining (resets in 2h 15m)
  [█████████████████████████████░░░░░░░░░░░] 45.3%

Weekly (7d): 78.2% remaining (resets in 3d 14h)
  [███████████████████████████████░░░░░░░░░] 78.2%
```

Auth (same as Claude Code / sketchybar helper):
1. Keychain service `Claude Code-credentials` via `security find-generic-password -w`
2. Else `~/.claude/.credentials.json`

Token fields: `claudeAiOauth.accessToken` or `access_token`.

## License

MIT

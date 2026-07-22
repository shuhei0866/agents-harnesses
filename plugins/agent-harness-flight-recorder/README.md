# Agent Harness Flight Recorder

Local, privacy-first lifecycle telemetry for Claude Code and Codex.

This first slice only observes work. It does not route models, score developers,
upload data, or call an evaluator model. The purpose is to create a trustworthy
`work episode` event stream before adding recommendations.

## What it records

The shared hook configuration observes four lifecycle events:

| Harness event | Canonical event |
|---|---|
| `SessionStart` | `session.started` |
| `UserPromptSubmit` | `turn.prompted` |
| `PostToolUse` | `tool.completed` |
| `Stop` | `turn.completed` |

Both harnesses write the same JSONL schema. The recorder uses Codex's
`PLUGIN_ROOT` environment variable to distinguish Codex from Claude Code;
payload fields such as `model` overlap and are never used as the discriminator.

## Privacy contract

The recorder is allowlist-based. Unknown input fields are discarded.

Stored:

- harness and lifecycle event names
- model, permission mode, and tool name when present
- a fixed allowlist of numeric duration, token, and cost metrics
- random event ID and timestamp
- truncated HMAC-SHA-256 identifiers for session, turn, and workspace correlation

Never stored by default:

- prompts or assistant messages
- commands, code, file contents, or tool output
- transcript contents or transcript paths
- raw session IDs, turn IDs, or workspace paths
- unknown future hook fields

The HMAC key is generated locally beside the event log with user-only
permissions, so low-entropy workspace paths cannot be checked against the log
without the installation-local key. The recorder never opens `transcript_path`;
it treats hook input as the only source and selects safe metadata from it.

## Failure behavior

Recording is fail-open. Empty input, malformed JSON, missing Python, an invalid
destination, or a write failure produces no hook decision and exits successfully.
The original Claude Code or Codex action continues.

Input is capped at 1 MiB; oversized hook payloads are skipped. Each event is
serialized before an advisory-locked `O_APPEND` write that handles short writes.
This keeps concurrent hook invocations from interleaving JSONL records on the
supported macOS/Linux development environments.

## Storage

Default:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/agent-harness-flight-recorder/events.jsonl
```

Override the file for testing or local policy:

```bash
export AGENT_FLIGHT_RECORDER_PATH=/path/to/events.jsonl
```

The correlation key defaults to `hash.key` beside that file. Its path can be
overridden with `AGENT_FLIGHT_RECORDER_KEY_PATH`; an externally managed secret
can instead be supplied through `AGENT_FLIGHT_RECORDER_HASH_KEY`.

New directories and files are created with user-only permissions where the
platform honors POSIX modes.

## Local development

Claude Code can load the plugin directly for one session:

```bash
claude --plugin-dir /absolute/path/to/plugins/agent-harness-flight-recorder
```

Codex loads this plugin from a configured marketplace. For hook development
without publishing a marketplace, use the same `hooks/hooks.json` definition
and replace `${CLAUDE_PLUGIN_ROOT}` with the plugin's absolute path in a local
`~/.codex/hooks.json` or trusted project `.codex/hooks.json`.

Run the contract tests:

```bash
bash plugins/agent-harness-flight-recorder/tests/test-record-event.sh
```

The tests exercise official-shape fixtures for both harnesses, privacy canaries,
fail-open behavior, optional fields, shared auto-detection, and 50 concurrent
writers. The stable event contract is in `schema/event-v1.schema.json`.

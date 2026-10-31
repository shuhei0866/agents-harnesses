# Security and privacy

## Supported boundary

Use this server only from trusted local MCP clients under one OS user.
The transport is stdio; the bridge does not expose an HTTP listener.
This is not a multi-user service. Possessing access to the state directory
allows reading and modifying every partner, prompt, response, and job.

The SQLite database and logs are plaintext, without TTL or encryption.
New state/workspace directories are created with mode 0700; server and worker
entrypoints set umask 0077. Existing directory permissions are not repaired.
OS permissions, backups and disk encryption remain the operator's responsibility.

## Provider execution

The worker resolves trusted `codex` / `claude` executables on PATH and sends
prompts on stdin, not shell-interpolated arguments. PATH, the environment,
package installation, and registry files must be trusted. The bridge is not
a sandbox for malicious CLI binaries or hostile local users.

Claude uses safe mode, no built-in tools, an empty strict MCP configuration,
and `dontAsk`. Codex uses `read-only` and `never`, omits user config, then
copies only the configured OpenAI model, reasoning effort, and credential-store
preference. The bridge does not disable admin-managed policies. Codex may still
read local files and run permitted read-only commands. A no-tools instruction
is guidance, not a technical guarantee for Codex.

An empty cwd avoids incidental project context; it does not isolate the home
directory. All model-bound text may be sent to the selected provider according
to the CLI's authentication and terms. No telemetry is added by the bridge.

## Data handling

The bridge stores full supplied messages and completed/provisional response
text. Errors and raw stderr can include provider content. Progress counters
store event timestamps/counts, phase and response length; thinking text and
signatures are not copied into those counters. CLI-native logs may retain
additional content independently.

Do not expose this server over a network, mount untrusted state, or publish
runtime directories. Use separate state directories and, when stronger
separation is needed, separate OS accounts/environments for unrelated contexts.

## Failure behavior

Requests are deduplicated within a named partner. This is not an exactly-once
guarantee at the provider: a process may disappear after the provider accepted
a request. Such stale jobs become `uncertain` and block new sends to that
partner. Inspect native history and use a new partner; do not edit the DB to
pretend the request never happened. Failed/interrupted/timed-out jobs are not
automatically replayed.

The timeout (5–600 seconds) bounds normal worker supervision; termination has
short SIGINT/SIGTERM/SIGKILL grace periods. It is not a provider billing ceiling.
Shutdown, disk exhaustion and hangs outside the supervised event loop remain
limitations of this alpha.

## Bounded dialogue

Starting a dialogue authorizes a sequence of model calls, up to its explicit
round and active-time limits. Both providers receive the topic and the partner's
completed replies. Use only material appropriate for that sharing scope.
Partner text is untrusted discussion material; it does not authorize tool use,
changed safety flags, more rounds, or a new budget.

Pause is a reply-boundary operation; stop requests interruption immediately.
Inspect status to confirm either. If a coordinator disappears, the child keeps
its persisted deadline. An uncertain child is not replayed. Native history
and prompt caching are separate: no cache hit or total billing ceiling is
promised. No new credential access or auth configuration is introduced.

Usage persistence keeps only numeric allowlisted fields and source labels.
It does not retain raw model-usage payloads, thinking text or pricing guesses.
The existing plaintext-state and trusted-local-user boundaries still apply.

## Scoped one-line carryovers

Carryovers are plaintext in the existing local registry. No new service,
credential, schedule, or background summarization is added. The host explicitly
selects a named partner or a dialogue series; dialogue continuations share notes
with both providers. The bridge does not match notes by topic or search other
conversations. These scope checks prevent accidental routing, not access by a
hostile user of the same local account.

Open notes remain until the host explicitly closes them. Reservation snapshots
are immutable; closure is not recall of a previously submitted prompt or deletion
from native history. A fragment may contain mistaken or adversarial text and is
labeled untrusted discussion material. It does not expand tool permissions.

## Reporting

Report vulnerabilities privately to the repository maintainer through an
available private contact/security channel. Public reports must contain only
synthetic reproductions; never attach a registry, stderr log, token or native
conversation. This project does not promise a response SLA.

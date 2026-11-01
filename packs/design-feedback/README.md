# Design feedback

A local, provider-independent feedback loop for UI work. The pack calls no model or network API. Its CLI is shared by Codex and Claude Code; the ordinary agent interprets the user's feedback during its existing turn.

- `UserPromptSubmit` captures relevant turns, binds already-presented artifact versions, and supplies the skill, canonical guidance pointer, scoped cases, and pending IDs.
- `Stop` registers local inline previews and requests at most one continuation to record or dismiss an unprocessed capture. `stop_hook_active` prevents loops.
- `SessionStart` reminds about pending captures in that session.
- The scheduled `sweep` refreshes the existing retrieval collector, reads its validated immutable snapshot through its lock, recovers new design-reaction candidates, and serially projects shareable cases into the configured Git owner.

Capture is not acceptance. Unknown project, missing historical artifact, unstated reason, candidate generalization, and explicit user judgment remain separate. Cases and captured evidence are immutable; corrections and exceptions use links. The local evidence store contains original text and artifact copies with private permissions. Git receives only deliberately shareable summaries and opaque evidence IDs/digests.

## Installation

Requires Python 3.9+ and Git. The optional scheduled worker uses macOS launchd. Choose an existing canonical guidance repository whose workflow explicitly permits direct main commits; automatic publishing refuses other workflows. Use a dedicated clean checkout owned by this writer, not a user's working tree.

```sh
python3 packs/design-feedback/install.py \
  --home "$HOME/.local/share/agents-harnesses/design-feedback" \
  --guidance-checkout /path/to/dedicated-guidance-checkout \
  --guideline-path docs/design-guidance.md \
  --case-dir docs/design-feedback/cases \
  --artifact-root /path/to/approved/previews
```

Without `--apply`, the installer prepares a private plan. After reviewing it, repeat with `--apply`; add `--start-worker` to load the five-minute launchd job. Optional `--retrieval-scripts`, `--retrieval-lab`, and `--retrieval-command` connect an existing Flight Recorder retrieval installation. Its original corpus, refresh rules, exclusions and locks are preserved. Without it, live-hook capture and queue delivery still work, and recovery reports `not_configured`.

Installation appends only this pack's handlers and short instruction pointers, preserves existing guards and configuration, and saves private backups. It never changes Codex hook trust, approval policy, sandbox settings, or model selection. Review/trust the new exact hook definitions through Codex `/hooks`, and verify in fresh native sessions. Configuration written to disk is not proof that a running client loaded it. Claude Code may require a new session after hook changes.

The installed skill documents recording and source verification. Useful commands:

```sh
design-feedback context --query 'compare items and inspect details' --cwd /path/to/project
design-feedback pending
design-feedback event EVENT_ID
design-feedback source EVENT_ID
design-feedback status
design-feedback sweep
```

`publish` uses a lock, rejects foreign dirty files/commits in its dedicated checkout, rebases only its own queue commits, pushes and checks remote ancestry before marking delivery. Errors retain the queue and are visible in status. The publisher edits only case files and its marked section of the canonical guidance document. Ordinary project-scoped feedback adds evidence, not global rules.

Recovery detects explicit design reactions since activation, not every possible design judgment. It does not infer project identity from the worker's cwd or attach current screenshots to historical feedback. Unassigned recovered candidates need source verification and `assign-project` before becoming accepted project cases. A degraded collector or unavailable snapshot is not complete collection. Review recovery/publish health separately from later design quality.

Run `python3 -m unittest discover -s packs/design-feedback/tests -v`. Tests use synthetic prompts, temporary state homes and local bare Git remotes; no global configuration, private evidence, or external publication is needed.

Hook contracts: [Codex hooks](https://learn.chatgpt.com/docs/hooks), [Claude Code hooks](https://code.claude.com/docs/en/hooks). Transcript file formats are not treated as stable APIs; recovery uses the existing normalized collector.

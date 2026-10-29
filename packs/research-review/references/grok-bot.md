# Grok Bot adapter

## Documented entry points

Checked 2026-10-29 against the official
[messaging](https://docs.x.ai/grok-bot/chat-and-collaboration),
[files](https://docs.x.ai/grok-bot/files-and-results) and
[skills/routines](https://docs.x.ai/grok-bot/skills-routines-and-automations) docs.
Recheck before relying on a changed interface; do not hardcode prices or limits.

- The desktop/mobile chat accepts messages and attachments and exposes actual
  Bot handoffs. Existing specialist Bots can collaborate asynchronously.
- An existing routine can expose a webhook URL and bearer key. A POST can include
  a JSON body. HTTP 200 means a run was accepted and started, **not completed**.
- All of a user's Bots share files, browser sessions and app logins on one cloud
  computer. Different Bot screens are not a credential-isolation boundary.

The generic model REST API, administration API and routine webhook are different
interfaces. This pack implements only the documented **existing routine webhook**;
it does not invent a general Bot chat API. It creates no routine or secret.

## Existing webhook

Use only a routine the user authorized for this research scope. Inspect its owner,
instruction and permitted tools in the app before first use: a POST body cannot
restrict a broadly configured routine. Never silently choose another endpoint.
Confirm that the request contains only material authorized for that service.

The configured routine must read the JSON `request` as this one-time task and
echo `task_id`/`request_id` (the same correlation ID) into its chat and returned
bundle. These body fields are this adapter's convention, not a vendor schema.
Use a task-specific output directory and coordinate access to shared files/apps;
the webhook does not solve cloud-computer collisions or serialize other routines.

Pass the existing URL and key as `GROK_BOT_WEBHOOK_URL` and
`GROK_BOT_WEBHOOK_KEY` from the caller's secret manager. Pin the separately
verified HTTPS scheme/host/port as `GROK_BOT_WEBHOOK_ORIGIN`; do not derive it from
an unverified URL just to satisfy the check. The script accepts HTTPS,
does not follow redirects, sends one POST and does not retry. Its output reports
`accepted`, `not_accepted`, `unknown` or `not_sent` and a task ID; it never reports
research completion. Unexpected 2xx/3xx and server errors are conservatively
classified as `unknown`; only 200 is accepted. Do not put secrets in a run bundle,
shell arguments or Git. A leaked URL/key is a capability to spend usage: pause the
routine through the supported UI, then use the provider's supported secret
replacement procedure before resuming. This adapter cannot revoke that key.

Before networking the CLI atomically creates `.grok-webhook-attempt.json` in the
run directory (task ID, timestamp and hashes only). It refuses another attempt
in that same directory, including after a crash. This is a local duplicate-attempt
guard, not evidence of delivery or a cross-machine exactly-once guarantee. Do not
delete it or copy the bundle elsewhere merely to retry an uncertain request.

For `unknown`, inspect the owning Bot's chat/run history for the task ID before any further
action. Do not resend because a local timeout expired. A matching chat receipt
and real artifacts are separate evidence. An idempotency field in the request
would not establish server-side deduplication, so none is assumed here.

Ask the routine owner to return `bundle.json`, `report.md` and any appendices as
one submission with the task ID. Download the actual files. Local and cloud paths
are different; do not tell a Bot to open a host-local path it cannot access.
Use `target`/`lint` on the received files. Missing artifacts are not reconstructible
from preview truncation. If a response says a required source or app is unavailable,
record the limitation instead of adding credentials, paid tools or permissions.

## GUI fallback

Use the session's supported computer-use tool. Do not inspect private app DBs,
extract session tokens, call undocumented app endpoints or launch a parallel
automation browser to work around a rejected route.

Before typing, ensure one operator owns the composer; a local lock does not stop
another agent or a human. Never overwrite an unexpected draft. Read the intended
Bot/chat, empty composer and task ID. Insert the exact prepared request, then
re-read the **full** composer and recipient immediately before sending in the
same interaction if possible. Compare exact content, not a matching prefix.
If content, focus or recipient changes, stop without sending or clearing it.
This reduces exposure; the app has no verified atomic compare-and-send operation,
so it cannot guarantee prevention of a last-instant race. If exclusive control
cannot be established, leave the prepared request for the user to send.

After sending, verify the actual transcript's recipient, task ID and content.
If receipt is uncertain, do not retry or cancel unrelated work. Preserve that
uncertainty and let the operator inspect it. Long handoffs should use the actual
file plus digest; if that is unavailable, number parts `n/N`, verify completeness
and request only missing parts, without inventing recipient replies.

Do not use public `@bot` posts as a private research transport. Do not create new
Bots, groups, routines, account links, permissions or paid APIs merely to run this
adapter. Those are separate setup changes when explicitly requested.

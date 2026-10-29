# Verification scope

Automated tests run without provider credentials using synthetic executables
named `codex` and `claude`, temporary state directories, and isolated config.

Coverage includes duplicate/concurrent sends, native ID consistency, persisted
history, stale workers, success/failure/timeout/interruption, progress privacy,
MCP reconnection, and a detached worker completing across a disconnected host.
The installed-wheel check runs the suite from outside the source tree.

Passing these tests verifies the bridge's control flow under modeled CLI
events. It does not prove live authentication, model availability, subscription
billing, every CLI version, or all OS cleanup behaviors.

CLI help inspection: Codex 0.164.0 and Claude Code 2.1.312.
The extracted package has not yet been tested against a real model provider.
Previously observed behavior of a local prototype is not an installed-package
acceptance test.

The release preparation scans source/distribution file lists for private
state and machine-specific material. Public examples and fixtures are synthetic.

## Extraction validation

On macOS with Python 3.13, all 18 tests passed from the source checkout and
again from an installed wheel outside the checkout. Both wheel and sdist
passed the distribution allowlists. Linux and Python 3.11 are included in the
CI configuration; see the repository's Actions checks for their latest results.

An optional live-provider smoke test was attempted through the existing
managed secret-boundary sandbox. macOS rejected sandbox initialization
(`sandbox_apply: Operation not permitted`) before any provider was invoked.
The protection was not weakened or bypassed. Live acceptance of this extracted
version remains open.

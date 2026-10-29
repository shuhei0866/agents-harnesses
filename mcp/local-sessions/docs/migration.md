# Existing local installations

This package never changes a running MCP configuration or migrates a registry
on installation. The default state path is outside the source/package tree.

For an existing installation, first inspect active jobs and dialogues through its normal
MCP tools. Keep its source, configuration, registry and CLI-native histories.
Do not relocate the SQLite file or workspaces while workers are active.
The registry includes absolute cwd paths; copying a database alone is not a
portable migration.

To adopt a tested package while retaining partners:

1. Stop sending new messages and stop active dialogues and wait for existing jobs to reach terminal
   states. Preserve a consistent registry backup and the CLI-native histories
   using the operator's existing backup process.
2. Install the package in a separate virtual environment.
3. Set `SESSION_BRIDGE_HOME` explicitly to the existing state directory.
   Retain its paths, permissions, authentication choices and outer sandbox.
4. Change the MCP command only after the operator approves the exact change.
   Reconnect both clients and verify list/history before a new message.
5. If needed, restore the previous MCP command. Do not delete state as rollback.

Version 0.2 adds dialogue and usage tables without rewriting existing sessions
or jobs. Older versions ignore those tables but cannot control dialogues; stop
all dialogues before switching back. A paused dialogue still has pending work
and is not a completed migration boundary. Omitting an explicit old state
path starts a new empty registry; it does not import or erase the old one.
Do not commit backups, logs or exported conversations to this repository.

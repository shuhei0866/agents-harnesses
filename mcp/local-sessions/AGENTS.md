# Local Session Bridge
This is a small, public-ready Python MCP server for continuing conversations with local coding CLIs.

- Keep bridge state, transcripts, credentials, machine paths, and real session IDs out of Git, packages, fixtures, issues, and CI logs.
- Use synthetic CLI fixtures for automated tests. Real provider runs consume account quota and require the operator's authorization.
- Preserve managed policies and provider restrictions. Do not remove safety flags to make an older CLI work.
- The supported trust boundary is a trusted local user. Do not describe stdio, an empty cwd, or read-only commands as a multi-user security boundary.
- Verify both source checkout and installed wheel behavior after packaging changes.
- Use feature branches and reviewable commits. Publication, deployment, and changes to an existing installation need explicit scope.

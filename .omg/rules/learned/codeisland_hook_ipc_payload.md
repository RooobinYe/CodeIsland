---
name: codeisland_hook_ipc_payload
description: Prevent upstream consumer crashes by responding with JSON before terminating large IPC socket payloads.
globs: ["HookServer.swift"]
---
# CodeIsland Hook IPC Payload Size Limits
- `maxPayloadSize` should be set to at least 10MB (`10_485_760`) to accommodate large file diffs from tools like Codex.
- Always send a well-formed JSON response (`{}` — the island never decides) to `codeisland-bridge` before explicitly dropping the `NWConnection` (`connection.cancel()`).

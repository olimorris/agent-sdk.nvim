# Handlers are split into events and requests

Some things a model or agent sends tell the plugin something. Others ask the plugin for something, and the reply can't continue until the plugin answers. A flat list of handlers hid that difference, so a plugin author couldn't tell which handlers they must answer.

Events sit at the top of `on`: `text`, `reasoning`, `usage`, `done`, `error`. Requests sit under `on.request`: `tool_call`, `permission`, and the reserved `read_file` and `write_file`. Every request is answered on the table it receives, with `respond` (and `fail` where failure is possible).

## Consequences

- A request handler that never answers leaves the reply hanging. Where the SDK can answer safely with no handler, it does: it fails a tool call and rejects a permission request
- New things an agent can ask for go under `on.request`, with the same `respond` shape

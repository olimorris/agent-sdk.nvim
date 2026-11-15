# One session API for HTTP adapters and ACP agents

An HTTP adapter and an ACP agent work very differently: one is a stateless request, the other a long-running process that keeps its own history and runs its own tools. The user picks the adapter, so a plugin can't know which it will get. Both are used through the same `sdk.session()` and `session:prompt()`, with the same handlers, and the SDK absorbs the differences.

Where the two can't be made the same, the SDK picks the behaviour that keeps a plugin written for one working on the other. The remaining differences are listed in one place, in `doc/INTEGRATING.md`.

## Consequences

- A field both sides emit has one name, whatever each spec calls it. A plugin reads `call.arguments` and `reply.usage.input_tokens` the same way on both
- Features one side can't support become no-ops on that side, not errors. `call.respond()` does nothing on ACP, and `session:set_messages()` returns `false, err` (see [0005](0005-the-sdk-owns-the-history.md))
- An ACP agent can't be given the plugin's tools, so that difference is permanent

# Streaming and non-streaming replies use the same handlers

A plugin author shouldn't maintain two kinds of code. `stream = false` delivers the same events to the same handlers, in one burst once the reply is complete. Where a provider supports only one mode, the SDK covers the other: it collects a stream into one reply, or sends a complete reply as one burst of events.

Every prompt ends with exactly one `done` or one `error`, in either mode. Stopping a reply ends it with an `error` whose `cancelled` is `true`.

## Considered options

- **`stream = false` returns the reply and skips the handlers:** rejected. A plugin would need a second code path, and a buffer that streams would need rewriting to work without streaming

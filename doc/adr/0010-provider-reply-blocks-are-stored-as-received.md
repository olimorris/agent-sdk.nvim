# A provider's reply blocks are stored as received and sent back unchanged

Superseded by [0014](0014-transports-and-adapters-are-ports-of-codecompanion.md).

Providers attach data to a reply that must come back untouched on the next request: Anthropic's thinking signatures, OpenAI's encrypted reasoning. Anthropic now rejects a conversation whose earlier thinking blocks were edited or reordered. The provider-neutral history can't represent these, so an adapter may attach its raw reply to the assistant message as `data`, and it sends that back as-is in place of rebuilding the message.

## Consequences

- `data` is opaque to the SDK and to plugins. Only the adapter that wrote it reads it, and it checks `data.provider` first
- A message without `data`, such as one a plugin wrote through `set_messages()`, is rebuilt from the neutral fields

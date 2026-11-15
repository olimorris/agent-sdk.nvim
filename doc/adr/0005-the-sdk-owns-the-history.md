# The SDK owns the history

On HTTP the SDK is the only owner of the conversation history. A plugin reads `session.messages` and replaces it only with `session:set_messages()`. The history is stored in CodeCompanion's provider-neutral message format and converted per adapter on every request, so a plugin never sees a provider's format.

On ACP the agent owns its history. `session.messages` is a read-only record of what the SDK saw, as in CodeCompanion, and is never sent back. `session:set_messages()` changes nothing and returns `false, err`.

## Considered options

- **The plugin owns the history and passes it with every prompt:** rejected. Every plugin would have to pair tool calls with results and keep reasoning signatures intact, and each would get it wrong differently
- **`set_messages()` raises on ACP:** rejected. A plugin tested only on HTTP would break the first time a user picked an agent. Returning `false, err` lets it carry on and still lets a careful plugin check

## Consequences

- A prompt that fails adds nothing to the history (see [0008](0008-a-failed-prompt-adds-nothing-to-the-history.md))
- A provider's reply blocks are stored as received (see [0010](0010-provider-reply-blocks-are-stored-as-received.md))

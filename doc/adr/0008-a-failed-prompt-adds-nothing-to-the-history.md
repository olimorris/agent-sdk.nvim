# A failed prompt adds nothing to the history

A prompt that errors or is stopped leaves the history exactly as it was, without the reply and without the prompt itself. The `error` event carries the prompt as `event.prompt`, so the plugin decides whether to send it again or hand it back to the user.

## Considered options

- **Keep the prompt in the history:** rejected. A retry would put the same user message in twice, and some providers reject two user messages in a row
- **Keep the partial reply:** rejected. A half-finished reply, possibly with unanswered tool calls, would be sent back to the model as if it were complete

## Consequences

- `done` always means a reply was added to the history, and `error` always means nothing was

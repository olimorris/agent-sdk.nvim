# A prompt isn't done while a tool call is unanswered

When a model asks for a tool, its reply is not finished: it is waiting on the plugin. So the plugin answers on the request with `call.respond(content)` or `call.fail(message)`. Once every call in a reply is answered, the SDK sends the results and the same prompt carries on. The plugin sees one `done`, with the whole answer, exactly as it does on an ACP agent that runs its own tools.

## Considered options

- **The plugin sends results as a new prompt** (`session:prompt({ { type = "tool_result", ... } })`): rejected. `done` would mean "the answer is finished" on ACP and "the model wants tool results" on HTTP. Every round would be a new task to track, `session:ask()` would return with no answer, and a plugin that forgot to send a result would leave a tool call in the history with no result

## Consequences

- The SDK sends follow-up requests itself. This is not an agent loop: the plugin decides what every tool does, and stops the model by closing the task
- The SDK pairs call ids, and the history only changes when the prompt finishes, so it never holds a tool call without its result
- With `stream = false`, a reply with a tool call arrives as one burst up to the call and another after it is answered
- `reply.usage` adds up every request the prompt made

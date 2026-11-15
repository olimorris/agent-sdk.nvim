# Integrating agent-sdk.nvim into a plugin

You're adding agent-sdk.nvim to a Neovim plugin so it can talk to LLMs and agents. The SDK is the connection layer: it owns adapters, credentials, history and the transport. The plugin owns everything else, including every buffer and window, the prompts it sends, and what it does with the replies.

Use only the API in the [Reference](#reference). When the plugin needs something the reference doesn't cover, stop and tell the user what's missing, rather than reaching into the SDK's internals.

## Steps

### 1. Map the conversations

A **conversation** is one session's worth of back-and-forth with a model: what starts it, where the reply is shown, what the user can do next, and what ends it. One float answering questions about a hunk is a conversation. A one-shot pass that parses a reply into data is another.

Read the plugin and list every feature that talks, or will talk, to a model. For each, write down its conversation:

- What starts it
- Where the reply goes, and whether it streams or must arrive whole (because the plugin parses it)
- Whether the user can ask a follow-up, or stop a reply
- What ends it

Done when every feature that talks to a model maps to a conversation with all four answered.

### 2. Add the user's config

Add one `adapter` option to the plugin's setup. It takes the adapter's name as a string, or a table with a name and a model:

```lua
require("your_plugin").setup({ adapter = "claude" })
require("your_plugin").setup({ adapter = { name = "claude", model = "claude-opus-5" } })
```

The name is the one the user gave the adapter in `agent_sdk.setup()`. API keys, URLs and adapter definitions live there, so the plugin's own config holds only the name and the model. If conversations need different adapters, give each its own option with the same shape.

In the plugin's README, show the user both forms and link to agent-sdk.nvim for setting up adapters.

Done when setup accepts both forms, and the plugin's config holds nothing about credentials or providers.

### 3. Start each conversation

When a conversation starts:

1. Resolve the adapter with `sdk.adapter(name)`. If it returns `nil, err`, show `err` with `vim.notify` at `ERROR` and stop
2. If the user set a model, check it with `adapter:has_model(model)` and warn if it returns `false`
3. Turn off features the adapter can't support, using `adapter.capabilities`
4. Start a session with `sdk.session()`, with the session's handlers in `on`

Resolve the adapter when the conversation starts rather than in the plugin's setup, as the user may call `agent_sdk.setup()` after the plugin's.

Every session needs `text`, `done` and `error` handlers. The `error` handler skips events where `event.cancelled` is `true`, because the plugin stopped that reply itself.

If the adapter can be ACP (any adapter can be, as the user picks it), the session also needs a **permission policy**: an `on.request.permission` handler that decides by `request.tool_call.kind`. Work out the policy from the conversation's purpose. A reviewer reads and searches, so it allows `read` and `search` and rejects everything else. Every path through the handler calls `request.respond()`.

Done when every conversation from step 1 starts this way, and every session has `text`, `done`, `error` and `request.permission` handlers.

### 4. Prompt

- Send prompts with `session:prompt()`, or `session:ask()` inside a `vim.async` task when the code reads better top to bottom
- Use `stream = false` for conversations that parse the reply
- Keep the task `session:prompt()` returns, and close it from the conversation's stop action
- Send one prompt at a time per session. Disable the plugin's "send" action until `done` or `error` arrives

Done when every conversation from step 1 sends its prompts this way, and every one the user can stop is wired to close the task.

### 5. Close each conversation

Call `session:close()` wherever a conversation ends: its window closes, its command finishes, or the plugin tears down.

Done when every `sdk.session()` call has a matching `session:close()` on every path that ends the conversation.

### 6. Test

Write tests with the test adapter, added through `agent_sdk.setup()` as a user would. For each conversation, cover:

- A reply that streams and ends in `done`
- A reply that ends in `error`
- For each permission policy, one permission request the policy allows and one it rejects, checked through `scripted.responses`

Done when the tests pass with no network access and no API keys set.

Tests should follow CodeCompanion's implementation, where actual output is captured and passed through the adapter.

## Reference

### Adapters

`sdk.adapter(name)` returns the user's adapter, or `nil, err`.

| Field | |
| --- | --- |
| `adapter.name` | The user's name for it |
| `adapter.type` | `"http"` or `"acp"` |
| `adapter.capabilities` | Read-only. `tools`, `vision`, `reasoning` (booleans) and `models` (a list) |
| `adapter:has_model(model)` | `false` only when the adapter knows its models and `model` isn't one of them |

`capabilities.models` is empty until the SDK knows the models: for an ACP agent, until a session has started; for Ollama, until the SDK has asked the server.

### Sessions

```lua
local session = sdk.session({
  adapter = adapter, -- from sdk.adapter()
  model = "claude-opus-5", -- optional, nil keeps the user's default
  system_prompt = "...", -- optional
  on = { ... }, -- handlers for every prompt in the session
})
```

`sdk.session()` returns straight away. Nothing is sent until the first prompt.

| Call | |
| --- | --- |
| `session:prompt(content, opts)` | Sends a prompt and returns a `vim.async` task. Closing the task stops the reply |
| `session:ask(content, opts)` | The same, inside a `vim.async` task. Returns `reply, err` |
| `session:close()` | Stops any reply in progress and ends the session. For ACP, stops the agent's process |
| `session.messages` | The history, read-only. On ACP, a record of what the SDK saw |
| `session:set_messages(messages)` | Replaces the history and returns `true`. On ACP, changes nothing and returns `false, err` |

`content` is a string, or a list of blocks like `{ type = "text", text = "..." }`.

`opts`:

- `stream`: `false` delivers every event in one burst once the reply is complete. A reply with a tool call arrives as one burst up to the tool call, and another once the call is answered. Defaults to `true`
- `on`: handlers for this prompt only. Each replaces the session's handler for the same event or request

### Events

Events tell the plugin something and ask nothing of it.

| Handler | Payload |
| --- | --- |
| `on.text` | `event.text`, a piece of the answer |
| `on.reasoning` | `event.text`, a piece of the reasoning |
| `on.usage` | Token counts: `input_tokens`, `output_tokens`, and any other counts the provider sends under its own names (on ACP, `cachedReadTokens`, `cachedWriteTokens`, `thoughtTokens`) |
| `on.tool_update` | `update.id`, `update.status` (`pending`, `in_progress`, `completed`, `failed`), `update.output`. On ACP, `update.rawOutput` instead of `output`, plus `title`, `kind`, `content`, `locations`, `rawInput` and `meta`. On HTTP, sent when the plugin answers the call |
| `on.done` | The reply: `reply.text`, `reply.reasoning`, `reply.tool_calls`, `reply.usage` |
| `on.error` | `event.message`, `event.cancelled`, `event.prompt` |

### Requests

Requests ask the plugin for something. The reply waits until the handler answers.

| Handler | Payload |
| --- | --- |
| `on.request.tool_call` | `call.id`, `call.name`, `call.arguments`, `call.needs_result`, `call.respond(content)`, `call.fail(message)`. On ACP, `call.name` is `nil` as ACP has no tool names and `call.rawInput` replaces `call.arguments`: use `call.title`, `call.kind`, `call.status`, and `call.meta` for the agent's own extras |
| `on.request.permission` | `request.tool_call`, `request.options` (each with `id`, `name`, `kind`), `request.respond(option_id)` |

```lua
on = {
  text = function(event) end,
  done = function(reply) end,
  error = function(event) end,
  request = {
    tool_call = function(call) end,
    permission = function(request) end,
  },
}
```

`on.request.read_file` and `on.request.write_file` are reserved for ACP agents and aren't built.

`tool_call.kind` and `option.kind` use ACP's values: tool kinds `read`, `edit`, `delete`, `move`, `search`, `execute`, `think`, `fetch`, `other`; option kinds `allow_once`, `allow_always`, `reject_once`, `reject_always`.

### Rules

- Handlers run on the main loop, so they can write to buffers and windows directly
- Every prompt ends with exactly one `done` or one `error`
- Stopping a reply ends the prompt with an `error` whose `cancelled` is `true`. On HTTP, nothing from the stopped reply is added to the history
- A prompt that ends in `error` adds nothing to the history, not even the prompt itself. `event.prompt` holds what was passed to `session:prompt()`, so the plugin can send it again or return it to the user
- Calling `session:prompt()` or `session:ask()` while a reply is in progress raises an error
- An `on.request.permission` handler must call `request.respond()`. The agent waits until it does. `request.respond(nil)` cancels
- Without an `on.request.permission` handler, the SDK picks the agent's reject option, or cancels the request when the agent offers none
- An `on.request.tool_call` handler must call `call.respond()` or `call.fail()` when `call.needs_result` is `true`. The prompt carries on once every call is answered, and ends in one `done`. Without one, the SDK fails every call
- The SDK closes every open session on `VimLeavePre`

### HTTP and ACP

The plugin's code is the same for both, except:

- An ACP agent keeps its own history. `session.messages` is a record of the prompts, text, reasoning and tool calls the SDK saw, and is never sent back to the agent. `session:set_messages()` changes nothing and returns `false, err`
- On ACP, `system_prompt` is added to the agent's own instructions. On HTTP, it is the whole system prompt
- On ACP, tool calls have `needs_result = false`: the agent runs the tool itself, and `call.respond()` and `call.fail()` do nothing. On HTTP, `needs_result` is `true` and the plugin owes a result. The API for giving the model the plugin's tool definitions isn't designed yet, so stop and ask the user if the plugin needs tools
- An ACP agent reads files, writes files and runs commands itself, behind permission requests. It can't do any of these through Neovim, so it doesn't see unsaved changes
- The SDK starts an ACP agent's process on the first prompt, so the first reply is slower
- If an ACP agent's process exits, the agent's history goes with it. The prompt in progress ends in an `error`, and so does every later prompt in that session. Start a new session to carry on

### Test adapter

```lua
local scripted = require("agent_sdk.test").adapter({
  type = "acp", -- optional, defaults to "http"
  replies = {
    -- one list of events per request, each ending in done or error
    -- a reply with a tool call is followed by a second request once the call is answered
    {
      { type = "text", text = "Hello" },
      { type = "done" },
    },
  },
})

require("agent_sdk").setup({ adapters = { scripted = scripted } })
```

A `permission_request` event in a script reaches the plugin's `on.request.permission` handler. It takes `tool_call` and `options` as in [Requests](#requests). `scripted.responses` lists the option ids the plugin's handlers responded with, in order.

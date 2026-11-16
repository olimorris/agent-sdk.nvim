# agent-sdk.nvim design

Every Neovim plugin that wants to talk to an LLM or an agent has to build its own HTTP adapters, ACP client and credential handling. Users then configure the same API keys and models once per plugin.

agent-sdk.nvim is a headless library that does this once. Users configure their adapters in one place, and any plugin built on the SDK can use them by name.

## Status

- Beta. Liable to break, and the README says so
- Built for Oli's plugins first, starting with [bottleneck.nvim](../bottleneck.nvim), then for other plugin authors
- Requires Neovim nightly (0.13-dev) because it is built on `vim.async`
- The Lua module is `agent_sdk`
- `README.md` holds a sketch of the API. `INTEGRATING.md` is the full reference, written for a plugin author to hand to their coding agent
- The reasons behind the decisions in this document are recorded in [adr/](adr/README.md)

## Relationship to CodeCompanion

- A new repo, started from CodeCompanion's adapter code. That layer has been stable for over a year
- CodeCompanion stays as it is until the SDK settles. It then adopts the SDK, with a shim for its existing adapters
- Plugins already reach into CodeCompanion's internals as an unofficial SDK (VectorCode, codecompanion-history and codecompanion-fast-apply use `codecompanion.http`; the `cc-adapter-*` plugins use `codecompanion.adapters`). The SDK gives them a supported API to move to

## The user

- Configures adapters, credentials and models once, in `setup({ adapters = ... })`
- Credentials work as in CodeCompanion: environment variables, `cmd:` for password managers, and functions
- Adds third-party adapters in their own setup (`adapters = { vertex = require("vertex-adapter") }`). A plugin never registers an adapter itself
- Extends a built-in adapter with `require("agent_sdk.adapters").extend(...)`, as in CodeCompanion. A string (`claude_code = "claude_code"`) uses a built-in adapter unchanged

## Plugins

- Refer to adapters by the name the user gave them. `sdk.adapter(name)` returns the adapter, or `nil, err` with an error the plugin can show the user
- Take the user's choice as one `adapter` option: a name, or `{ name = ..., model = ... }`
- May override the model for a session
- May read an adapter's `name`, `type` (`"http"` or `"acp"`) and capabilities (tools, vision, reasoning, models). Capabilities are read-only
- `capabilities.models` is empty until the SDK knows the models: for an ACP agent, until a session has started; for Ollama, until the SDK has asked the server
- `adapter:has_model(model)` returns `false` only when the adapter knows its models and `model` isn't one of them, so a plugin never warns about a model it can't check yet
- May deep copy an adapter's config and change the copy. They can never change the user's config

## Scope

The SDK is the connection layer only:

- No agent loop. Plugins decide what every tool call does and when to stop. The SDK only sends the plugin's results back
- No UI. Plugins own every buffer and window
- No file handlers for ACP agents. The SDK reserves the requests (`on.request.read_file`, `on.request.write_file`) but ships no implementation
- No terminals for ACP agents. An agent runs commands in its own shell, behind a permission request

## Sessions

Every adapter is used through a session and `session:prompt()`.

- `sdk.session({ adapter, model, system_prompt, on })` takes the adapter object, not its name, so a plugin can pass a modified deep copy
- `sdk.session()` returns straight away. Nothing is sent until the first prompt
- Handlers in `on` apply to every prompt in the session. Handlers passed to `session:prompt()` replace the session's handler for that event, for that prompt only
- A prompt is a string, or a list of content blocks (`{ type = "text", text = ... }`)
- `session:prompt()` returns a `vim.async` task. Closing it stops the reply
- One prompt at a time. Calling `session:prompt()` or `session:ask()` while a reply is in progress raises an error
- `session:close()` stops any reply in progress and ends the session

### HTTP

- The SDK is the only owner of the history
- The plugin sends prompts and tool results. The SDK adds the assistant's reply to the history when the request is done
- Plugins read `session.messages` and change it only with `session:set_messages(...)`
- History is stored in CodeCompanion's provider-neutral message format and converted per adapter on every request
- Reasoning is stored as CodeCompanion stores it, with provider data such as Anthropic's signature in `reasoning._data`, and adapters rebuild the provider's blocks from it
- Tool call ids must pair up within each request, as some adapters re-mint ids for historical tool calls

### ACP

- The agent owns its history. `session.messages` is a read-only record of what the SDK saw, as in CodeCompanion, and is never sent back to the agent
- `session:set_messages(...)` changes nothing and returns `false, err`. It doesn't raise, so a plugin that was only tested on HTTP keeps working on an agent
- One agent process per session, started on the first prompt. The SDK kills it when the session ends and on `VimLeavePre`
- `system_prompt` is added to the agent's own instructions. On HTTP, it is the whole system prompt
- An agent is never told the editor can read files, write files or run terminals. `on.request.read_file` and `on.request.write_file` are reserved for when that changes, and aren't built
- Permission requests with no plugin handler are rejected
- `on.request.permission` gives the plugin `request.tool_call`, `data.options` and `data.respond(option_id)`. Option fields are snake_case (`option.id`, not ACP's `optionId`). `data.respond(nil)` cancels
- The agent waits until the handler calls `data.respond()`. A handler that never responds leaves the reply hanging, and the docs say so

## Events

Every adapter emits the same events, so plugins never see provider-specific chunks. Handlers come in two groups.

Events tell the plugin something, and ask nothing of it:

- `on.text`
- `on.reasoning`
- `on.usage`
- `on.tool_update`
- `on.done`
- `on.error`

Requests ask the plugin for something, and the reply waits for its answer. They sit under `on.request`:

- `on.request.tool_call`
- `on.request.permission` (ACP)
- `on.request.read_file` and `on.request.write_file` (ACP, reserved, not built)

Every adapter supports `stream = false`. The plugin gets the same events in one burst once the reply is complete, so its code doesn't change between modes. A reply with a tool call arrives as one burst up to the tool call, and another once the call is answered. Where a provider supports only one mode, the SDK covers the other: it collects a stream into one reply, or sends a complete reply as one burst of events.

Tool calls are passed straight through to the plugin's `on.request.tool_call` handler.

- A prompt isn't done while a tool call is unanswered. The plugin answers on the event with `data.respond(content)` or `data.fail(message)`
- When every call in a reply is answered, the SDK sends the results and the same prompt carries on. The plugin sees one `done`, with the whole answer, as it does on ACP
- The SDK pairs the ids, so the history never holds a tool call without its result
- A request handler that never answers leaves the reply hanging. With no `tool_call` handler, the SDK fails the call. With no `permission` handler, it rejects the request
- On ACP the agent runs the tool itself, so `data.respond` and `data.fail` do nothing

- Every handler receives one table, `data` (`data.text`, `data.message`), so every handler has the same shape
- Handlers run on the main loop, so they can write to buffers and windows directly
- Every prompt ends with exactly one `done` or one `error`
- `done` receives the whole reply: `reply.text`, `reply.reasoning` and `reply.usage`. `done` always means a reply was added to the history
- Stopping a reply ends the prompt with an `error` whose `data.cancelled` is `true`. On HTTP, nothing from the stopped reply is added to the history
- A prompt that ends in `error` adds nothing to the history, not even the prompt itself. The `error` event carries it as `data.prompt`, so the plugin can send it again or return it to the user
- Tool calls carry `needs_result`. It is `true` on HTTP, where the plugin owes a result, and `false` on ACP, where the agent runs the tool itself
- `reply.tool_calls` lists every tool call in the prompt, and `reply.usage` adds up every request the prompt made

## Async

- Built on `vim.async`
- Events and callbacks are the base API
- A coroutine wrapper lets a plugin write `local reply, err = session:ask(...)`. It returns `reply, err` rather than raising like `vim.async.await`, as that reads better at the call site
- The session's handlers still run during `session:ask()`, so a buffer can stream while the task waits. Closing the task stops the reply

## Adapters

- Port CodeCompanion's clients and adapters, keeping its structure and names, and drop what the SDK doesn't need ([0014](adr/0014-transports-and-adapters-are-ports-of-codecompanion.md))
- The ACP client follows CodeCompanion's flow with leaner code and its own names. Each file's header names the CodeCompanion file it came from
- HTTP adapters use CodeCompanion's nested handlers (`lifecycle`, `request`, `response`, `tools`) and its `schema`
- An adapter is included only if it needs code beyond config
- OpenRouter is the one exception and ships as its own adapter because of its scale. It extends `openai_compatible`
- `openai_compatible` is the base for everything else. Providers like Novita are config examples in the docs, not adapters
- HTTP: Anthropic, OpenAI Responses, OpenAI Chat Completions, `openai_compatible`, Gemini, Ollama, OpenRouter. Copilot is still to decide, as its token exchange is vendor-specific
- ACP: CodeCompanion's ACP adapter shape (`commands`, `defaults`, `parameters`, `handlers`), plus presets for Claude Code, Codex and Gemini CLI. Claude Code is built
- The user sets an agent's session options (`model`, `mode`, `thought_level`) in `defaults.session_config_options`, by category. Presets set none. A value the agent doesn't offer ends the prompt in an error
- The session's model goes through the agent's `model` option
- `system_prompt` is sent only to an agent that advertises `systemPrompt`, as CodeCompanion does

## Testing

The SDK ships a public test adapter that replays a scripted stream of events, so plugin authors can test without API keys or network calls.

- `require("agent_sdk.test").adapter({ replies = ... })`. Each entry in `replies` is the reply to one request. A prompt whose reply has a tool call makes a second request once the call is answered
- Each reply ends with an explicit `done` or `error`, so a test can script either
- `type = "acp"` scripts an agent: permission requests, and `session:set_messages()` returning `false, err`
- `scripted.responses` lists the option ids the plugin's permission handlers responded with
- Tests add the test adapter through `agent_sdk.setup()`, standing in for the user

## Open

- Handler naming and sections
- When CodeCompanion moves onto the SDK, and what its shim looks like
- Moving the plugins that use `codecompanion.http` and `codecompanion.adapters` to the SDK
- How a plugin gives the model its tool definitions on HTTP. Until this exists, only the test adapter produces tool calls on HTTP

## Further ahead

Ideas only. Not designed yet.

- **Tool definitions:** plugins send their own. System prompts are already a session option
- **Skills:** users define skills, and plugin authors can ship skills with their plugin. How they are included in a request is still to work out. Skills plus curated tool definitions would let a plugin author ship a well-tuned plugin
- **Agent cards:** like a model card, every plugin built on the SDK publishes one. It states the tools it runs on the user's machine and the risk of each
- **Safety:** the SDK makes it easy for a plugin to have an agent run tools on the user's machine. A malicious plugin could use that to take control of it. Agent cards are one part of the answer, and this needs a lot of care

## Next step

Built: the adapter registry, sessions, events, requests, the test adapter, the HTTP transport, the Anthropic adapter, the ACP transport and the Claude Code preset. A demo plugin lives in [agent-sdk-demo.nvim](../../agent-sdk-demo.nvim).

1. Try the demo plugin against Claude Code, and change what feels wrong
2. Build bottleneck.nvim on it. Rewrite the README's examples from that experience, as the current ones are a sketch

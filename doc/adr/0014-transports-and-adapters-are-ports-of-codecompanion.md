# Transports and adapters are ports of CodeCompanion's code

ADR 0012 started the adapters from CodeCompanion, but the first HTTP client, Anthropic adapter and ACP client were fresh rewrites that only borrowed its ideas. They now port CodeCompanion's files directly, keeping its structure and names, and drop only what the SDK has no use for (chat buffer events, logging, model fetching, server-side tools, compaction). The SDK's own code is the part that turns each client's output into session events.

This supersedes [0010](0010-provider-reply-blocks-are-stored-as-received.md). The history uses CodeCompanion's message format, and adapters rebuild provider blocks from it, as CodeCompanion's do: Anthropic's thinking signature lives in `reasoning._data.signature`.

## Consequences

- HTTP adapters use CodeCompanion's nested handler names (`lifecycle.setup`, `request.build_messages`, `response.parse_chat`, `tools.format_calls`) and its `schema`. ACP adapters use its `commands`, `defaults`, `parameters` and `handlers`
- Tool calls in the history are OpenAI-shaped (`function.name`, `function.arguments` as JSON), as in CodeCompanion
- A fix to CodeCompanion's clients or adapters can be carried across, and the other way round
- The ACP client keeps CodeCompanion's flow (start the agent, initialize, authenticate, create the session, apply the config options, prompt) but is slimmed down and renamed. Each file's header names the CodeCompanion file it came from
- Event fields come from the provider's or ACP's spec. Anything outside it, like ACP's `_meta`, goes in `meta`. A field both transports emit keeps one name, per [0003](0003-one-session-api-for-http-and-acp.md): ACP's `rawInput` is `arguments`, `cachedReadTokens` is `cache_read_input_tokens`

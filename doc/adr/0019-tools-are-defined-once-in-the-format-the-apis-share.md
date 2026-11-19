# Tools are defined once, in the format the APIs share

A plugin gives the model its tools in the session's `tools`, as a list of `{ name, description, parameters }`, where `parameters` is a JSON Schema object. Every API we support takes the same three things and only names or nests them differently: Anthropic calls the schema `input_schema`, Chat Completions nests the tool under `function`, Responses keeps it flat, and Gemini wraps the list in `functionDeclarations` and takes the schema as `parametersJsonSchema`. Each adapter's `build_tools` moves the fields with `tools.translate()`, and the schema itself is sent unchanged. It's the same shape MCP uses, so tools from an MCP server map across too.

## Considered options

- **OpenAI's Chat Completions format, as CodeCompanion uses:** rejected. The `type = "function"` wrapper says nothing to a plugin author, and every other API has to unwrap it
- **Our own schema language, converted to each API's:** rejected. Plugin authors already know JSON Schema, and any conversion loses what the target can't express
- **Gemini's `parameters` field:** rejected. It takes an OpenAPI subset, so the schema would need converting. `parametersJsonSchema` takes JSON Schema as it is
- **Tools per prompt:** rejected for now. Anthropic refuses a request whose history holds tool calls but which defines no tools, so dropping a tool mid-session can break the next prompt

## Consequences

- `sdk.session()` raises on a tool that any API would reject: a name outside `^[a-zA-Z_][a-zA-Z0-9_-]{0,63}$`, a duplicate name, no description, or `parameters` without `type = "object"`. A plugin finds the mistake when it starts a session, not from a provider's 400
- Provider extras like OpenAI's `strict` or Anthropic's `cache_control` aren't in the format. An adapter that wants them overrides `build_tools`
- An empty `properties` table is sent as `{}`, not `[]`, as Lua can't tell them apart
- An ACP agent ignores `tools`, so a plugin passes them whatever the adapter

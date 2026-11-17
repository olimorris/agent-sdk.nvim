# HTTP adapters and ACP agents share `parameters`

A user configures every adapter with `parameters`, and three keys mean the same thing on both transports: `mode`, `model` and `thought_level`. The names are ACP's session config option categories. On an ACP agent, `parameters` are its session config options. On an HTTP adapter, they're the request body, and each adapter translates `thought_level` into its provider's field (`output_config.effort` for Anthropic, `reasoning_effort` for OpenAI) and ignores `mode`.

Without this, a user writes `defaults.session_config_options` for an agent and `parameters` for an API, with different names for the same setting. The mapping back to ACP is documented on the adapters page, so a person or an agent reading the config can find the spec's name.

ACP adapters held the `initialize` request's params in `parameters`, as in CodeCompanion. They move to `initialize`, named after the ACP method, and CodeCompanion's shim maps one to the other.

## Considered options

- **`defaults.session_config_options` on HTTP adapters too:** rejected. It's a long name for what most users think of as parameters, and HTTP adapters have no `defaults` table
- **A separate key for the shared settings:** rejected. A user would set `model` in one place and `temperature` in another

## Consequences

- Each API's mapping is a data file in `lua/agent_sdk/adapters/parameters/`, separate from its adapter, so it can be tested on its own and read alongside the vendor's docs
- `defaults.session_config_options` still works on ACP agents, with `parameters` taking priority
- A session takes `mode`, `model` and `thought_level` and nothing else, so a plugin can't send a key that only one transport understands
- Values aren't unified. Each agent and provider accepts its own `thought_level` values, and an unknown one ends the prompt in an error

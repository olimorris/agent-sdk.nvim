# Configuration

You set up your adapters once, in agent-sdk.nvim. Every plugin built on it then picks one by name.

```lua
require("agent_sdk").setup({
  adapters = {
    anthropic = require("agent_sdk.adapters").extend("anthropic", {
      env = { api_key = "cmd:op read op://Private/Anthropic_API/credential --no-newline" },
    }),
    claude_code = "claude_code",
  },
})

require("some_plugin").setup({ adapter = "anthropic" })
require("other_plugin").setup({ adapter = { name = "claude_code", model = "sonnet" } })
```

The key is your name for the adapter. A string uses a built-in adapter as it ships. `extend()` copies a built-in adapter and overrides any part of it.

## Built-in adapters

| Name | Type | Talks to |
| --- | --- | --- |
| `anthropic` | HTTP | Anthropic's Messages API |
| `claude_code` | ACP | Claude Code, through [claude-agent-acp](https://github.com/agentclientprotocol/claude-agent-acp) |

## Credentials

`env` holds the values an adapter needs, like an API key. Each value is one of:

| Value | Resolves to |
| --- | --- |
| `"ANTHROPIC_API_KEY"` | That environment variable. If it isn't set, the string itself |
| `"cmd:op read op://..."` | The command's output, with trailing whitespace removed |
| `"file:~/.secrets/anthropic"` | The file's contents |
| `function(adapter) ... end` | What the function returns |

A `cmd:` runs once and its output is reused, so your password manager asks once. It runs again after an HTTP provider rejects the key with a 401 or 403.

A failing `cmd:` ends the prompt in an error with its stderr:

```
agent-sdk.nvim: the command `op read op://Private/Anthropic_API/credential` failed: [ERROR] not signed in
```

## Anthropic

```lua
anthropic = require("agent_sdk.adapters").extend("anthropic", {
  env = { api_key = "cmd:op read op://Private/Anthropic_API/credential --no-newline" },
  schema = {
    model = { default = "claude-opus-5-5" },
    extended_thinking = { default = false },
    max_tokens = { default = 32000 },
  },
}),
```

| Setting | Default |
| --- | --- |
| `env.api_key` | `"ANTHROPIC_API_KEY"` |
| `schema.model.default` | `"claude-sonnet-5"` |
| `schema.extended_thinking.default` | `true` for models that can reason |
| `schema.max_tokens.default` | The model's limit, `64000` |
| `schema.top_p.default`, `schema.top_k.default`, `schema.stop_sequences.default` | Not sent |

A plugin's `model` replaces `schema.model.default` for its sessions.

## Claude Code

Install [claude-agent-acp](https://github.com/agentclientprotocol/claude-agent-acp) and sign in to Claude Code. The SDK starts the agent on a plugin's first prompt.

```lua
claude_code = require("agent_sdk.adapters").extend("claude_code", {
  env = { CLAUDE_CODE_OAUTH_TOKEN = "cmd:op read op://Private/Claude_Code/token --no-newline" },
  defaults = {
    session_config_options = {
      model = "opus",
      mode = "plan",
      thought_level = "high",
    },
  },
}),
```

`env.CLAUDE_CODE_OAUTH_TOKEN` is optional. Without it, the agent uses your Claude Code sign-in.

### Session options

`defaults.session_config_options` sets the agent's own options when a session starts, by category. Leave one out to keep the agent's default. A value can be the option's value or its name, in any case.

| Category | Claude Code's values |
| --- | --- |
| `model` | `default`, `opus`, `sonnet`, `fable`, `haiku`, and older models by id |
| `mode` | `default` (Manual), `acceptEdits`, `plan`, `auto`, `bypassPermissions` |
| `thought_level` | `default`, `low`, `medium`, `high`, `xhigh`, `max` |

The agent decides the values, so they change with its version. A value it doesn't offer ends the prompt in an error that lists the ones it does:

```
agent-sdk.nvim: gpt isn't one of the agent's model options: default, opus, sonnet, fable, haiku, ...
```

A plugin's `model` replaces the `model` option for its sessions.

### Other settings

```lua
claude_code = require("agent_sdk.adapters").extend("claude_code", {
  commands = {
    default = { vim.fn.expand("~/.local/bin/claude-agent-acp") },
  },
  defaults = {
    timeout = 30000,
    mcpServers = {
      { name = "github", command = "github-mcp-server", args = { "stdio" }, env = {} },
    },
  },
}),
```

| Setting | |
| --- | --- |
| `commands.default` | The command that starts the agent. Defaults to `{ "claude-agent-acp" }` |
| `defaults.timeout` | How long to wait for the agent to change a session option, in milliseconds. Defaults to `20000` |
| `defaults.mcpServers` | MCP servers to give the agent, in [ACP's format](https://agentclientprotocol.com/protocol/session-setup#mcp-servers) |

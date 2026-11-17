# One ACP adapter, and agents are config

The SDK ships one `acp` adapter, and every agent, like Claude Code, Codex or Gemini CLI, is the user's config extending it: a command, credentials in `env`, and an auth method if the agent needs one. Each agent gets a Configure page that a user, or their coding agent, follows to install it and sign in.

CodeCompanion ships an adapter per agent, but each one differs from the others only in that config. The only code, in Claude Code's adapter, decided whether to sign in. The SDK makes that generic: it calls `authenticate` only with the method the user set in `defaults.auth_method`, and otherwise lets the agent sign in with what it has. When an agent then refuses to start a session, the error lists the agent's auth methods.

This settles the open question in [0015](0015-one-adapter-per-api-format.md): ACP agents follow the same rule as HTTP providers.

## Considered options

- **A preset per agent, extending `acp`:** rejected. Each preset is config the SDK would have to keep in step with the agent's releases, and the docs page already gives the user that config
- **Sign in with the agent's first auth method, as CodeCompanion does:** rejected. Which method comes first is the agent's choice, and a method that starts an interactive login can't finish from inside Neovim

## Consequences

- A user writes `commands.default` themselves, so the Configure page for each agent has to say exactly what to install and what to put there
- CodeCompanion's shim maps its per-agent adapters onto `acp`

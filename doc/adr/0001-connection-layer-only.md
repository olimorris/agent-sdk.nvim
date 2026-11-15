# The SDK is the connection layer only

Every Neovim plugin that talks to a model builds its own adapters, ACP client and credential handling. The SDK does that part once and stops there: it owns adapters, credentials, the transport and the history. It has no agent loop, no UI and no built-in tools, because those are where plugins differ and where they compete.

## Consequences

- The name suggests more. "Agent SDK" elsewhere means a loop with tools, so the README says early that this is not one
- A plugin decides what every tool call does and when to stop. The SDK only carries the plugin's answer back (see [0007](0007-a-prompt-is-not-done-while-a-tool-call-is-unanswered.md))

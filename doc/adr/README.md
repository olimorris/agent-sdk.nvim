# Decisions

One file per decision: what was decided and why. A decision is recorded here when it is hard to reverse, surprising without context, and the result of a real trade-off.

To add one, copy the next number and write a title and a short paragraph. Add "Considered options" or "Consequences" only when they are worth remembering.

- [0001](0001-connection-layer-only.md) - The SDK is the connection layer only
- [0002](0002-users-configure-adapters-once.md) - Users configure adapters once, and plugins use them by name
- [0003](0003-one-session-api-for-http-and-acp.md) - One session API for HTTP adapters and ACP agents
- [0004](0004-built-on-vim-async.md) - Built on vim.async, which requires Neovim nightly
- [0005](0005-the-sdk-owns-the-history.md) - The SDK owns the history
- [0006](0006-events-and-requests.md) - Handlers are split into events and requests
- [0007](0007-a-prompt-is-not-done-while-a-tool-call-is-unanswered.md) - A prompt isn't done while a tool call is unanswered
- [0008](0008-a-failed-prompt-adds-nothing-to-the-history.md) - A failed prompt adds nothing to the history
- [0009](0009-streaming-and-non-streaming-share-handlers.md) - Streaming and non-streaming replies use the same handlers
- [0010](0010-provider-reply-blocks-are-stored-as-received.md) - A provider's reply blocks are stored as received and sent back unchanged (superseded by 0014)
- [0011](0011-no-file-handlers-or-terminals-for-acp-agents.md) - No file handlers or terminals for ACP agents
- [0012](0012-adapters-start-from-codecompanion.md) - Adapters start from CodeCompanion's adapter code (second paragraph superseded by 0015)
- [0013](0013-a-public-test-adapter.md) - The SDK ships a public test adapter
- [0014](0014-transports-and-adapters-are-ports-of-codecompanion.md) - Transports and adapters are ports of CodeCompanion's code
- [0015](0015-one-adapter-per-api-format.md) - The SDK ships one adapter per API format, and other providers extend one

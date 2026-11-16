<!-- panvimdoc-ignore-start -->

<p align="center">
<img src="https://github.com/user-attachments/assets/8f4576e6-8313-401a-b114-db0f7f3b793b" alt="Agent-SDK.nvim" />
</p>

<!-- panvimdoc-ignore-end -->

An SDK enabling you to connect Neovim plugins to LLMs and agents via HTTP and [ACP](https://agentclientprotocol.com). Like [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) was for early Neovim plugin devs...

## Adapters

Agent SDK ships one adapter per API format: OpenAI, OpenAI Responses, Anthropic, Gemini and Copilot. Any other provider, like Ollama or OpenRouter, extends one of them, in your config or in its own plugin. Pull requests that add a vendor adapter are declined.


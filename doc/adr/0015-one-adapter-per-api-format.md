# The SDK ships one adapter per API format

The SDK ships an adapter only for an API format that needs its own code. Over HTTP that's OpenAI, OpenAI Responses, Anthropic, Gemini and Copilot. Every other provider, like Ollama or OpenRouter, extends one of them, either in the user's config or in its own plugin. Pull requests that add a vendor adapter are declined, and point to extending instead.

Without this, the repo becomes an adapter registry, and its upkeep grows with every provider. The work goes into making the base adapters extensible instead: an extension can override any handler, not only the URL, key and model. OpenRouter is the test of that. Its session IDs, routing and provider preferences must all be reachable by extending `openai`, with no change to the SDK.

This replaces the second paragraph of [0012](0012-adapters-start-from-codecompanion.md), including OpenRouter as a built-in exception.

## Considered options

- **Ship an adapter per vendor:** rejected. Most vendors differ from a base format only in their URL and a few fields, and every one would be another adapter to keep current
- **OpenRouter as a built-in exception:** rejected. If extending can't cover OpenRouter, the base adapter isn't extensible enough, and that's the thing to fix

## Consequences

- The docs show how to extend an adapter, including overriding handlers, with Ollama and OpenRouter as examples
- An adapter for a popular provider can live in its own plugin, and later in an Agent SDK organisation, without a pull request to this repo
- ACP agents follow the same rule, from one `acp` adapter. See [0017](0017-one-acp-adapter.md)

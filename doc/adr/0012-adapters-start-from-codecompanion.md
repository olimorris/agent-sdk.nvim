# Adapters start from CodeCompanion's adapter code

The SDK is a new repo, and its adapters keep CodeCompanion's structure (`env`, `headers`, handlers). That layer has been stable for over a year, and plugins already reach into it as an unofficial SDK (`codecompanion.http`, `codecompanion.adapters`). CodeCompanion stays as it is until the SDK settles, then adopts it with a shim for its existing adapters.

Superseded by [0015](0015-one-adapter-per-api-format.md): An adapter ships only if it needs code beyond config. `openai_compatible` is the base for everything else, and providers that are only a URL and a key are config examples in the docs. OpenRouter is the one exception because of its scale.

## Considered options

- **Extract the SDK out of CodeCompanion in place:** rejected. CodeCompanion's adapters are tied to its chat buffer and config, and changing them in place would break its users while the SDK's API is still moving

# AGENTS.md

## Golden rule: HTTP and ACP are interchangeable

A plugin's code must work unchanged whether the user picks an HTTP adapter or an ACP agent. Before adding or renaming any event, reply or session field, check what the other transport emits for the same thing and use that name, even where ACP's spec or the provider's API names it differently. Only a field with no counterpart on the other side keeps its spec name. The reasoning is in [ADR 0003](doc/adr/0003-one-session-api-for-http-and-acp.md), and the remaining differences are listed in `doc/INTEGRATING.md`.

## No vendor adapters

The SDK ships one adapter per API format. Never add an adapter for a vendor like Ollama or OpenRouter: it extends an existing adapter with `extend()`. If an extension can't reach what it needs, make the base adapter more extensible instead. See [ADR 0015](doc/adr/0015-one-adapter-per-api-format.md).

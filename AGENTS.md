# AGENTS.md

## Golden rule: HTTP and ACP are interchangeable

A plugin's code must work unchanged whether the user picks an HTTP adapter or an ACP agent. Before adding or renaming any event, reply or session field, check what the other transport emits for the same thing and use that name, even where ACP's spec or the provider's API names it differently. Only a field with no counterpart on the other side keeps its spec name. The reasoning is in [ADR 0003](docs/adr/0003-one-session-api-for-http-and-acp.md), and the remaining differences are listed in `docs/INTEGRATING.md`.

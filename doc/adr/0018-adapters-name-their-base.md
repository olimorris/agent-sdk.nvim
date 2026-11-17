# Adapters name their base instead of calling extend()

A user's adapter is a plain table. `base = "openai"` names the built-in it starts from, and the rest of the table is merged over a copy of it when a plugin first asks for the adapter. A string, like `anthropic = "anthropic"`, is shorthand for a base with nothing changed. A table without `base` is a complete adapter.

CodeCompanion's `require("codecompanion.adapters").extend(name, table)` put a `require` and a function call in front of every adapter, and loaded every built-in a user mentioned at startup. With `base`, the config reads as data and nothing loads until it's used. `base` sorts first among an adapter's keys, so what it's built on is always the first line.

## Considered options

- **Keep `extend()`:** rejected. It's noise on every entry, and a second way to say what a string already says
- **Keep `extend()` as an alias for CodeCompanion's users:** rejected. The SDK isn't released, and the shim can turn `extend()` calls into `base`

## Consequences

- A mistake in an adapter's table, like a `base` that isn't a built-in, shows up when a plugin asks for the adapter, as the error from `sdk.adapter()`
- An override still calls the base adapter's handler through `require("agent_sdk.adapters.http.openai")`

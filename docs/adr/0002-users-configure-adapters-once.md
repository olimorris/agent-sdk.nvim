# Users configure adapters once, and plugins use them by name

Users were setting up the same API keys and models in every plugin. Adapters, credentials and models now live in one place, `agent_sdk.setup({ adapters = ... })`, and a plugin's own config holds only an adapter's name and an optional model.

A plugin never registers an adapter. Third-party adapters are added by the user in their own setup. `sdk.adapter(name)` returns a deep copy, so a plugin can change its copy and can never change the user's config.

## Considered options

- **Plugins register adapters:** rejected. Two plugins could register different adapters under one name, and the user would no longer know where a model's settings come from
- **Return the user's adapter itself:** rejected. One plugin's change would leak into every other plugin

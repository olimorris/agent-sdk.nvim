# The SDK ships a public test adapter

A plugin built on the SDK needs tests that run with no API keys and no network. `require("agent_sdk.test").adapter({ replies = ... })` replays scripted events through the real session code, so a plugin's tests exercise the same handlers, history and requests as a real adapter. Tests add it through `agent_sdk.setup()`, standing in for the user.

## Considered options

- **Leave plugins to stub the SDK:** rejected. Every plugin would write its own fake, and the fakes would drift from how the SDK behaves

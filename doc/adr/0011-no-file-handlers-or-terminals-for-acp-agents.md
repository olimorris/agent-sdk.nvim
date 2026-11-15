# No file handlers or terminals for ACP agents

ACP lets an agent ask the editor to read files, write files and run commands in a terminal. The SDK never tells an agent the editor can do these. The agent uses its own file access and its own shell, behind permission requests.

The terminal protocol is the most code a plugin would write for any SDK feature, and a mistake in it runs commands on the user's machine. File handlers are less risky, but shipping an implementation would put file access inside a library whose scope is the connection.

`on.request.read_file` and `on.request.write_file` are reserved for a plugin to supply its own, and aren't built.

## Consequences

- An ACP agent reads from disk, so it doesn't see unsaved changes in a buffer

# Examples

How the SDK looks from a plugin. The first three sections are built and tested. [Still to decide](#still-to-decide) holds proposals.

`append` and `read_file` are the plugin's own functions: one writes to a buffer, the other returns a file's text, including unsaved changes.

## A reply

The plugin writes its handlers once. They run for every prompt in the session, streaming or not.

```lua
local session = sdk.session({
  adapter = adapter,
  on = {
    reasoning = function(event)
      append(reasoning_buf, event.text)
    end,
    text = function(event)
      append(answer_buf, event.text)
    end,
    done = function(reply)
      vim.bo[answer_buf].modifiable = false
    end,
    error = function(event)
      vim.notify(event.message, vim.log.levels.ERROR)
    end,
  },
})

session:prompt("Why was the nil check moved?")
session:prompt("Why was the nil check moved?", { stream = false })
```

`done` receives the whole reply:

```lua
reply = {
  text = "I'll read the file to check. It moved because...",
  reasoning = "The nil check moved above the loop, so...",
  tool_calls = {
    { id = "toolu_01A", name = "read_file", arguments = { path = "lua/foo.lua" } },
  },
  usage = { input_tokens = 2600, output_tokens = 140 },
}
```

## A tool call

A prompt isn't done while a tool call is unanswered. The plugin answers on the event, and the same prompt carries on.

```lua
on = {
  tool_call = function(call)
    if call.name ~= "read_file" then
      return call.fail("Unknown tool: " .. tostring(call.name))
    end
    local text, err = read_file(call.arguments.path)
    if text then
      call.respond(text)
    else
      call.fail(err)
    end
  end,
}
```

The plugin's handlers run in this order: `text`, `tool_call`, `text`, `done`.

Afterwards the history holds every step, with each tool call paired to its result:

```lua
session.messages = {
  { role = "user", content = "Why was the nil check moved?" },
  {
    role = "llm",
    content = "I'll read the file to check.",
    reasoning = { content = "The nil check moved above the loop, so..." },
    tools = { calls = { { id = "toolu_01A", name = "read_file", arguments = { path = "lua/foo.lua" } } } },
  },
  { role = "tool", content = "local M = {}\n...", tools = { call_id = "toolu_01A" } },
  { role = "llm", content = "It moved because..." },
}
```

On an ACP agent the same handler runs, but the agent runs its own tools. `call.needs_result` is `false`, and `call.respond()` and `call.fail()` do nothing.

## A prompt that fails

A prompt that errors or is stopped adds nothing to the history. The `error` event carries the prompt, so the plugin can send it again or hand it back to the user.

```lua
on = {
  error = function(event)
    if event.cancelled then
      return restore_input(event.prompt)
    end
    vim.notify(event.message, vim.log.levels.ERROR)
    last_failed_prompt = event.prompt
  end,
}

session:prompt(last_failed_prompt)
```

## Still to decide

### Tool definitions

How a plugin tells the model which tools it has. Proposed as a session option:

```lua
local session = sdk.session({
  adapter = adapter,
  tools = {
    {
      name = "read_file",
      description = "Read a file from the user's project, including unsaved changes",
      parameters = {
        type = "object",
        properties = { path = { type = "string" } },
        required = { "path" },
      },
    },
  },
  on = { ... },
})
```

An ACP agent can't be given the plugin's tools. It has its own, so `tools` is ignored there.

### ACP file handlers

An ACP agent reads from disk, so it misses unsaved changes. ACP lets the agent ask the editor to read or write a file instead. Proposed as events with the same `respond` and `fail` as a tool call:

```lua
on = {
  read_file = function(request)
    local text, err = read_file(request.path)
    if text then
      request.respond(text)
    else
      request.fail(err)
    end
  end,
  write_file = function(request)
    request.fail("This plugin is read-only")
  end,
}
```

- `request.path`, plus `request.line` and `request.limit` when the agent wants part of a file. `write_file` adds `request.content`
- Declaring the handler is what tells the agent it can ask. With no handler, the agent uses its own file access
- On HTTP these never fire. The plugin wires `read_file` twice: as a tool for HTTP, as a handler for ACP

### ACP terminals

An agent can ask the editor to run a command for it. Proposed: leave this out of the first release. With no handler, the agent runs commands in its own shell, behind `permission_request`.

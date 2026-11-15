# Examples

How the SDK looks from a plugin. The first four sections are built and tested. [Still to decide](#still-to-decide) holds what isn't.

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
  request = {
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
  },
}
```

The plugin's handlers run in this order: `text`, `request.tool_call`, `text`, `done`.

A tool call sits under `on.request` because the model is asking the plugin for something. `text`, `reasoning`, `done` and `error` ask nothing.

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

## From the provider to your handlers

One reply from Anthropic, followed from the API to the plugin. The model thinks, writes some text and asks for a tool. Once the plugin answers, it finishes the answer.

### What Anthropic sends

Anthropic streams the reply as events. Put together, the first request returns:

```lua
{
  role = "assistant",
  stop_reason = "tool_use",
  content = {
    { type = "thinking", thinking = "The nil check moved above the loop, so...", signature = "EqQBCkYIBxgC..." },
    { type = "text", text = "I'll read the file to check." },
    { type = "tool_use", id = "toolu_01A", name = "read_file", input = { path = "lua/foo.lua" } },
  },
  usage = { input_tokens = 1200, output_tokens = 85 },
}
```

The plugin never sees this. Every adapter turns its provider's output into the same events.

### What your handlers receive

In order, with the table each handler is called with:

```lua
-- first request
on.usage({ type = "usage", input_tokens = 1200, output_tokens = 1 })
on.reasoning({ type = "reasoning", text = "The nil check moved " })
on.reasoning({ type = "reasoning", text = "above the loop, so..." })
on.text({ type = "text", text = "I'll read the file " })
on.text({ type = "text", text = "to check." })
on.request.tool_call({
  type = "tool_call",
  id = "toolu_01A",
  name = "read_file",
  arguments = { path = "lua/foo.lua" },
  needs_result = true,
  respond = function(content) end,
  fail = function(message) end,
})
on.usage({ type = "usage", output_tokens = 85 })

-- the plugin calls call.respond("local M = {}\n..."), and the SDK sends the second request
on.usage({ type = "usage", input_tokens = 1400, output_tokens = 1 })
on.text({ type = "text", text = "It moved because..." })
on.usage({ type = "usage", output_tokens = 40 })

on.done(reply)
```

- `reasoning` and `text` arrive in pieces as they stream. With `stream = false` they arrive once each, with the whole text
- `usage` reports the counts as the provider sends them, so a request can report more than once
- A handler the plugin didn't define is skipped

### What `done` receives

The whole reply, across both requests:

```lua
reply = {
  text = "I'll read the file to check.It moved because...",
  reasoning = "The nil check moved above the loop, so...",
  tool_calls = {
    { id = "toolu_01A", name = "read_file", arguments = { path = "lua/foo.lua" } },
  },
  usage = { input_tokens = 2600, output_tokens = 125 },
}
```

- `text` and `reasoning` join every piece exactly as received, with nothing added between requests
- `usage` adds up every request the prompt made

### What the history holds

```lua
session.messages = {
  { role = "user", content = "Why was the nil check moved?" },
  {
    role = "llm",
    content = "I'll read the file to check.",
    reasoning = { content = "The nil check moved above the loop, so..." },
    tools = { calls = { { id = "toolu_01A", name = "read_file", arguments = { path = "lua/foo.lua" } } } },
    data = {
      provider = "anthropic",
      content = {
        { type = "thinking", thinking = "The nil check moved above the loop, so...", signature = "EqQBCkYIBxgC..." },
        { type = "text", text = "I'll read the file to check." },
        { type = "tool_use", id = "toolu_01A", name = "read_file", input = { path = "lua/foo.lua" } },
      },
    },
  },
  { role = "tool", content = "local M = {}\n...", tools = { call_id = "toolu_01A" } },
  { role = "llm", content = "It moved because...", data = { provider = "anthropic", content = { ... } } },
}
```

- `content`, `reasoning` and `tools` are the same for every adapter
- `data` is the adapter's own copy of the reply, sent back unchanged on the next request so Anthropic's thinking signature survives. Plugins don't read it

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

Reserved, not built. An ACP agent reads from disk, so it misses unsaved changes. ACP lets the agent ask the editor to read or write a file instead. These would be requests, next to `tool_call`:

```lua
on = {
  request = {
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
  },
}
```

## Left out

Terminals. An ACP agent runs commands in its own shell, behind a permission request.

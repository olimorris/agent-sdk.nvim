local anthropic = require("agent_sdk.adapters.anthropic")
local sdk = require("agent_sdk")
local fake_http = dofile("tests/fake_http.lua")

local eq = MiniTest.expect.equality

local function stub(name)
  return fake_http.read("tests/stubs/" .. name)
end

local function body(request)
  return anthropic.handlers.request.body(anthropic, request)
end

local fake
local previous_key

local function setup_session(stubs, on)
  sdk.setup({ adapters = { anthropic = "anthropic" } })
  fake.on_call = function(call, number)
    fake_http.deliver(call, stubs[number], 7)
  end
  return sdk.session({ adapter = sdk.adapter("anthropic"), on = on })
end

local function recorder()
  local log = {}
  local function record(kind)
    return function(event)
      log[#log + 1] = { kind, event }
    end
  end
  local on = {
    text = record("text"),
    reasoning = record("reasoning"),
    usage = record("usage"),
    done = record("done"),
    error = record("error"),
    request = {
      tool_call = function(call)
        log[#log + 1] = { "tool_call", call }
        call.respond("file contents")
      end,
    },
  }
  return log, on
end

local function kinds(log)
  return vim.tbl_map(function(entry)
    return entry[1]
  end, log)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      previous_key = vim.env.ANTHROPIC_API_KEY
      vim.env.ANTHROPIC_API_KEY = "dummy-key"
      fake = fake_http.install()
    end,
    post_case = function()
      fake.restore()
      vim.env.ANTHROPIC_API_KEY = previous_key
    end,
  },
})

T["text only stream"] = function()
  local log, on = recorder()
  local session = setup_session({ stub("anthropic_text.txt") }, on)
  local reply = session:prompt("hi"):wait(1000)

  eq(kinds(log), { "usage", "text", "text", "usage", "done" })
  eq(log[1][2].input_tokens, 25)
  eq(log[1][2].cache_read_input_tokens, 0)
  eq(reply.text, "Hello, world")
  eq(reply.usage.input_tokens, 25)
  eq(reply.usage.output_tokens, 12)
  eq(session.messages[2].content, "Hello, world")
  eq(session.messages[2].data, {
    provider = "anthropic",
    content = { { type = "text", text = "Hello, world" } },
  })
  eq(fake.calls[1].cmd[1], "curl")
  eq(fake.calls[1].opts.stdin:find("x-api-key: dummy-key", 1, true) ~= nil, true)
end

T["thinking, text and a tool call"] = function()
  local log, on = recorder()
  local session = setup_session({ stub("anthropic_thinking_tool.txt"), stub("anthropic_text.txt") }, on)
  local reply = session:prompt("hi"):wait(1000)

  eq(kinds(log), {
    "usage",
    "reasoning",
    "reasoning",
    "text",
    "tool_call",
    "usage",
    "usage",
    "text",
    "text",
    "usage",
    "done",
  })
  eq(log[5][2].name, "read_file")
  eq(log[5][2].arguments, { path = "lua/foo.lua" })
  eq(reply.reasoning, "The nil check moved above the loop.")

  local assistant = session.messages[2]
  eq(assistant.data.content[1], {
    type = "thinking",
    thinking = "The nil check moved above the loop.",
    signature = "EqQBCkYIBxgC",
  })
  eq(
    assistant.data.content[3],
    { type = "tool_use", id = "toolu_01A", name = "read_file", input = { path = "lua/foo.lua" } }
  )
  eq(assistant.tools.calls[1].id, "toolu_01A")
end

T["the next request sends the stored blocks back unchanged"] = function()
  local _, on = recorder()
  local session = setup_session({ stub("anthropic_thinking_tool.txt"), stub("anthropic_text.txt") }, on)
  session:prompt("hi"):wait(1000)

  local stored = session.messages[2].data.content
  local second = fake.calls[2].body.messages
  eq(second[1], { role = "user", content = "hi" })
  eq(second[2], { role = "assistant", content = stored })
  eq(second[3], {
    role = "user",
    content = { { type = "tool_result", tool_use_id = "toolu_01A", content = "file contents" } },
  })
end

T["a second prompt sends the first reply's blocks back"] = function()
  local _, on = recorder()
  local session = setup_session({ stub("anthropic_text.txt"), stub("anthropic_text.txt") }, on)
  session:prompt("one"):wait(1000)
  session:prompt("two"):wait(1000)

  local messages = fake.calls[2].body.messages
  eq(#messages, 3)
  eq(messages[2], { role = "assistant", content = session.messages[2].data.content })
  eq(messages[3], { role = "user", content = "two" })
end

T["a mid-stream error ends the prompt in one error"] = function()
  local log, on = recorder()
  local session = setup_session({ stub("anthropic_error.txt") }, on)
  local reply, err = session:prompt("hi"):wait(1000)

  eq(reply, nil)
  eq(err.message, "overloaded_error: Overloaded")
  eq(kinds(log), { "usage", "text", "error" })
  eq(session.messages, {})
end

T["a refusal ends the prompt in an error"] = function()
  local log, on = recorder()
  local session = setup_session({ stub("anthropic_refusal.txt") }, on)
  local _, err = session:prompt("hi"):wait(1000)

  eq(err.message, "The model declined this request")
  eq(kinds(log), { "usage", "text", "usage", "error" })
end

T["a non-streaming body goes through complete"] = function()
  local log, on = recorder()
  local session = setup_session({
    stub("anthropic_complete.json"),
    '{"type":"message","content":[{"type":"text","text":"Done"}],"stop_reason":"end_turn","usage":{"output_tokens":3}}',
  }, on)
  local reply = session:prompt("hi", { stream = false }):wait(1000)

  eq(fake.calls[1].body.stream, false)
  eq(fake.calls[1].body.max_tokens, 16000)
  eq(reply.reasoning, "The nil check moved above the loop.")
  eq(reply.text, "HelloDone")
  eq(reply.tool_calls[1].name, "read_file")
  eq(session.messages[2].data.content[1].signature, "EqQBCkYIBxgC")
  eq(kinds(log)[1], "usage")
  eq(fake.calls[2].body.max_tokens, 16000)
end

T["an HTTP error body becomes an error"] = function()
  local log, on = recorder()
  local session = setup_session({}, on)
  fake.on_call = function(call)
    fake_http.deliver(
      call,
      '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}',
      20
    )
  end
  local _, err = session:prompt("hi"):wait(1000)
  eq(err.message, "authentication_error: invalid x-api-key")
  eq(kinds(log), { "error" })
end

T["unknown block types are kept as received"] = function()
  local state = {}
  local handlers = anthropic.handlers.response
  handlers.chunk(anthropic, {
    type = "content_block_start",
    index = 0,
    content_block = { type = "redacted_thinking", data = "abc" },
  }, state)
  local events = handlers.chunk(anthropic, { type = "message_stop" }, state)
  eq(events[1].data.content, { { type = "redacted_thinking", data = "abc" } })
end

T["a tool call with no arguments sends an object"] = function()
  local state = {}
  local handlers = anthropic.handlers.response
  handlers.chunk(anthropic, {
    type = "content_block_start",
    index = 0,
    content_block = { type = "tool_use", id = "t", name = "ls", input = {} },
  }, state)
  local events = handlers.chunk(anthropic, { type = "content_block_stop", index = 0 }, state)
  eq(events[1], { type = "tool_call", id = "t", name = "ls", arguments = {} })
  eq(vim.json.encode(state.blocks[1].input), "{}")
end

T["bad tool JSON becomes an error naming the tool"] = function()
  local state = {}
  local handlers = anthropic.handlers.response
  handlers.chunk(anthropic, {
    type = "content_block_start",
    index = 0,
    content_block = { type = "tool_use", id = "t", name = "ls", input = {} },
  }, state)
  handlers.chunk(anthropic, {
    type = "content_block_delta",
    index = 0,
    delta = { type = "input_json_delta", partial_json = "{oops" },
  }, state)
  local events = handlers.chunk(anthropic, { type = "content_block_stop", index = 0 }, state)
  eq(events[1].type, "error")
  eq(events[1].message:find("ls", 1, true) ~= nil, true)
end

T["body: system prompt and model override"] = function()
  local result = body({ messages = {}, system_prompt = "Be brief", model = "claude-haiku-5-5", stream = true })
  eq(result.system, "Be brief")
  eq(result.model, "claude-haiku-5-5")
  eq(result.max_tokens, 64000)
  eq(result.thinking, { type = "adaptive", display = "summarized" })
  eq(result.temperature, nil)
end

T["body: the default model and no system prompt"] = function()
  local result = body({ messages = {}, stream = true })
  eq(result.model, "claude-opus-5-5")
  eq(result.system, nil)
end

T["body: fallbacks only for models that accept them"] = function()
  eq(body({ messages = {}, stream = true, model = "claude-opus-5-5" }).fallbacks, "default")
  eq(body({ messages = {}, stream = true, model = "claude-haiku-5-5" }).fallbacks, nil)
end

T["body: non-streaming caps max_tokens"] = function()
  local result = body({ messages = {}, stream = false })
  eq(result.stream, false)
  eq(result.max_tokens, 16000)
  eq(anthropic.params.max_tokens, 64000)
end

T["body: consecutive tool messages merge into one user message"] = function()
  local result = body({
    stream = true,
    messages = {
      { role = "user", content = "go" },
      { role = "llm", content = "", tools = { calls = { { id = "a", name = "x" }, { id = "b", name = "y" } } } },
      { role = "tool", content = "one", tools = { call_id = "a" } },
      { role = "tool", content = "two", tools = { call_id = "b", is_error = true } },
    },
  })
  eq(#result.messages, 3)
  eq(result.messages[3], {
    role = "user",
    content = {
      { type = "tool_result", tool_use_id = "a", content = "one" },
      { type = "tool_result", tool_use_id = "b", content = "two", is_error = true },
    },
  })
end

T["body: an llm message without data is rebuilt from content and tool calls"] = function()
  local result = body({
    stream = true,
    messages = {
      {
        role = "llm",
        content = "Looking",
        tools = { calls = { { id = "a", name = "x", arguments = { n = 1 } }, { id = "b", name = "y" } } },
      },
    },
  })
  local content = result.messages[1].content
  eq(result.messages[1].role, "assistant")
  eq(content[1], { type = "text", text = "Looking" })
  eq(content[2], { type = "tool_use", id = "a", name = "x", input = { n = 1 } })
  eq(vim.json.encode(content[3].input), "{}")
end

T["body: an empty llm content produces no text block"] = function()
  local result = body({ stream = true, messages = { { role = "llm", content = "" } } })
  eq(result.messages[1].content, {})
end

T["body: data from another provider is rebuilt, not sent"] = function()
  local result = body({
    stream = true,
    messages = { { role = "llm", content = "hi", data = { provider = "openai", content = { "x" } } } },
  })
  eq(result.messages[1].content, { { type = "text", text = "hi" } })
end

return T

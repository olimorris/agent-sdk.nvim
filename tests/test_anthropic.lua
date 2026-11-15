local sdk = require("agent_sdk")
local fake_http = dofile("tests/fake_http.lua")

local eq = MiniTest.expect.equality

local fake

local function stub(name)
  return fake_http.read("tests/stubs/" .. name)
end

local function anthropic(overrides)
  return require("agent_sdk.adapters").extend(
    "anthropic",
    vim.tbl_deep_extend("force", { env = { api_key = "cmd:printf dummy-key" } }, overrides or {})
  )
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

local function make(replies, opts)
  opts = opts or {}
  sdk.setup({ adapters = { anthropic = anthropic(opts.adapter) } })
  fake.on_call = function(call, number)
    fake_http.deliver(call, replies[number])
  end
  return sdk.session({
    adapter = sdk.adapter("anthropic"),
    model = opts.model,
    system_prompt = opts.system_prompt,
    on = opts.on,
  })
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      fake = fake_http.install()
    end,
    post_case = function()
      fake.restore()
    end,
  },
})

T["streams text, then usage and done"] = function()
  local log, on = recorder()
  local session = make({ stub("anthropic_text.txt") }, { on = on })
  local reply = session:prompt("hi"):wait(1000)

  eq(kinds(log), { "text", "text", "usage", "done" })
  eq(reply.text, "Hello, world")
  -- CodeCompanion's parse_tokens adds message_start's output token to message_delta's running total
  eq(reply.usage, { input_tokens = 25, output_tokens = 13 })
  eq(session.messages[2], { role = "llm", content = "Hello, world" })
end

T["thinking, text and a tool call"] = function()
  local log, on = recorder()
  local session = make({ stub("anthropic_thinking_tool.txt"), stub("anthropic_text.txt") }, { on = on })
  local reply = session:prompt("hi"):wait(1000)

  eq(kinds(log), { "reasoning", "reasoning", "text", "usage", "tool_call", "text", "text", "usage", "done" })
  eq(log[5][2].name, "read_file")
  eq(log[5][2].arguments, { path = "lua/foo.lua" })
  eq(reply.reasoning, "The nil check moved above the loop.")
  eq(session.messages[2], {
    role = "llm",
    content = "Hello",
    reasoning = { content = "The nil check moved above the loop.", _data = { signature = "EqQBCkYIBxgC" } },
    tools = {
      calls = {
        {
          id = "toolu_01A",
          type = "function",
          ["function"] = { name = "read_file", arguments = '{"path":"lua/foo.lua"}' },
        },
      },
    },
  })
end

T["the next request sends the thinking, text and tool call back with the result"] = function()
  local _, on = recorder()
  local session = make({ stub("anthropic_thinking_tool.txt"), stub("anthropic_text.txt") }, { on = on })
  session:prompt("hi"):wait(1000)

  local messages = fake.calls[2].body.messages
  eq(messages[1], { role = "user", content = { { type = "text", text = "hi" } } })
  eq(messages[2], {
    role = "assistant",
    content = {
      { type = "thinking", thinking = "The nil check moved above the loop.", signature = "EqQBCkYIBxgC" },
      { type = "text", text = "Hello" },
      { type = "tool_use", id = "toolu_01A", name = "read_file", input = { path = "lua/foo.lua" } },
    },
  })
  eq(messages[3], {
    role = "user",
    content = { { type = "tool_result", tool_use_id = "toolu_01A", content = "file contents", is_error = false } },
  })
end

T["a mid-stream error ends the prompt in one error and adds nothing"] = function()
  local log, on = recorder()
  local session = make({ stub("anthropic_error.txt") }, { on = on })
  local reply, err = session:prompt("hi"):wait(1000)
  vim.wait(50)

  eq(reply, nil)
  eq(err.message, "overloaded_error: Overloaded")
  eq(kinds(log), { "text", "error" })
  eq(session.messages, {})
end

T["a non-streaming reply goes through the same handlers"] = function()
  local log, on = recorder()
  local session = make({
    stub("anthropic_complete.json"),
    '{"type":"message","role":"assistant","content":[{"type":"text","text":"Done"}],"usage":{"input_tokens":30,"output_tokens":3}}',
  }, { on = on })
  local reply = session:prompt("hi", { stream = false }):wait(1000)

  eq(kinds(log), { "usage", "reasoning", "text", "tool_call", "usage", "text", "done" })
  eq(reply.text, "HelloDone")
  eq(reply.reasoning, "The nil check moved above the loop.")
  eq(reply.usage, { input_tokens = 55, output_tokens = 88 })
  eq(session.messages[2].reasoning._data.signature, "EqQBCkYIBxgC")
end

T["a tool call with no arguments sends an object back"] = function()
  local session = make({
    '{"type":"message","role":"assistant","content":[{"type":"tool_use","id":"t","name":"ls","input":{}}],"usage":{"input_tokens":1,"output_tokens":1}}',
    '{"type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}',
  }, { on = select(2, recorder()) })
  session:prompt("hi", { stream = false }):wait(1000)

  local tool_use = fake.calls[2].body.messages[2].content[1]
  eq(tool_use.name, "ls")
  eq(vim.json.encode(tool_use.input), "{}")
end

T["unreadable tool arguments end the prompt in an error naming the tool"] = function()
  local text = table.concat({
    'data: {"type":"message_start","message":{"role":"assistant","usage":{"input_tokens":1,"output_tokens":1}}}',
    'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"ls","input":{}}}',
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{oops"}}',
  }, "\n")
  local _, err = make({ text }):prompt("hi"):wait(1000)
  eq(err.message, "Could not read the arguments of the tool call ls")
end

T["body: the system prompt, the session's model and its max_tokens"] = function()
  make({ stub("anthropic_text.txt") }, { model = "claude-haiku-5-5", system_prompt = "Be brief" })
    :prompt("hi")
    :wait(1000)

  local body = fake.calls[1].body
  eq(body.system, { { type = "text", text = "Be brief" } })
  eq(body.model, "claude-haiku-5-5")
  eq(body.max_tokens, 64000)
  eq(body.thinking, { type = "adaptive" })
  eq(body.stream, true)
  eq(body.cache_control, { type = "ephemeral" })
end

T["body: the schema's default model and no system prompt"] = function()
  make({ stub("anthropic_text.txt") }):prompt("hi"):wait(1000)

  local body = fake.calls[1].body
  eq(body.model, "claude-sonnet-5")
  eq(body.system, nil)
end

T["body: the user can change the default model in their config"] = function()
  make({ stub("anthropic_text.txt") }, { adapter = { schema = { model = { default = "claude-opus-5-5" } } } })
    :prompt("hi")
    :wait(1000)
  eq(fake.calls[1].body.model, "claude-opus-5-5")
end

T["body: results for one reply's tool calls go back as one user message"] = function()
  local two_calls =
    '{"type":"message","role":"assistant","content":[{"type":"tool_use","id":"a","name":"x","input":{}},{"type":"tool_use","id":"b","name":"y","input":{}}],"usage":{"input_tokens":1,"output_tokens":1}}'
  local done =
    '{"type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}'
  make({ two_calls, done }, {
      on = {
        request = {
          tool_call = function(call)
            if call.id == "a" then
              call.respond("one")
            else
              call.fail("two")
            end
          end,
        },
      },
    })
    :prompt("go", { stream = false })
    :wait(1000)

  local messages = fake.calls[2].body.messages
  eq(#messages, 3)
  eq(messages[3], {
    role = "user",
    content = {
      { type = "tool_result", tool_use_id = "a", content = "one", is_error = false },
      { type = "tool_result", tool_use_id = "b", content = "two", is_error = true },
    },
  })
end

return T

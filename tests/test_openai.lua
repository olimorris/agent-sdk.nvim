local sdk = require("agent_sdk")
local fake_http = dofile("tests/fake_http.lua")

local eq = MiniTest.expect.equality

local fake

local function stub(name)
  return fake_http.read("tests/stubs/" .. name)
end

local function extend(name, overrides)
  return vim.tbl_deep_extend("force", { base = name, env = { api_key = "cmd:printf dummy-key" } }, overrides or {})
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
        call.respond("sunny")
      end,
    },
  }
  return log, on
end

local function count(log, kind)
  return #vim.tbl_filter(function(entry)
    return entry[1] == kind
  end, log)
end

local function make(replies, opts)
  opts = opts or {}
  sdk.setup({ adapters = { openai = opts.adapter or extend("openai") } })
  fake.on_call = function(call, number)
    fake_http.deliver(call, replies[number])
  end
  return sdk.session({
    adapter = sdk.adapter("openai"),
    model = opts.model,
    system_prompt = opts.system_prompt,
    on = opts.on,
  })
end

local done =
  '{"choices":[{"index":0,"message":{"role":"assistant","content":"Done"}}],"usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6}}'

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
  local session = make({ stub("openai_streaming.txt") }, { on = on })
  local reply = session:prompt("hi"):wait(1000)

  eq(reply.text, "Dynamic, Flexible. \n\nIs there anything specific you would like to know about Ruby?")
  eq(reply.usage, { input_tokens = 394, output_tokens = 18 })
  eq(log[#log][1], "done")
  eq(session.messages[2], { role = "llm", content = reply.text })
end

T["a non-streaming reply goes through the same handlers"] = function()
  local session = make({ stub("openai_no_streaming.txt") }, { on = select(2, recorder()) })
  local reply = session:prompt("hi", { stream = false }):wait(1000)

  eq(reply.text, "Elegant simplicity.")
  eq(reply.usage, { input_tokens = 343, output_tokens = 3 })
end

T["streamed tool calls are joined by index and answered"] = function()
  local log, on = recorder()
  local session = make({ stub("openai_tools_streaming.txt"), done }, { on = on })
  local reply = session:prompt("weather?"):wait(1000)

  eq(count(log, "tool_call"), 2)
  local calls = vim.tbl_map(
    function(entry)
      return { entry[2].id, entry[2].name, entry[2].arguments }
    end,
    vim.tbl_filter(function(entry)
      return entry[1] == "tool_call"
    end, log)
  )
  eq(calls, {
    { "call_RJU6xfk0OzQF3Gg9cOFS5RY7", "weather", { location = "London", units = "celsius" } },
    { "call_a9oyUMlFhnX8HvqzlfIx5Uek", "weather", { location = "Paris", units = "celsius" } },
  })
  eq(reply.text, "Done")
end

T["the next request sends the tool calls back with their results"] = function()
  local session = make({ stub("openai_tools_streaming.txt"), done }, { on = select(2, recorder()) })
  session:prompt("weather?"):wait(1000)

  local messages = fake.calls[2].body.messages
  eq(messages[1], { role = "user", content = "weather?" })
  eq(messages[2].role, "assistant")
  local calls = vim.tbl_map(function(call)
    return { call.id, call.type, call["function"].name, vim.json.decode(call["function"].arguments) }
  end, messages[2].tool_calls)
  eq(calls, {
    { "call_RJU6xfk0OzQF3Gg9cOFS5RY7", "function", "weather", { location = "London", units = "celsius" } },
    { "call_a9oyUMlFhnX8HvqzlfIx5Uek", "function", "weather", { location = "Paris", units = "celsius" } },
  })
  eq(messages[3], { role = "tool", content = "sunny", tool_call_id = "call_RJU6xfk0OzQF3Gg9cOFS5RY7" })
  eq(messages[4], { role = "tool", content = "sunny", tool_call_id = "call_a9oyUMlFhnX8HvqzlfIx5Uek" })
end

T["a mid-stream error ends the prompt in one error"] = function()
  local log, on = recorder()
  local text = table.concat({
    'data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Hel"}}]}',
    'data: {"error":{"type":"server_error","message":"The server had an error"}}',
  }, "\n")
  local reply, err = make({ text }, { on = on }):prompt("hi"):wait(1000)
  vim.wait(50)

  eq(reply, nil)
  eq(err.message, "server_error: The server had an error")
  eq(count(log, "error"), 1)
end

T["body: the system prompt, the session's model and streaming options"] = function()
  make({ stub("openai_streaming.txt") }, { model = "gpt-5", system_prompt = "Be brief" }):prompt("hi"):wait(1000)

  local body = fake.calls[1].body
  eq(body.messages[1], { role = "system", content = "Be brief" })
  eq(body.model, "gpt-5")
  eq(body.stream, true)
  eq(body.stream_options, { include_usage = true })
end

T["body: the user's reasoning effort goes to a model that can reason"] = function()
  make({ stub("openai_streaming.txt") }, {
      adapter = extend("openai", { parameters = { reasoning_effort = "high" } }),
      model = "gpt-5",
    })
    :prompt("hi")
    :wait(1000)
  eq(fake.calls[1].body.reasoning_effort, "high")
end

T["body: no reasoning effort for a model that can't reason"] = function()
  make({ stub("openai_streaming.txt") }, { adapter = extend("openai", { parameters = { reasoning_effort = "high" } }) })
    :prompt("hi")
    :wait(1000)

  local body = fake.calls[1].body
  eq(body.model, "gpt-4.1")
  eq(body.reasoning_effort, nil)
end

T["headers: the key goes in a bearer token"] = function()
  make({ stub("openai_streaming.txt") }):prompt("hi"):wait(1000)
  MiniTest.expect.no_equality(fake.calls[1].headers_text:find("Authorization: Bearer dummy-key", 1, true), nil)
end

T["parameters: thought_level becomes reasoning_effort and mode is dropped"] = function()
  make({ stub("openai_streaming.txt") }, {
      adapter = extend("openai", { parameters = { mode = "plan", thought_level = "high" } }),
      model = "gpt-5",
    })
    :prompt("hi")
    :wait(1000)

  local body = fake.calls[1].body
  eq(body.reasoning_effort, "high")
  eq(body.thought_level, nil)
  eq(body.mode, nil)
end

T["parameters: no thought_level for a model that can't reason"] = function()
  make({ stub("openai_streaming.txt") }, { adapter = extend("openai", { parameters = { thought_level = "high" } }) })
    :prompt("hi")
    :wait(1000)
  eq(fake.calls[1].body.reasoning_effort, nil)
end

T["extending"] = MiniTest.new_set()

T["extending"]["replaces the model list"] = function()
  sdk.setup({ adapters = { deepseek = extend("openai", { models = { ["deepseek-v4-flash"] = {} } }) } })
  eq(vim.tbl_keys(sdk.adapter("deepseek").models), { "deepseek-v4-flash" })
end

T["extending"]["parse_meta turns a provider's extra fields into reasoning"] = function()
  local adapter = extend("openai", {
    url = "https://api.deepseek.com/chat/completions",
    model = "deepseek-v4-flash",
    models = { ["deepseek-v4-flash"] = {} },
    handlers = {
      response = {
        parse_meta = function(self, args)
          local reasoning = args.data.extra.reasoning_content
          if reasoning then
            args.data.output.reasoning = { content = reasoning }
          end
          return args.data
        end,
      },
    },
  })
  local reply = make({ stub("deepseek_streaming.txt") }, { adapter = adapter, on = select(2, recorder()) })
    :prompt("hi")
    :wait(1000)

  eq(fake.calls[1].opts.url, "https://api.deepseek.com/chat/completions")
  eq(reply.text, "Elegant simplicity")
  eq(vim.startswith(reply.reasoning, "We need to explain Ruby in two words."), true)
  eq(reply.usage, { input_tokens = 9, output_tokens = 168 })
end

T["extending"]["an override can call the base adapter's handler"] = function()
  local openai = require("agent_sdk.adapters.http.openai")
  local adapter = extend("openai", {
    handlers = {
      request = {
        build_parameters = function(self, args)
          local params = openai.handlers.request.build_parameters(self, args)
          params.session_id = "abc"
          return params
        end,
      },
    },
  })
  make({ stub("openai_streaming.txt") }, { adapter = adapter }):prompt("hi"):wait(1000)

  local body = fake.calls[1].body
  eq(body.session_id, "abc")
  eq(body.stream, true)
end

return T

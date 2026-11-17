local sdk = require("agent_sdk")
local fake_http = dofile("tests/fake_http.lua")

local eq = MiniTest.expect.equality

local fake

local function stub(name)
  return fake_http.read("tests/stubs/" .. name)
end

local function anthropic(overrides)
  return vim.tbl_deep_extend(
    "force",
    { base = "anthropic", env = { api_key = "cmd:printf dummy-key" } },
    overrides or {}
  )
end

local function make(on, adapter)
  sdk.setup({ adapters = { anthropic = adapter or anthropic() } })
  return sdk.session({ adapter = sdk.adapter("anthropic"), on = on })
end

local function errors()
  local seen = {}
  return seen, {
    error = function(event)
      seen[#seen + 1] = event
    end,
  }
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

T["the key from the user's cmd: reaches the headers, not the command line"] = function()
  fake.on_call = function(call)
    fake_http.deliver(call, stub("anthropic_text.txt"))
  end
  make():prompt("hi"):wait(1000)

  local call = fake.calls[1]
  eq(call.headers_text:find("x-api-key: dummy-key", 1, true) ~= nil, true)
  eq(vim.tbl_contains(call.opts.raw, "dummy-key"), false)
  eq(call.opts.url, "https://api.anthropic.com/v1/messages")
end

T["the body and headers files are deleted once the request ends"] = function()
  fake.on_call = function(call)
    fake_http.deliver(call, stub("anthropic_text.txt"))
  end
  make():prompt("hi"):wait(1000)
  vim.wait(50)

  eq(vim.uv.fs_stat(fake.calls[1].body_path), nil)
  eq(vim.uv.fs_stat(fake.calls[1].headers_file), nil)
end

T["an HTTP error body becomes one error with the provider's message"] = function()
  fake.on_call = function(call)
    fake_http.deliver(
      call,
      '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}',
      401
    )
  end
  local seen, on = errors()
  local _, err = make(on):prompt("hi"):wait(1000)
  vim.wait(50)

  eq(err.message, "authentication_error: invalid x-api-key")
  eq(#seen, 1)
end

T["a curl failure becomes one error with stderr"] = function()
  fake.on_call = function(call)
    fake_http.fail(call, "Could not resolve host: api.anthropic.com")
  end
  local seen, on = errors()
  local _, err = make(on):prompt("hi"):wait(1000)
  vim.wait(50)

  eq(err.message, "Could not resolve host: api.anthropic.com")
  eq(#seen, 1)
end

T["a failing cmd: ends the prompt in an error naming the command"] = function()
  local session = make(nil, anthropic({ env = { api_key = "cmd:echo locked >&2; exit 1" } }))
  local _, err = session:prompt("hi"):wait(1000)

  eq(err.message, "agent-sdk.nvim: the command `echo locked >&2; exit 1` failed: locked")
  eq(#fake.calls, 0)
end

T["stopping a reply shuts the request down and ignores later output"] = function()
  local texts = {}
  local task
  fake.on_call = function(call)
    call.opts.stream('data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"a"}}')
    task:close()
    call.opts.stream('data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"b"}}')
  end
  task = make({
    text = function(event)
      texts[#texts + 1] = event.text
    end,
  }):prompt("hi")
  task:pwait(1000)
  vim.wait(50)

  eq(texts, { "a" })
  eq(fake.calls[1].job.killed, true)
end

T["closing the session stops a running request"] = function()
  local session = make()
  local task = session:prompt("hi")
  vim.wait(1000, function()
    return #fake.calls == 1
  end)
  session:close()
  task:pwait(1000)

  eq(fake.calls[1].job.killed, true)
end

T["stream = false sends one request and reads the whole body"] = function()
  fake.on_call = function(call)
    fake_http.deliver(
      call,
      '{"type":"message","role":"assistant","content":[{"type":"text","text":"Hi"}],"usage":{"input_tokens":3,"output_tokens":1}}'
    )
  end
  local reply = make():prompt("hi", { stream = false }):wait(1000)

  eq(fake.calls[1].body.stream, nil)
  eq(fake.calls[1].opts.stream, nil)
  eq(reply.text, "Hi")
  eq(reply.usage, { input_tokens = 3, output_tokens = 1 })
end

return T

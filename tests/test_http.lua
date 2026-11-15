local sdk = require("agent_sdk")
local fake_http = dofile("tests/fake_http.lua")

local eq = MiniTest.expect.equality

local SECRET = "sk-test-secret"

local adapter = {
  type = "http",
  url = "https://example.test/v1/chat",
  env = { key = "AGENT_SDK_TEST_KEY" },
  headers = { ["x-api-key"] = "${key}", ["content-type"] = "application/json" },
  model = "m",
  handlers = {
    request = {
      body = function(_, request)
        return { prompt = request.content[1].text, stream = request.stream, quote = 'a "b" \\ c' }
      end,
    },
    response = {
      chunk = function(_, data, state)
        state.seen = (state.seen or 0) + 1
        if data.t == "text" then
          return { { type = "text", text = data.v } }
        elseif data.t == "done" then
          return { { type = "done" } }
        end
        return {}
      end,
      complete = function(_, json)
        return { { type = "text", text = json.v }, { type = "done" } }
      end,
      error = function(_, json)
        return json.error and json.error.message or nil
      end,
    },
  },
}

local fake

local function session()
  sdk.setup({ adapters = { plain = adapter } })
  local log = {}
  local on = {
    text = function(event)
      log[#log + 1] = "text:" .. event.text
    end,
    done = function()
      log[#log + 1] = "done"
    end,
    error = function(event)
      log[#log + 1] = "error:" .. event.message
    end,
  }
  return sdk.session({ adapter = sdk.adapter("plain"), on = on }), log
end

local function sse(...)
  local out = {}
  for _, line in ipairs({ ... }) do
    out[#out + 1] = "event: x\ndata: " .. line .. "\n\n"
  end
  return table.concat(out)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      vim.env.AGENT_SDK_TEST_KEY = SECRET
      fake = fake_http.install()
    end,
    post_case = function()
      fake.restore()
      vim.env.AGENT_SDK_TEST_KEY = nil
    end,
  },
})

T["the real run is blocked in tests"] = function()
  fake.restore()
  local ok, err = pcall(require("agent_sdk.http").run, { "true" }, {}, function() end)
  eq(ok, false)
  eq(err:find("Test attempted a real HTTP request", 1, true) ~= nil, true)
end

T["the key is in the stdin config and absent from the command"] = function()
  local s = session()
  fake.on_call = function(call)
    fake_http.deliver(call, sse('{"t":"done"}'), 100)
  end
  s:prompt("hi"):wait(1000)

  local call = fake.calls[1]
  eq(call.cmd, { "curl", "--silent", "--show-error", "--no-buffer", "--config", "-" })
  eq(table.concat(call.cmd, " "):find(SECRET, 1, true), nil)
  eq(call.opts.stdin:find('header = "x-api-key: ' .. SECRET .. '"', 1, true) ~= nil, true)
  eq(call.opts.stdin:find('url = "https://example.test/v1/chat"', 1, true) ~= nil, true)
  eq(call.opts.stdin:find('request = "POST"', 1, true) ~= nil, true)
  eq(call.body_text:find(SECRET, 1, true), nil)
end

T["the body goes to a temp file that is deleted on exit"] = function()
  local s = session()
  fake.on_call = function(call)
    fake_http.deliver(call, sse('{"t":"done"}'), 100)
  end
  s:prompt("hi"):wait(1000)

  local call = fake.calls[1]
  eq(call.body, { prompt = "hi", stream = true, quote = 'a "b" \\ c' })
  vim.wait(50)
  eq(vim.uv.fs_stat(call.body_path), nil)
end

T["a data line split across chunks is parsed once"] = function()
  local s, log = session()
  fake.on_call = function(call)
    fake_http.deliver(call, sse('{"t":"text","v":"Hello"}', '{"t":"done"}'), 7)
  end
  s:prompt("hi"):wait(1000)
  eq(log, { "text:Hello", "done" })
end

T["lines that do not start with data: are ignored"] = function()
  local s, log = session()
  fake.on_call = function(call)
    local text = ": comment\nevent: x\nretry: 5\ndata: not json\n\n" .. sse('{"t":"text","v":"ok"}', '{"t":"done"}')
    fake_http.deliver(call, text, 5)
  end
  s:prompt("hi"):wait(1000)
  eq(log, { "text:ok", "done" })
end

T["an HTTP error body becomes one error event"] = function()
  local s, log = session()
  fake.on_call = function(call)
    fake_http.deliver(call, '{"error":{"message":"bad key"}}', 9, { code = 0, stdout = "", stderr = "" })
  end
  s:prompt("hi"):wait(1000)
  eq(log, { "error:bad key" })
end

T["a curl failure becomes one error event with stderr"] = function()
  local s, log = session()
  fake.on_call = function(call)
    call.on_exit({ code = 6, stdout = "", stderr = "curl: (6) Could not resolve host\n" })
  end
  s:prompt("hi"):wait(1000)
  eq(log, { "error:curl: (6) Could not resolve host" })
end

T["a curl failure with no stderr names the exit code"] = function()
  local s, log = session()
  fake.on_call = function(call)
    call.on_exit({ code = 18, stdout = "", stderr = "" })
  end
  s:prompt("hi"):wait(1000)
  eq(log, { "error:curl exited with code 18" })
end

T["a dropped stream after text gives exactly one error"] = function()
  local s, log = session()
  fake.on_call = function(call)
    fake_http.deliver(call, sse('{"t":"text","v":"a"}'), 100, { code = 18, stdout = "", stderr = "" })
  end
  s:prompt("hi"):wait(1000)
  eq(log, { "text:a", "error:curl exited with code 18" })
end

T["cancel kills the job, deletes the file and silences later output"] = function()
  local s, log = session()
  local call
  fake.on_call = function(c)
    call = c
    c.opts.stdout(nil, sse('{"t":"text","v":"a"}'))
  end
  local task = s:prompt("hi")
  vim.wait(1000, function()
    return #log > 0
  end)
  task:close()
  vim.wait(100)

  eq(call.job.killed, 15)
  eq(vim.uv.fs_stat(call.body_path), nil)

  call.opts.stdout(nil, sse('{"t":"text","v":"late"}'))
  call.on_exit({ code = 143, stdout = "", stderr = "" })
  vim.wait(50)
  eq(log, { "text:a", "error:The reply was stopped" })
end

T["closing the session cancels running requests"] = function()
  local s, log = session()
  local call
  fake.on_call = function(c)
    call = c
    c.opts.stdout(nil, sse('{"t":"text","v":"a"}'))
  end
  s:prompt("hi")
  vim.wait(1000, function()
    return #log > 0
  end)
  s:close()
  eq(call.job.killed, 15)
end

T["a missing environment variable ends the prompt in an error naming it"] = function()
  vim.env.AGENT_SDK_TEST_KEY = nil
  local s, log = session()
  s:prompt("hi"):wait(1000)
  eq(log, { "error:agent-sdk.nvim: the environment variable AGENT_SDK_TEST_KEY is not set" })
  eq(#fake.calls, 0)
end

T["stream = false goes through complete"] = function()
  local s, log = session()
  fake.on_call = function(call)
    fake_http.deliver(call, '{"v":"whole"}', 4)
  end
  s:prompt("hi", { stream = false }):wait(1000)
  eq(fake.calls[1].body.stream, false)
  eq(log, { "text:whole", "done" })
end

T["stream = false with an error body gives one error"] = function()
  local s, log = session()
  fake.on_call = function(call)
    fake_http.deliver(call, '{"error":{"message":"nope"}}', 100)
  end
  s:prompt("hi", { stream = false }):wait(1000)
  eq(log, { "error:nope" })
end

return T

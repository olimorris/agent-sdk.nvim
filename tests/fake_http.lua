local http = require("agent_sdk.http")

local M = {}

function M.install()
  local original = http.run
  local fake = { calls = {} }

  http.run = function(cmd, opts, on_exit)
    local job = { killed = nil }
    function job:kill(signal)
      self.killed = signal
    end

    local call = { cmd = cmd, opts = opts, on_exit = on_exit, job = job }
    call.body_path = opts.stdin:match('data%-binary = "@([^"]*)"')
    if call.body_path then
      local file = io.open(call.body_path, "rb")
      if file then
        call.body_text = file:read("*a")
        call.body = vim.json.decode(call.body_text)
        file:close()
      end
    end
    fake.calls[#fake.calls + 1] = call
    if fake.on_call then
      vim.schedule(function()
        fake.on_call(call, #fake.calls)
      end)
    end
    return job
  end

  function fake.restore()
    http.run = original
  end

  return fake
end

function M.deliver(call, text, size, exit)
  for index = 1, #text, size do
    call.opts.stdout(nil, text:sub(index, index + size - 1))
  end
  call.on_exit(exit or { code = 0, stdout = text, stderr = "" })
end

function M.read(path)
  local file = assert(io.open(path, "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

return M

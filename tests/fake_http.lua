local Client = require("agent_sdk.http").Client

local M = {}

local function read(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

M.read = function(path)
  return assert(read(path))
end

---Swap curl for a fake that records each request and lets the test answer it
function M.install()
  local post = Client.static.methods.post
  local original = post.default
  local fake = { calls = {} }

  post.default = function(opts)
    local job = {}
    function job.shutdown()
      job.killed = true
    end

    local headers_file = opts.raw[#opts.raw]:sub(2)
    local call = {
      opts = opts,
      job = job,
      body_path = opts.body_file,
      body = vim.json.decode(read(opts.body_file)),
      headers_text = read(headers_file),
      headers_file = headers_file,
    }
    fake.calls[#fake.calls + 1] = call
    if fake.on_call then
      vim.schedule(function()
        fake.on_call(call, #fake.calls)
      end)
    end
    return job
  end

  function fake.restore()
    post.default = original
  end

  return fake
end

---Answer a call the way curl would: line by line when streaming, then the whole response
---@param call table
---@param text string
---@param status? number
function M.deliver(call, text, status)
  if call.opts.stream then
    for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
      call.opts.stream(line)
    end
  end
  call.opts.callback({ status = status or 200, headers = {}, body = text, exit = 0 })
end

---@param call table
---@param stderr string
function M.fail(call, stderr)
  call.opts.on_error({ message = stderr, stderr = stderr, exit = 7 })
end

return M

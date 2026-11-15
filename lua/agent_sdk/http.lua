local env = require("agent_sdk.env")

local M = {}

function M.run(cmd, opts, on_exit)
  return vim.system(cmd, opts, on_exit)
end

local function quote(value)
  return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function curl_config(adapter, headers, body_path)
  local lines = { "url = " .. quote(adapter.url), 'request = "POST"' }
  for name, value in pairs(headers) do
    lines[#lines + 1] = "header = " .. quote(name .. ": " .. value)
  end
  lines[#lines + 1] = "data-binary = " .. quote("@" .. body_path)
  return table.concat(lines, "\n") .. "\n"
end

local function build_headers(adapter, values)
  local headers = {}
  for name, template in pairs(adapter.headers or {}) do
    headers[name] = template:gsub("%${([^}]+)}", function(key)
      return values[key]
    end)
  end
  return headers
end

local function is_terminal(event)
  return event.type == "done" or event.type == "error"
end

local function decode(text)
  local ok, json = pcall(vim.json.decode, text)
  if ok and type(json) == "table" then
    return json
  end
end

---@param adapter table
---@param opts table?
---@return agent_sdk.Connection
function M.connect(adapter, opts)
  local values, err = env.resolve_all(adapter.env)
  if not values then
    error(err, 0)
  end
  local headers = build_headers(adapter, values)
  local running = {}

  local connection = {}

  function connection:request(request, emit)
    local handlers = adapter.handlers
    local body = vim.json.encode(handlers.request.body(adapter, request))
    local body_path = vim.fn.tempname()
    local file = assert(io.open(body_path, "wb"))
    file:write(body)
    file:close()
    local id = {}

    local streaming = request.stream ~= false
    local state = {}
    local buffer = ""
    local stdout = {}
    local cancelled = false
    local finished = false
    local job

    local function send(events)
      for _, event in ipairs(events) do
        if finished then
          return
        end
        finished = is_terminal(event)
        emit(event)
      end
    end

    local function on_stdout(_, chunk)
      if cancelled or not chunk then
        return
      end
      stdout[#stdout + 1] = chunk
      if not streaming then
        return
      end
      buffer = buffer .. chunk
      while true do
        local newline = buffer:find("\n", 1, true)
        if not newline then
          break
        end
        local line = buffer:sub(1, newline - 1):gsub("\r$", "")
        buffer = buffer:sub(newline + 1)
        local payload = line:match("^data:(.*)$")
        local data = payload and decode(vim.trim(payload))
        if data then
          send(handlers.response.chunk(adapter, data, state))
        end
      end
    end

    local function on_exit(result)
      vim.uv.fs_unlink(body_path)
      running[id] = nil
      if cancelled then
        return
      end

      local raw = table.concat(stdout)
      local json = decode(raw)
      if not streaming and json and handlers.response.error(adapter, json) == nil then
        send(handlers.response.complete(adapter, json))
      end
      if finished then
        return
      end

      local message = json and handlers.response.error(adapter, json)
      if not message then
        local stderr = vim.trim(result.stderr or "")
        message = stderr ~= "" and stderr or ("curl exited with code %d"):format(result.code or -1)
      end
      send({ { type = "error", message = message } })
    end

    local cmd = { "curl", "--silent", "--show-error", "--no-buffer", "--config", "-" }
    job = M.run(cmd, { stdin = curl_config(adapter, headers, body_path), text = true, stdout = on_stdout }, on_exit)

    local function cancel()
      if cancelled then
        return
      end
      cancelled = true
      running[id] = nil
      pcall(job.kill, job, 15)
      vim.uv.fs_unlink(body_path)
    end
    running[id] = cancel
    return cancel
  end

  function connection:close()
    for _, cancel in pairs(running) do
      cancel()
    end
  end

  return connection
end

return M

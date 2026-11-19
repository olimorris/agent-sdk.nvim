--=============================================================================
-- HTTP Client - Ported from CodeCompanion's codecompanion/http.lua
--=============================================================================
local Curl = require("agent_sdk.utils.curl")

local adapter_utils = require("agent_sdk.adapters.utils")
local adapters = require("agent_sdk.adapters.http")
local async = require("agent_sdk.utils.async")
local log = require("agent_sdk.log")

---@class agent_sdk.HTTPPayload
---@field messages table
---@field tools? agent_sdk.Tool[]

---@class agent_sdk.HTTPClient
---@field adapter agent_sdk.HTTPAdapter
---@field methods table
local Client = {}
Client.static = {}

Client.static.methods = {
  post = { default = Curl.post },
  encode = { default = vim.json.encode },
  schedule = { default = vim.schedule },
}

---@async
---@param suffix string
---@param text string
---@return string path
local function write_temp_file(suffix, text)
  local path = vim.fn.tempname() .. suffix
  local ok, err = async.write_file(path, text)
  if not ok then
    error(("agent-sdk.nvim: couldn't write the request to %s: %s"):format(path, err), 0)
  end
  return path
end

---@param headers table
---@return string
local function format_headers(headers)
  local lines = {}
  for k, v in pairs(headers) do
    table.insert(lines, k .. ": " .. tostring(v))
  end
  return table.concat(lines, "\n")
end

---@param opts? table
---@return table
local function transform_static_methods(opts)
  local ret = {}
  for k, v in pairs(Client.static.methods) do
    if opts and opts[k] ~= nil then
      ret[k] = opts[k]
    else
      ret[k] = v.default
    end
  end
  return ret
end

---@param status? number
---@return boolean
local function is_auth_failure(status)
  return status == 401 or status == 403
end

---@async
---@param self agent_sdk.HTTPClient
---@return agent_sdk.HTTPAdapter|nil adapter, string|nil err
local function prepare_adapter(self)
  local adapter = vim.deepcopy(self.adapter)

  local ok = adapters.call_handler(adapter, "setup")
  if ok == false then
    return nil, "the adapter's setup handler failed"
  end

  return adapter_utils.get_env_vars(adapter)
end

---Merge the request body from the adapter handlers and payload
---@param adapter agent_sdk.HTTPAdapter
---@param payload agent_sdk.HTTPPayload
---@return table
function Client.merge_body(adapter, payload)
  return vim.tbl_deep_extend(
    "keep",
    adapters.call_handler(adapter, "build_parameters", {
      params = adapter_utils.set_env_vars(adapter, adapter.parameters),
      messages = payload.messages,
    }) or {},
    adapters.call_handler(adapter, "build_messages", { messages = payload.messages }) or {},
    payload.tools and adapters.call_handler(adapter, "build_tools", { tools = payload.tools }) or {},
    adapter.body and adapter.body or {},
    adapters.call_handler(adapter, "build_body", { payload = payload }) or {}
  )
end

---Assemble the curl args shared by every request, plus the adapter's headers file
---@async
---@param adapter agent_sdk.HTTPAdapter
---@param opts? { stream?: boolean }
---@return table raw, string headers_file
function Client.build_curl_args(adapter, opts)
  opts = opts or {}

  local raw = {
    "--retry",
    "3",
    "--retry-delay",
    "1",
    "--keepalive-time",
    "60",
    "--connect-timeout",
    "10",
  }

  if opts.stream then
    table.insert(raw, "--tcp-nodelay")
    table.insert(raw, "--no-buffer")
  end

  if adapter.raw then
    vim.list_extend(raw, adapter_utils.set_env_vars(adapter, adapter.raw))
  end

  local headers_file = write_temp_file(".headers", format_headers(adapter_utils.set_env_vars(adapter, adapter.headers)))
  vim.list_extend(raw, { "--header", "@" .. headers_file })

  return raw, headers_file
end

---@param args { adapter: agent_sdk.HTTPAdapter, opts?: table }
---@return agent_sdk.HTTPClient
function Client.new(args)
  args = args or {}
  return setmetatable({
    adapter = args.adapter,
    methods = transform_static_methods(args.opts),
  }, { __index = Client })
end

---@class agent_sdk.HTTPAdapter.RequestActions
---@field callback fun(err: nil|table, data: nil|string|table, adapter: agent_sdk.HTTPAdapter|nil) Runs once per streamed line, or once with the whole response
---@field done? fun() Runs when the request is complete

---Send a HTTP request and wait for it to end. Closing the task stops the request
---@async
---@param payload agent_sdk.HTTPPayload
---@param actions agent_sdk.HTTPAdapter.RequestActions
function Client:request(payload, actions)
  -- Make a copy of the adapter to ensure that we replace variables in every request
  local adapter, err = prepare_adapter(self)
  if not adapter then
    actions.callback({ message = err }, nil, nil)
    return
  end

  local body = self.methods.encode(Client.merge_body(adapter, payload))
  local url = adapter_utils.set_env_vars(adapter, adapter.url)
  -- Never log the headers or env: they hold the user's credentials
  log.debug("http request", adapter.name, url)
  log.trace("http body", body)
  local body_file = write_temp_file(".json", body)
  local raw, headers_file = Client.build_curl_args(adapter, { stream = adapter.opts and adapter.opts.stream })
  local temp_files = { body_file, headers_file }

  -- Capture streaming errors for use in final callback
  local stream_error_body = nil

  vim.async.await(function(finished)
    local request_opts = {
      body_file = body_file,
      raw = raw,
      url = url,
      callback = function(data)
        self.methods.schedule(function()
          if not adapter.opts.stream and data and data ~= "" then
            actions.callback(nil, data, adapter)
          end

          adapters.call_handler(adapter, "on_exit", { data = data })

          if actions.done then
            actions.done()
          end

          if data and data.status and data.status >= 400 then
            if is_auth_failure(data.status) then
              adapter_utils.clear_cached_cmds(adapter)
            end
            actions.callback({ message = string.format([[%d error: ]], data.status), stderr = data }, nil, adapter)
          elseif stream_error_body then
            actions.callback({ message = "Request failed", stderr = stream_error_body }, nil, adapter)
          end

          async.remove(temp_files)
          finished()
        end)
      end,
      on_error = function(curl_err)
        self.methods.schedule(function()
          actions.callback(curl_err, nil, adapter)
          async.remove(temp_files)
          finished()
        end)
      end,
    }

    if adapter.opts and adapter.opts.stream then
      -- This will be called multiple times until the stream is finished
      request_opts.stream = function(data)
        if data and data ~= "" then
          local cleaned = adapter_utils.clean_streamed_data(data)
          if cleaned:match('^%s*{"error"') or cleaned:match('^%s*{"type"%s*:%s*"error"') then
            stream_error_body = cleaned
            return
          end
        end
        actions.callback(nil, data, adapter)
      end
    end

    local job = self.methods.post(request_opts)
    return {
      close = function(_, callback)
        if job then
          pcall(job.shutdown)
        end
        async.remove(temp_files)
        if callback then
          callback()
        end
      end,
    }
  end)
end

--=============================================================================
-- The SDK's side: turn the client into the events a session handles
--=============================================================================

local M = { Client = Client }

---Read the provider's error message from an error body, or fall back to the client's message
---@param err table
---@return string
local function error_message(err)
  local body = type(err.stderr) == "table" and err.stderr.body or (err.stderr ~= err.message and err.stderr or nil)
  local ok, json = pcall(vim.json.decode, body or "")
  if ok and type(json) == "table" and type(json.error) == "table" then
    local message = json.error.message or "Unknown error"
    return json.error.type and (json.error.type .. ": " .. message) or message
  end
  if type(body) == "string" and vim.trim(body) ~= "" then
    return vim.trim(err.message or "") .. vim.trim(body)
  end
  return err.message or "Unknown error"
end

---Apply the session's model and settings to a copy of the adapter, as CodeCompanion's chat does
---@param adapter agent_sdk.HTTPAdapter
---@param request agent_sdk.Request
---@return agent_sdk.HTTPAdapter
local function resolve(adapter, request)
  local resolved = vim.deepcopy(adapter)
  resolved.opts = resolved.opts or {}
  resolved.opts.stream = request.stream ~= false
  resolved.parameters = resolved.parameters or {}
  resolved.temp = resolved.temp or {}
  resolved = adapters.map_schema_to_params(resolved)
  resolved.parameters.model = request.model or resolved.parameters.model or resolved.model
  resolved.parameters.thought_level = request.thought_level or resolved.parameters.thought_level
  return resolved
end

---@param adapter agent_sdk.HTTPAdapter
---@return agent_sdk.Connection
function M.connect(adapter)
  local running = {}
  local connection = {}

  function connection:request(request, emit)
    local resolved = resolve(adapter, request)
    local messages = vim.deepcopy(request.messages or {})
    if request.system_prompt then
      table.insert(messages, 1, { role = "system", content = request.system_prompt })
    end
    messages = adapters.map_roles(resolved.roles or {}, messages)

    local tools, reasoning = {}, {}
    local prepared, had_error, cancelled = nil, false, false
    local id = {}

    local client = Client.new({ adapter = resolved })
    local actions = {
      callback = function(err, data, used)
        prepared = used or prepared
        if cancelled or had_error then
          return
        end
        if err then
          had_error = true
          running[id] = nil
          return emit({ type = "error", message = error_message(err) })
        end

        local total = adapters.call_handler(prepared, "parse_tokens", { data = data })
        if type(total) == "number" then
          local input = prepared.temp.input_tokens or 0
          emit({ type = "usage", input_tokens = input, output_tokens = total - input })
        end

        local result = adapters.call_handler(prepared, "parse_chat", { data = data, tools = tools })
        if result and result.extra and adapters.get_handler(prepared, "parse_meta") then
          result = adapters.call_handler(prepared, "parse_meta", { data = result })
        end
        local output = result and result.status == "success" and result.output
        if not output then
          return
        end
        if output.reasoning then
          reasoning[#reasoning + 1] = output.reasoning
          if output.reasoning.content and output.reasoning.content ~= "" then
            emit({ type = "reasoning", text = output.reasoning.content })
          end
        end
        if output.content and output.content ~= "" then
          emit({ type = "text", text = output.content })
        end
      end,

      -- Deferred a tick, as the client reports an HTTP error after `done`
      done = function()
        vim.schedule(function()
          if cancelled or had_error then
            return
          end
          running[id] = nil
          prepared = prepared or resolved
          local calls = #tools > 0 and adapters.call_handler(prepared, "format_calls", { tools = tools }) or {}
          for _, call in ipairs(calls) do
            local arguments = call["function"].arguments
            local ok, decoded = pcall(vim.json.decode, arguments ~= "" and arguments or "{}")
            if not ok then
              had_error = true
              return emit({
                type = "error",
                message = ("Could not read the arguments of the tool call %s"):format(call["function"].name),
              })
            end
            emit({ type = "tool_call", id = call.id, name = call["function"].name, arguments = decoded })
          end
          local formed = #reasoning > 0 and adapters.call_handler(prepared, "build_reasoning", { data = reasoning })
          emit({ type = "done", reasoning = formed or nil })
        end)
      end,
    }

    local task = vim.async.run(function()
      client:request(
        { messages = messages, tools = request.tools and #request.tools > 0 and request.tools or nil },
        actions
      )
    end)
    -- A Lua error inside the request would otherwise end the task without a word to the plugin
    task:on_complete(function(err)
      if err and not cancelled and not had_error then
        had_error = true
        running[id] = nil
        emit({ type = "error", message = "agent-sdk.nvim: " .. tostring(err) })
      end
    end)

    local function cancel()
      if cancelled then
        return
      end
      cancelled = true
      running[id] = nil
      task:close()
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

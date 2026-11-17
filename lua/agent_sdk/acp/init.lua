--=============================================================================
-- ACP Connection - Adapted from CodeCompanion's codecompanion/acp/init.lua
--=============================================================================
local METHODS = require("agent_sdk.acp.methods")
local Prompt = require("agent_sdk.acp.prompt")
local acp_adapter = require("agent_sdk.adapters.acp")
local adapter_utils = require("agent_sdk.adapters.utils")
local async = require("agent_sdk.utils.async")
local log = require("agent_sdk.log")
local options = require("agent_sdk.acp.config_options")

---@class agent_sdk.ACP.Connection
---@field adapter agent_sdk.ACPAdapter
---@field resolved agent_sdk.ACPAdapter The adapter with its environment variables resolved
---@field system_prompt string|nil
---@field session_id string|nil
---@field options table[] The agent's current session config options
---@field agent_info table|nil The agent's `initialize` result
---@field active_prompt agent_sdk.ACP.Prompt|nil
---@field _process table|nil
---@field _pending table<number, fun(result: any, err: string|nil)>
---@field _next_id number
---@field _stdout string
---@field _stderr string[]
---@field _waiting fun(ok: boolean, err: string|nil)[]|nil
---@field _idle fun()[] Prompts waiting for a cancelled turn to end
---@field _exited string|nil Why the agent's process exited after its session started
local Connection = {}
Connection.__index = Connection

-- Tests replace this so no real agent is started
Connection.system = vim.system

---@param args { adapter: agent_sdk.ACPAdapter, system_prompt?: string }
---@return agent_sdk.ACP.Connection
function Connection.new(args)
  return setmetatable({
    adapter = args.adapter,
    resolved = args.adapter,
    options = {},
    system_prompt = args.system_prompt,
    _next_id = 1,
    _pending = {},
    _idle = {},
    _stderr = {},
    _stdout = "",
  }, Connection)
end

--=============================================================================
-- JSON-RPC over the agent's stdio
--=============================================================================

---@param message table
---@return boolean
function Connection:write(message)
  if not self._process then
    return false
  end
  message.jsonrpc = "2.0"
  log.debug("acp send", message)
  return (pcall(self._process.write, self._process, vim.json.encode(message) .. "\n"))
end

---Send a request and call back with its result, or its error message
---@param method string
---@param params table
---@param callback fun(result: any, err: string|nil)
---@return number id
function Connection:send(method, params, callback)
  local id = self._next_id
  self._next_id = id + 1
  self._pending[id] = callback
  if not self:write({ id = id, method = method, params = params }) then
    self._pending[id] = nil
    vim.schedule(function()
      callback(nil, "the agent isn't running")
    end)
  end
  return id
end

---Send a request and yield until its response arrives
---@param method string
---@param params table
---@param timeout? number
---@return any result, string|nil err
function Connection:request(method, params, timeout)
  local function send()
    return vim.async.await(function(callback)
      local id = self:send(method, params, callback)
      return {
        close = function(_, closed)
          self._pending[id] = nil
          if closed then
            closed()
          end
        end,
      }
    end)
  end
  if not timeout then
    return send()
  end

  local ok, result, err = async.timeout(timeout, send)
  if not ok then
    return nil, ("%s timed out"):format(method)
  end
  return result, err
end

---@param id number
---@param result table
function Connection:respond(id, result)
  self:write({ id = id, result = result })
end

---@param method string
---@param params table
function Connection:notify(method, params)
  self:write({ method = method, params = params })
end

---@param data string
function Connection:on_stdout(data)
  -- A message can arrive split across reads, so only complete lines are parsed
  local lines = vim.split(self._stdout .. data, "\n", { plain = true })
  self._stdout = table.remove(lines)
  for _, line in ipairs(lines) do
    self:dispatch(line)
  end
end

---@param err table
---@return string
local function error_message(err)
  if type(err.data) == "table" and err.data.error then
    return err.data.error
  end
  return err.message or "Unknown error"
end

local DISPATCH = {
  [METHODS.SESSION_UPDATE] = function(self, message)
    local update = message.params.update or {}
    if update.sessionUpdate == "config_option_update" then
      self.options = update.configOptions or self.options
    elseif self.active_prompt then
      self.active_prompt:on_update(update)
    end
  end,
  [METHODS.SESSION_REQUEST_PERMISSION] = function(self, message)
    if self.active_prompt then
      self.active_prompt:on_permission(message.id, message.params)
    else
      self:respond(message.id, { outcome = { outcome = "cancelled" } })
    end
  end,
}

---@param line string
function Connection:dispatch(line)
  local ok, message = pcall(vim.json.decode, line)
  if not ok or type(message) ~= "table" then
    log.warn("acp unreadable line", line)
    return
  end
  -- Streamed updates arrive once per chunk, so they'd bury everything else at debug
  if message.method == "session/update" then
    log.trace("acp recv", message)
  else
    log.debug("acp recv", message)
  end

  if message.method then
    local handler = DISPATCH[message.method]
    if handler and type(message.params) == "table" then
      handler(self, message)
    elseif message.id ~= nil then
      -- An unanswered request leaves the agent waiting forever
      self:write({
        id = message.id,
        error = handler and { code = -32602, message = "Invalid params" }
          or { code = -32601, message = "Method not found: " .. tostring(message.method) },
      })
    end
  elseif message.id and self._pending[message.id] then
    local callback = self._pending[message.id]
    self._pending[message.id] = nil
    callback(message.result, message.error and error_message(message.error))
  end
end

--=============================================================================
-- The agent's process
--=============================================================================

---Copy the adapter and resolve its environment variables
---@return agent_sdk.ACPAdapter|nil adapter, string|nil err
function Connection:resolve_adapter()
  local adapter, err = adapter_utils.get_env_vars(vim.deepcopy(self.adapter))
  if not adapter then
    return nil, err
  end
  adapter.defaults = adapter.defaults or {}
  adapter.initialize = adapter_utils.set_env_vars(adapter, adapter.initialize)
  adapter.defaults.auth_method = adapter_utils.set_env_vars(adapter, adapter.defaults.auth_method)
  adapter.defaults.mcpServers = adapter_utils.set_env_vars(adapter, adapter.defaults.mcpServers)
  local commands = adapter.commands or {}
  local command = commands.selected or commands.default
  if type(command) ~= "table" or #command == 0 then
    return nil,
      ('the adapter %s has no command to start its agent. Set commands.default, e.g. { "claude-agent-acp" }'):format(
        tostring(adapter.name)
      )
  end
  adapter.command = adapter_utils.set_env_vars(adapter, command)
  return adapter
end

---@return boolean success, string|nil err
function Connection:spawn()
  local adapter, err = self:resolve_adapter()
  if not adapter then
    return false, err
  end
  self.resolved = adapter

  if acp_adapter.get_handler(adapter, "setup") and not acp_adapter.call_handler(adapter, "setup") then
    return false, "the adapter's setup handler failed"
  end

  self._stdout, self._stderr = "", {}
  local process
  local ok, result = pcall(
    Connection.system,
    adapter.command,
    {
      stdin = true,
      cwd = vim.fn.getcwd(),
      env = adapter.env_replaced or {},
      stdout = vim.schedule_wrap(function(_, data)
        if data then
          self:on_stdout(data)
        end
      end),
      stderr = function(_, data)
        table.insert(self._stderr, data)
        if data then
          log.debug("agent stderr", data)
        end
      end,
    },
    vim.schedule_wrap(function(obj)
      self:on_exit(process, obj.code)
    end)
  )

  if not ok then
    return false, ("couldn't start %s: %s"):format(adapter.command[1], result)
  end
  log.info("agent started", adapter.command)
  process = result
  self._process = process
  return true
end

---Fail everything waiting on the agent and forget its session
---@param message string
function Connection:reset(message)
  local pending, prompt = self._pending, self.active_prompt
  self._process, self.session_id, self.active_prompt, self._pending = nil, nil, nil, {}

  for _, callback in pairs(pending) do
    pcall(callback, nil, message)
  end
  if prompt then
    prompt:fail(message)
  end
  self:_wake()
end

---@param process table
---@param code number
function Connection:on_exit(process, code)
  -- A process stopped by close may exit after its replacement has started
  if process ~= self._process then
    return
  end
  acp_adapter.call_handler(self.resolved, "on_exit", { code = code })

  local last = vim.trim(table.concat(self._stderr)):match("([^\n]*)$")
  local message = ("the agent exited with code %s%s"):format(tostring(code), last ~= "" and (": " .. last) or "")
  log.info(message)
  -- A new process would start with none of the agent's history, so the plugin must start a new session
  if self.session_id then
    self._exited = message
  end
  self:reset(message)
end

function Connection:close()
  local handle = self._process
  if handle then
    self:reset("the agent was stopped")
    pcall(handle.kill, handle, "sigterm")
  end
end

--=============================================================================
-- The session
--=============================================================================

---Start the agent and its session, once, however many prompts are waiting on it
---@return boolean success, string|nil err
function Connection:open()
  if self.session_id then
    return true
  end
  if self._exited then
    return false, self._exited
  end
  if self._waiting then
    return vim.async.await(function(callback)
      table.insert(self._waiting, callback)
    end)
  end

  self._waiting = {}
  -- An error must still release the waiters, or every later prompt waits forever
  local ok, success, err = pcall(self._handshake, self)
  if not ok then
    success, err = false, tostring(success)
  end
  if not success then
    self:close()
  end

  local waiting = self._waiting
  self._waiting = nil
  for _, callback in ipairs(waiting) do
    vim.schedule(function()
      callback(success, err)
    end)
  end
  return success, err
end

---@return number milliseconds
function Connection:_timeout()
  return self.resolved.defaults.timeout or 20000
end

---@return boolean success, string|nil err
function Connection:_handshake()
  local ok, err = self:spawn()
  if not ok then
    return false, err
  end

  local info
  info, err = self:request(METHODS.INITIALIZE, self.resolved.initialize, self:_timeout())
  if type(info) ~= "table" then
    return false, "the agent couldn't start: " .. (err or "no reply to initialize")
  end
  self.agent_info = info

  ok, err = self:_authenticate()
  if not ok then
    return false, err
  end

  local session
  session, err = self:request(METHODS.SESSION_NEW, {
    cwd = vim.fn.getcwd(),
    mcpServers = self.resolved.defaults.mcpServers or {},
    systemPrompt = self:_system_prompt(),
  }, self:_timeout())
  if type(session) ~= "table" or not session.sessionId then
    return false, "the agent couldn't start a session: " .. (err or "no session id") .. self:_auth_hint()
  end
  self.session_id = session.sessionId
  self.options = session.configOptions or {}

  return self:_apply_options()
end

---@return string[]
function Connection:_auth_method_ids()
  return vim.tbl_map(function(method)
    return method.id
  end, self.agent_info.authMethods or {})
end

---Point the user at the agent's auth methods when they haven't picked one, as an unsigned-in agent can't start a session
---@return string
function Connection:_auth_hint()
  local ids = self:_auth_method_ids()
  if #ids == 0 or self.resolved.defaults.auth_method then
    return ""
  end
  return (". If the agent needs signing in, give it a credential in env or set defaults.auth_method to one of: %s"):format(
    table.concat(ids, ", ")
  )
end

---Sign in through the adapter's auth handler, or else the auth method the user picked
---Without either, the agent signs in with what it already has, such as a token in env or its own login
---@return boolean success, string|nil err
function Connection:_authenticate()
  local ids = self:_auth_method_ids()
  if #ids == 0 or acp_adapter.call_handler(self.resolved, "auth") == true then
    return true
  end

  local method_id = self.resolved.defaults.auth_method
  if not method_id then
    return true
  end
  if not vim.tbl_contains(ids, method_id) then
    return false, ("the agent doesn't offer the auth method %s, only %s"):format(method_id, table.concat(ids, ", "))
  end

  local _, err = self:request(METHODS.AUTHENTICATE, { methodId = method_id }, self:_timeout())
  if err then
    return false, ("the agent couldn't sign in with %s: %s"):format(method_id, err)
  end
  return true
end

---The system prompt, appended to the agent's own, or nil when the agent can't take one
---@return table|nil
function Connection:_system_prompt()
  local capabilities = self.agent_info.agentCapabilities or {}
  local supported = type(capabilities.sessionCapabilities) == "table"
    and type(capabilities.sessionCapabilities.systemPrompt) == "table"
  if not supported or type(self.system_prompt) ~= "string" or self.system_prompt == "" then
    return nil
  end
  return { mode = "append", content = { { type = "text", text = self.system_prompt } } }
end

---Apply the user's `defaults.session_config_options`
---@return boolean success, string|nil err
function Connection:_apply_options()
  local desired = self.resolved.defaults.session_config_options or {}
  for _, category in ipairs(options.categories(desired)) do
    local value = desired[category]
    if type(value) == "function" then
      value = value(self.resolved)
    end
    if type(value) == "string" and value ~= "" then
      local change, err = options.change(self.options, category, value)
      if err then
        return false, err
      end
      if change then
        local ok
        ok, err = self:set_option(change.id, change.value)
        if not ok then
          return false, err
        end
      end
    end
  end
  return true
end

---@param config_id string
---@param value string
---@return boolean success, string|nil err
function Connection:set_option(config_id, value)
  local result, err = self:request(
    METHODS.SESSION_SET_CONFIG_OPTION,
    { sessionId = self.session_id, configId = config_id, value = value },
    self:_timeout()
  )
  if err then
    return false, ("the agent couldn't set %s to %s: %s"):format(config_id, value, err)
  end
  if type(result) == "table" and result.configOptions then
    self.options = result.configOptions
  end
  return true
end

---@return string[]
function Connection:models()
  local opt = options.find(self.options, "model")
  return opt and options.values(opt) or {}
end

---@param messages table
---@param handlers agent_sdk.ACP.Prompt.Handlers
---@return agent_sdk.ACP.Prompt
function Connection:prompt(messages, handlers)
  return Prompt.new(self, messages, handlers)
end

function Connection:_wake()
  local idle = self._idle
  self._idle = {}
  for _, callback in ipairs(idle) do
    vim.schedule(callback)
  end
end

---@param prompt agent_sdk.ACP.Prompt
function Connection:release(prompt)
  if self.active_prompt == prompt then
    self.active_prompt = nil
    self:_wake()
  end
end

---Wait for a cancelled turn to end, giving up on an agent that never answers it
function Connection:wait_idle()
  while self.active_prompt do
    local prompt = self.active_prompt
    local released = async.timeout(self:_timeout(), function()
      vim.async.await(function(callback)
        table.insert(self._idle, callback)
      end)
    end)
    if not released then
      self:release(prompt)
    end
  end
end

--=============================================================================
-- The SDK's side: turn the connection into the events a session handles
--=============================================================================

---Fields from the spec's ToolCall, with the agent's own extras under `meta`
---@param tool_call table
---@return table
local function to_tool_call(tool_call)
  return {
    id = tool_call.toolCallId,
    title = tool_call.title,
    kind = tool_call.kind,
    status = tool_call.status,
    content = tool_call.content,
    locations = tool_call.locations,
    arguments = tool_call.rawInput,
    output = tool_call.rawOutput,
    meta = tool_call._meta,
  }
end

---@param usage table
---@return table
local function to_usage(usage)
  return {
    type = "usage",
    input_tokens = usage.inputTokens,
    output_tokens = usage.outputTokens,
    cache_read_input_tokens = usage.cachedReadTokens,
    cache_creation_input_tokens = usage.cachedWriteTokens,
  }
end

---@param adapter agent_sdk.ACPAdapter
---@param opts { mode?: string, model?: string, system_prompt?: string, thought_level?: string }
---@return agent_sdk.Connection
function Connection.connect(adapter, opts)
  opts = opts or {}
  local agent = vim.deepcopy(adapter)
  agent.defaults = agent.defaults or {}
  local params = vim.tbl_extend("force", agent.parameters or {}, {
    mode = opts.mode,
    model = opts.model,
    thought_level = opts.thought_level,
  })
  agent.defaults.session_config_options = vim.tbl_extend(
    "force",
    agent.defaults.session_config_options or {},
    require("agent_sdk.adapters.parameters").translate("acp", params)
  )

  local connection = Connection.new({ adapter = agent, system_prompt = opts.system_prompt })
  local client = {}

  function client:request(request, emit)
    local state = { cancelled = false }

    local function emit_tool_call(kind)
      return function(tool_call)
        emit(vim.tbl_extend("force", to_tool_call(tool_call), { type = kind }))
      end
    end

    vim.async.run(function()
      local ok, err = connection:open()
      if state.cancelled then
        return
      end
      if not ok then
        return emit({ type = "error", message = "agent-sdk.nvim: " .. err })
      end
      adapter.capabilities.models = connection:models()

      connection:wait_idle()
      if state.cancelled then
        return
      end

      state.prompt = connection:prompt(request.content, {
        text = function(text)
          emit({ type = "text", text = text })
        end,
        reasoning = function(text)
          emit({ type = "reasoning", text = text })
        end,
        tool_call = emit_tool_call("tool_call"),
        tool_update = emit_tool_call("tool_update"),
        permission = function(permission)
          emit({
            type = "permission_request",
            tool_call = to_tool_call(permission.tool_call or {}),
            options = vim.tbl_map(function(option)
              return { id = option.optionId, name = option.name, kind = option.kind }
            end, permission.options),
            respond = permission.respond,
          })
        end,
        done = function(stop_reason, usage)
          if type(usage) == "table" then
            emit(to_usage(usage))
          end
          if stop_reason == "refusal" then
            return emit({ type = "error", message = "The agent declined this request" })
          elseif stop_reason == "cancelled" then
            return emit({ type = "error", message = "The agent stopped the reply", cancelled = true })
          end
          emit({ type = "done" })
        end,
        error = function(message)
          emit({ type = "error", message = message })
        end,
      })
      state.prompt:send()
    end)

    return function()
      state.cancelled = true
      if state.prompt then
        state.prompt:cancel()
      end
    end
  end

  function client:close()
    connection:close()
  end

  return client
end

return Connection

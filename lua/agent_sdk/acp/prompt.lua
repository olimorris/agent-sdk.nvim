--=============================================================================
-- Prompt - Ported from CodeCompanion's codecompanion/acp/prompt_builder.lua
--=============================================================================
local METHODS = require("agent_sdk.acp.methods")
local acp_adapter = require("agent_sdk.adapters.acp")

---@class agent_sdk.ACP.Prompt.Handlers
---@field text? fun(text: string)
---@field reasoning? fun(text: string)
---@field tool_call? fun(tool_call: table)
---@field tool_update? fun(tool_call: table)
---@field permission? fun(request: { tool_call: table, options: table[], respond: fun(option_id: string|nil) })
---@field done? fun(stop_reason: string, usage: table|nil)
---@field error? fun(message: string)

---@class agent_sdk.ACP.Prompt
---@field connection agent_sdk.ACP.Connection
---@field messages table
---@field handlers agent_sdk.ACP.Prompt.Handlers
---@field _finished boolean
---@field _permissions table<number, fun(option_id: string|nil)> Permission requests still waiting on an answer
local Prompt = {}
Prompt.__index = Prompt

---@param connection agent_sdk.ACP.Connection
---@param messages table
---@param handlers agent_sdk.ACP.Prompt.Handlers
---@return agent_sdk.ACP.Prompt
function Prompt.new(connection, messages, handlers)
  local built = acp_adapter.call_handler(connection.resolved, "build_messages", {
    messages = messages,
    capabilities = connection.agent_info and connection.agent_info.agentCapabilities,
  })

  return setmetatable({
    connection = connection,
    handlers = handlers,
    messages = built or messages,
    _finished = false,
    _permissions = {},
  }, Prompt)
end

function Prompt:send()
  self.connection.active_prompt = self
  self.connection:send(METHODS.SESSION_PROMPT, {
    sessionId = self.connection.session_id,
    prompt = self.messages,
  }, function(result, err)
    if err then
      return self:fail(err)
    end
    self:complete(result.stopReason, result.usage)
  end)
end

---Mark the prompt finished, so a late response or a second cancel does nothing
---@return boolean first
function Prompt:_finish()
  if self._finished then
    return false
  end
  self._finished = true
  self.connection:release(self)
  return true
end

---@param handler? function
---@param ... any
local function call(handler, ...)
  if handler then
    handler(...)
  end
end

---@param update table
function Prompt:on_update(update)
  local kind = update.sessionUpdate
  local content = update.content
  local text = type(content) == "table" and content.type == "text" and content.text or nil

  if kind == "agent_message_chunk" and text and text ~= "" then
    call(self.handlers.text, text)
  elseif kind == "agent_thought_chunk" and text and text ~= "" then
    call(self.handlers.reasoning, text)
  elseif kind == "tool_call" then
    call(self.handlers.tool_call, update)
  elseif kind == "tool_call_update" then
    call(self.handlers.tool_update, update)
  end
end

---@param id number
---@param params table
function Prompt:on_permission(id, params)
  local answered = false
  local function respond(option_id)
    if answered then
      return
    end
    answered = true
    self._permissions[id] = nil
    local outcome = option_id and { outcome = "selected", optionId = option_id } or { outcome = "cancelled" }
    self.connection:respond(id, { outcome = outcome })
  end
  self._permissions[id] = respond

  if not self.handlers.permission then
    return respond(nil)
  end
  self.handlers.permission({ tool_call = params.toolCall, options = params.options or {}, respond = respond })
end

---@param message string
function Prompt:fail(message)
  if self:_finish() then
    call(self.handlers.error, message)
  end
end

---@param stop_reason string
---@param usage? table
function Prompt:complete(stop_reason, usage)
  if self:_finish() then
    call(self.handlers.done, stop_reason, usage)
  end
end

function Prompt:cancel()
  if not self:_finish() then
    return
  end
  if self.connection.session_id then
    self.connection:notify(METHODS.SESSION_CANCEL, { sessionId = self.connection.session_id })
  end
  -- Ref: https://agentclientprotocol.com/protocol/prompt-turn#cancellation
  for _, respond in pairs(self._permissions) do
    respond(nil)
  end
end

return Prompt

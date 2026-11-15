local M = {}

---@class agent_sdk.Request
---@field content table[]
---@field messages table[]?
---@field model string?
---@field system_prompt string?
---@field stream boolean

---@class agent_sdk.Connection
---@field request fun(self: agent_sdk.Connection, request: agent_sdk.Request, emit: fun(event: table)): fun()?
---@field close fun(self: agent_sdk.Connection)

---@class agent_sdk.Handlers
---@field text fun(event: table)?
---@field reasoning fun(event: table)?
---@field usage fun(event: table)?
---@field tool_update fun(update: table)?
---@field done fun(reply: agent_sdk.Reply)?
---@field error fun(event: table)?
---@field request { tool_call: fun(call: table)?, permission: fun(request: table)? }?

---@class agent_sdk.SessionOpts
---@field adapter agent_sdk.Adapter
---@field model string?
---@field system_prompt string?
---@field on agent_sdk.Handlers?

---@class agent_sdk.PromptOpts
---@field stream boolean?
---@field on agent_sdk.Handlers?

---@class agent_sdk.Reply
---@field text string
---@field reasoning string?
---@field usage table?
---@field tool_calls table[]

---@class agent_sdk.Session
---@field messages table[]
---@field adapter agent_sdk.Adapter
---@field model string?
---@field system_prompt string?
---@field on agent_sdk.Handlers
---@field closed boolean
local Session = {}
Session.__index = Session

local live = {}
local autocmd_created = false

local function close_all_on_exit()
  if autocmd_created then
    return
  end
  autocmd_created = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("agent_sdk", { clear = true }),
    callback = function()
      for _, session in ipairs(vim.tbl_keys(live)) do
        session:close()
      end
    end,
  })
end

local function stopped_event()
  return { type = "error", message = "The reply was stopped", cancelled = true }
end

local function call(handler, arg)
  local ok, err = pcall(handler, arg)
  if not ok then
    vim.schedule(function()
      error(err, 0)
    end)
  end
end

local function normalise(content)
  if type(content) == "string" then
    return { { type = "text", text = content } }
  end
  return content
end

local function new_round()
  return { text = {}, reasoning = {}, tool_calls = {}, results = {}, owed = 0, answered = 0 }
end

local function new_turn(session, content, opts)
  local turn = {
    prompt = content,
    on = opts.on or {},
    stream = opts.stream ~= false,
    finished = false,
    stopping = false,
    held = {},
    text = {},
    reasoning = {},
    tool_calls = {},
    round = new_round(),
    messages = { { role = "user", content = content } },
  }
  turn.request = {
    content = normalise(content),
    model = session.model,
    system_prompt = session.system_prompt,
    stream = turn.stream,
  }
  if session.adapter.type == "http" then
    turn.request.messages = vim.deepcopy(session.messages)
    vim.list_extend(turn.request.messages, vim.deepcopy(turn.messages))
  end
  return turn
end

local function build_reply(turn)
  return {
    text = table.concat(turn.text),
    reasoning = #turn.reasoning > 0 and table.concat(turn.reasoning) or nil,
    usage = turn.usage,
    tool_calls = turn.tool_calls,
  }
end

local requests = { tool_call = "tool_call", permission_request = "permission" }

local function handler_for(session, turn, kind)
  local request = requests[kind]
  if request then
    return (turn.on.request or {})[request] or (session.on.request or {})[request]
  end
  return turn.on[kind] or session.on[kind]
end

local function deliver(session, turn, event)
  local handler = handler_for(session, turn, event.type)
  if handler then
    return call(handler, event)
  end
  if event.type == "tool_call" and event.needs_result then
    event.fail("The plugin has no handler for tool calls")
  end
end

local function flush(session, turn)
  local held = turn.held
  turn.held = {}
  for _, event in ipairs(held) do
    deliver(session, turn, event)
  end
end

local function finish(session, turn, reply, err)
  turn.finished = true
  if session.turn == turn then
    session.turn = nil
  end

  if reply then
    vim.list_extend(session.messages, turn.messages)
    flush(session, turn)
    local handler = handler_for(session, turn, "done")
    if handler then
      call(handler, reply)
    end
  else
    err = vim.tbl_extend("force", err, { prompt = turn.prompt })
    deliver(session, turn, err)
  end

  turn.result = { reply, err, n = 2 }
  if turn.waiter then
    turn.waiter(reply, err)
  end
end

local enqueue

local function emit(session, turn, event)
  if turn.finished or turn.stopping then
    return
  end
  enqueue(session, turn, event)
end

local function send(session, turn)
  local connection = session.connection
  local ok, cancel = pcall(connection.request, connection, turn.request, function(event)
    emit(session, turn, event)
  end)
  if not ok then
    return emit(session, turn, { type = "error", message = tostring(cancel) })
  end
  if type(cancel) == "function" and not turn.finished then
    turn.cancel = cancel
  end
end

local function send_tool_results(session, turn)
  local round = turn.round
  if round.sent or not round.ended or round.answered < round.owed or turn.finished or turn.stopping then
    return
  end
  round.sent = true

  local results = {}
  for index in ipairs(round.tool_calls) do
    local message = round.results[index]
    turn.messages[#turn.messages + 1] = message
    results[#results + 1] = {
      type = "tool_result",
      tool_call_id = message.tools.call_id,
      content = message.content,
      is_error = message.tools.is_error,
    }
  end

  turn.round = new_round()
  turn.request = {
    content = results,
    messages = vim.list_extend(vim.deepcopy(session.messages), vim.deepcopy(turn.messages)),
    model = session.model,
    system_prompt = session.system_prompt,
    stream = turn.stream,
  }
  send(session, turn)
end

local function end_round(session, turn, raw)
  local round = turn.round
  round.ended = true
  turn.cancel = nil

  for field, value in pairs(round.usage or {}) do
    turn.usage = turn.usage or {}
    turn.usage[field] = type(value) == "number" and (turn.usage[field] or 0) + value or value
  end

  local assistant = { role = "llm", content = table.concat(round.text) }
  if #round.reasoning > 0 then
    assistant.reasoning = { content = table.concat(round.reasoning) }
  end
  if raw.reasoning then
    assistant.reasoning = raw.reasoning
  end
  if #round.tool_calls > 0 then
    assistant.tools = {
      calls = vim.tbl_map(function(call)
        return {
          id = call.id,
          type = "function",
          ["function"] = {
            name = call.name,
            arguments = vim.json.encode(call.arguments or vim.empty_dict()),
          },
        }
      end, round.tool_calls),
    }
  end
  turn.messages[#turn.messages + 1] = assistant

  if round.owed == 0 then
    return finish(session, turn, build_reply(turn))
  end
  flush(session, turn)
  send_tool_results(session, turn)
end

local function update_tool_call(turn, update)
  for _, tool_call in ipairs(turn.tool_calls) do
    if tool_call.id == update.id then
      for field, value in pairs(update) do
        if field ~= "type" then
          tool_call[field] = value
        end
      end
    end
  end
end

local function tool_call_event(session, turn, raw)
  local tool_call = vim.tbl_extend("force", {}, raw)
  tool_call.type = nil
  local round = turn.round
  local index = #round.tool_calls + 1
  round.tool_calls[index] = tool_call
  turn.tool_calls[#turn.tool_calls + 1] = vim.deepcopy(tool_call)

  if session.adapter.type ~= "http" then
    local function ignore() end
    return vim.tbl_extend("force", raw, { needs_result = false, respond = ignore, fail = ignore })
  end

  round.owed = round.owed + 1
  local function answer(content, is_error)
    if round.results[index] or turn.finished or turn.stopping then
      return
    end
    round.results[index] = { role = "tool", content = content, tools = { call_id = raw.id, is_error = is_error } }
    round.answered = round.answered + 1
    local update =
      { type = "tool_update", id = raw.id, status = is_error and "failed" or "completed", output = content }
    update_tool_call(turn, update)
    deliver(session, turn, update)
    send_tool_results(session, turn)
  end

  return vim.tbl_extend("force", raw, {
    needs_result = true,
    respond = function(content)
      answer(content)
    end,
    fail = function(message)
      answer(message, true)
    end,
  })
end

local function reject(options, respond)
  for _, kind in ipairs({ "reject_once", "reject_always" }) do
    for _, option in ipairs(options or {}) do
      if option.kind == kind then
        return respond(option.id)
      end
    end
  end
  respond(nil)
end

local function request_permission(session, turn, raw)
  local transport_respond = raw.respond
  local responded = false
  local function respond(option_id)
    if responded or turn.finished then
      return
    end
    responded = true
    transport_respond(option_id)
  end

  local handler = handler_for(session, turn, "permission_request")
  if not handler then
    return reject(raw.options, respond)
  end
  call(handler, vim.tbl_extend("force", raw, { respond = respond }))
end

local function process(session, turn, raw)
  if turn.finished then
    return
  end

  local kind = raw.type
  if kind == "done" then
    return end_round(session, turn, raw)
  elseif kind == "error" then
    return finish(session, turn, nil, raw)
  elseif kind == "permission_request" then
    return request_permission(session, turn, raw)
  end

  local event = raw
  local round = turn.round
  if kind == "text" then
    turn.text[#turn.text + 1] = raw.text
    round.text[#round.text + 1] = raw.text
  elseif kind == "reasoning" then
    turn.reasoning[#turn.reasoning + 1] = raw.text
    round.reasoning[#round.reasoning + 1] = raw.text
  elseif kind == "usage" then
    local fields = vim.tbl_extend("force", {}, raw)
    fields.type = nil
    round.usage = vim.tbl_extend("force", round.usage or {}, fields)
  elseif kind == "tool_call" then
    event = tool_call_event(session, turn, raw)
  elseif kind == "tool_update" then
    update_tool_call(turn, raw)
  end

  if turn.stream then
    deliver(session, turn, event)
  else
    turn.held[#turn.held + 1] = event
  end
end

local function drain(session)
  if session.draining then
    return
  end
  session.draining = true
  while #session.queue > 0 do
    local item = table.remove(session.queue, 1)
    local ok, err = pcall(process, session, item.turn, item.event)
    if not ok then
      vim.schedule(function()
        error(err, 0)
      end)
    end
  end
  session.draining = false
end

function enqueue(session, turn, event)
  session.queue[#session.queue + 1] = { turn = turn, event = event }
  if vim.in_fast_event() then
    vim.schedule(function()
      drain(session)
    end)
  else
    drain(session)
  end
end

local function cancel_turn(session, turn)
  if turn.finished or turn.stopping then
    return
  end
  turn.stopping = true
  if turn.cancel then
    pcall(turn.cancel)
  end
  enqueue(session, turn, stopped_event())
end

local function connect(session)
  local connection = session.adapter.connect(session.adapter, {
    model = session.model,
    system_prompt = session.system_prompt,
  })
  assert(type(connection) == "table", "adapter.connect must return a connection")
  session.connection = connection
  live[session] = true
  close_all_on_exit()
end

local function start(session, turn)
  if turn.finished or turn.stopping then
    return
  end

  if not session.connection then
    local ok, err = pcall(connect, session)
    if not ok then
      return emit(session, turn, { type = "error", message = tostring(err) })
    end
  end
  send(session, turn)
end

---@param opts agent_sdk.SessionOpts
---@return agent_sdk.Session
function M.new(opts)
  opts = opts or {}
  local adapter = opts.adapter
  if type(adapter) ~= "table" then
    error("agent-sdk.nvim: sdk.session() needs an adapter from sdk.adapter()", 2)
  end
  if type(adapter.connect) ~= "function" then
    error("agent-sdk.nvim: adapter has no connect function", 2)
  end

  return setmetatable({
    adapter = adapter,
    model = opts.model or adapter.model,
    system_prompt = opts.system_prompt,
    on = opts.on or {},
    messages = {},
    queue = {},
    closed = false,
  }, Session)
end

---@param content string|table[]
---@param opts agent_sdk.PromptOpts?
function Session:prompt(content, opts)
  if self.closed then
    error("agent-sdk.nvim: the session is closed", 2)
  end
  if self.turn then
    error("agent-sdk.nvim: a reply is already in progress", 2)
  end

  local turn = new_turn(self, content, opts or {})
  self.turn = turn

  local task = vim.async.run(function()
    return vim.async.await(function(callback)
      if turn.result then
        callback(turn.result[1], turn.result[2])
      else
        turn.waiter = callback
      end
    end)
  end)

  task:on_complete(function()
    cancel_turn(self, turn)
  end)

  -- A handler could run before the plugin has the task if the request started here
  vim.schedule(function()
    start(self, turn)
  end)

  return task
end

---@param content string|table[]
---@param opts agent_sdk.PromptOpts?
---@return agent_sdk.Reply?, table?
function Session:ask(content, opts)
  local task = self:prompt(content, opts)
  local ok, reply, err = vim.async.pawait(task)
  if ok then
    return reply, err
  end
  local stopped = reply == "closed" and stopped_event() or { type = "error", message = tostring(reply) }
  stopped.prompt = content
  return nil, stopped
end

---@param messages table[]
---@return boolean ok
---@return string? err
function Session:set_messages(messages)
  if self.turn then
    error("agent-sdk.nvim: a reply is already in progress", 2)
  end
  if self.adapter.type == "acp" then
    return false, "agent-sdk.nvim: an ACP agent owns its history, so the messages were not changed"
  end
  self.messages = vim.deepcopy(messages)
  return true
end

function Session:close()
  if self.closed then
    return
  end
  self.closed = true
  live[self] = nil
  if self.turn then
    cancel_turn(self, self.turn)
  end
  if self.connection then
    pcall(self.connection.close, self.connection)
    self.connection = nil
  end
end

return M

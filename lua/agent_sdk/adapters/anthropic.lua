local FALLBACK_MODELS = {
  ["claude-fable-5-2"] = true,
  ["claude-fable-5-1"] = true,
  ["claude-opus-5-5"] = true,
  ["claude-opus-5"] = true,
  ["claude-sonnet-5-5"] = true,
}

local NON_STREAMING_MAX_TOKENS = 16000

local function object(value)
  if type(value) == "table" and next(value) == nil then
    return vim.empty_dict()
  end
  return value or vim.empty_dict()
end

local function assistant_content(message)
  local data = message.data
  if type(data) == "table" and data.provider == "anthropic" then
    return data.content
  end

  local content = {}
  if type(message.content) == "string" and message.content ~= "" then
    content[#content + 1] = { type = "text", text = message.content }
  end
  for _, call in ipairs((message.tools or {}).calls or {}) do
    content[#content + 1] = { type = "tool_use", id = call.id, name = call.name, input = object(call.arguments) }
  end
  return content
end

local function convert_messages(messages)
  local converted = {}
  local last_results

  for _, message in ipairs(messages) do
    if message.role == "tool" then
      local result = {
        type = "tool_result",
        tool_use_id = message.tools.call_id,
        content = message.content,
        is_error = message.tools.is_error and true or nil,
      }
      if last_results then
        last_results[#last_results + 1] = result
      else
        last_results = { result }
        converted[#converted + 1] = { role = "user", content = last_results }
      end
    else
      last_results = nil
      if message.role == "llm" then
        converted[#converted + 1] = { role = "assistant", content = assistant_content(message) }
      else
        converted[#converted + 1] = { role = "user", content = message.content }
      end
    end
  end

  return converted
end

local function body(adapter, request)
  local result = vim.deepcopy(adapter.params or {})
  result.model = request.model or adapter.model
  result.stream = request.stream
  if request.stream == false and (result.max_tokens or 0) > NON_STREAMING_MAX_TOKENS then
    result.max_tokens = NON_STREAMING_MAX_TOKENS
  end
  if request.system_prompt then
    result.system = request.system_prompt
  end
  if FALLBACK_MODELS[result.model] then
    result.fallbacks = "default"
  end
  result.messages = convert_messages(request.messages or {})
  return result
end

local function usage_event(usage, with_input)
  local event = { type = "usage", output_tokens = usage.output_tokens }
  if with_input then
    event.input_tokens = usage.input_tokens
    for _, field in ipairs({ "cache_read_input_tokens", "cache_creation_input_tokens" }) do
      if type(usage[field]) == "number" then
        event[field] = usage[field]
      end
    end
  end
  return event
end

local function error_message(err)
  if type(err) ~= "table" then
    return "Unknown error"
  end
  local message = err.message or "Unknown error"
  return err.type and (err.type .. ": " .. message) or message
end

local function finish(stop_reason, blocks)
  if stop_reason == "refusal" then
    return { type = "error", message = "The model declined this request" }
  end
  return { type = "done", data = { provider = "anthropic", content = blocks } }
end

local function chunk(_, data, state)
  state.blocks = state.blocks or {}
  state.inputs = state.inputs or {}
  local kind = data.type

  if kind == "message_start" then
    local usage = (data.message or {}).usage
    return usage and { usage_event(usage, true) } or {}
  end

  if kind == "content_block_start" then
    local block = vim.deepcopy(data.content_block)
    state.blocks[data.index + 1] = block
    if block.type == "tool_use" then
      state.inputs[data.index + 1] = {}
    end
    return {}
  end

  if kind == "content_block_delta" then
    local block = state.blocks[data.index + 1]
    local delta = data.delta or {}
    if not block then
      return {}
    end
    if delta.type == "text_delta" then
      block.text = (block.text or "") .. delta.text
      return { { type = "text", text = delta.text } }
    elseif delta.type == "thinking_delta" then
      block.thinking = (block.thinking or "") .. delta.thinking
      return delta.thinking ~= "" and { { type = "reasoning", text = delta.thinking } } or {}
    elseif delta.type == "signature_delta" then
      block.signature = delta.signature
    elseif delta.type == "input_json_delta" and state.inputs[data.index + 1] then
      table.insert(state.inputs[data.index + 1], delta.partial_json)
    end
    return {}
  end

  if kind == "content_block_stop" then
    local block = state.blocks[data.index + 1]
    if not block or block.type ~= "tool_use" then
      return {}
    end
    local json = table.concat(state.inputs[data.index + 1] or {})
    local ok, decoded = true, vim.empty_dict()
    if json ~= "" then
      ok, decoded = pcall(vim.json.decode, json)
    end
    if not ok then
      return { { type = "error", message = ("Could not read the arguments of the tool call %s"):format(block.name) } }
    end
    block.input = object(decoded)
    return { { type = "tool_call", id = block.id, name = block.name, arguments = block.input } }
  end

  if kind == "message_delta" then
    state.stop_reason = (data.delta or {}).stop_reason
    local usage = data.usage
    return usage and usage.output_tokens and { usage_event(usage, false) } or {}
  end

  if kind == "message_stop" then
    return { finish(state.stop_reason, state.blocks) }
  end

  if kind == "error" then
    return { { type = "error", message = error_message(data.error) } }
  end

  return {}
end

local function complete(_, json)
  if json.type == "error" then
    return { { type = "error", message = error_message(json.error) } }
  end

  local events = {}
  if json.usage then
    events[#events + 1] = usage_event(json.usage, true)
  end
  for _, block in ipairs(json.content or {}) do
    if block.type == "thinking" and block.thinking and block.thinking ~= "" then
      events[#events + 1] = { type = "reasoning", text = block.thinking }
    elseif block.type == "text" then
      events[#events + 1] = { type = "text", text = block.text }
    elseif block.type == "tool_use" then
      events[#events + 1] = { type = "tool_call", id = block.id, name = block.name, arguments = object(block.input) }
    end
  end
  events[#events + 1] = finish(json.stop_reason, json.content)
  return events
end

local function error_body(_, json)
  if json.type == "error" then
    return error_message(json.error)
  end
end

return {
  type = "http",
  url = "https://api.anthropic.com/v1/messages",
  env = { api_key = "ANTHROPIC_API_KEY" },
  headers = {
    ["content-type"] = "application/json",
    ["x-api-key"] = "${api_key}",
    ["anthropic-version"] = "2026-10-21",
    ["anthropic-beta"] = "server-side-fallback-2026-07-01",
  },
  model = "claude-opus-5-5",
  capabilities = {
    tools = false,
    vision = false,
    reasoning = true,
    models = { "claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5" },
  },
  params = {
    max_tokens = 64000,
    thinking = { type = "adaptive", display = "summarized" },
  },
  handlers = {
    request = { body = body },
    response = { chunk = chunk, complete = complete, error = error_body },
  },
}

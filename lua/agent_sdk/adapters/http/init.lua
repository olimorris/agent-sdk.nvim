--=============================================================================
-- HTTP adapters - Ported from CodeCompanion's codecompanion/adapters/http/init.lua
--=============================================================================

---@class agent_sdk.HTTPAdapter
---@field name string
---@field formatted_name string
---@field type "http"
---@field roles { llm: string, user: string }
---@field opts table
---@field url string
---@field env? table
---@field env_replaced? table
---@field headers table
---@field parameters? table
---@field temp? table
---@field raw? string[]
---@field handlers agent_sdk.HTTPAdapter.Handlers
---@field schema table

---@class agent_sdk.HTTPAdapter.Handlers
---@field lifecycle? { setup?: (fun(self): boolean), on_exit?: fun(self, args: { data: table }) }
---@field request? { build_parameters?: function, build_messages?: function, build_reasoning?: function, build_body?: function }
---@field response? { parse_chat?: function, parse_tokens?: function }
---@field tools? { format_calls?: function }

local M = {}

local CATEGORIES = { "lifecycle", "request", "response", "tools" }

---@param adapter agent_sdk.HTTPAdapter
---@param name string
---@return function|nil
function M.get_handler(adapter, name)
  for _, category in ipairs(CATEGORIES) do
    local handlers = adapter.handlers and adapter.handlers[category]
    if handlers and handlers[name] then
      return handlers[name]
    end
  end
end

---@param adapter agent_sdk.HTTPAdapter
---@param name string
---@param args? table
---@return any|nil
function M.call_handler(adapter, name, args)
  local handler = M.get_handler(adapter, name)
  if handler then
    return handler(adapter, args or {})
  end
end

---Turn the schema's defaults into settings
---@param adapter agent_sdk.HTTPAdapter
---@return table
function M.make_from_schema(adapter)
  local settings = {}
  for key, value in pairs(adapter.schema or {}) do
    if type(value.enabled) ~= "function" or value.enabled(adapter) then
      local default = value.default
      if type(default) == "function" then
        default = default(adapter)
      end
      if default ~= nil then
        settings[key] = default
      end
    end
  end
  return settings
end

---Write each setting to where its schema entry's `mapping` points, e.g. `parameters` or `temp`
---@param adapter agent_sdk.HTTPAdapter
---@param settings? table
---@return agent_sdk.HTTPAdapter
function M.map_schema_to_params(adapter, settings)
  settings = settings or M.make_from_schema(adapter)

  for k, v in pairs(settings) do
    local mapping = adapter.schema[k] and adapter.schema[k].mapping
    if mapping then
      local current = adapter
      for segment in mapping:gmatch("[^.]+") do
        current[segment] = current[segment] or {}
        current = current[segment]
      end

      local key_segments = vim.split(k, ".", { plain = true })
      for i = 1, #key_segments - 1 do
        current[key_segments[i]] = current[key_segments[i]] or {}
        current = current[key_segments[i]]
      end
      current[key_segments[#key_segments]] = v
    end
  end

  return adapter
end

---Replace roles in the messages with the adapter's defined roles
---@param roles table
---@param messages table
---@return table
function M.map_roles(roles, messages)
  for _, message in ipairs(messages) do
    if message.role then
      message.role = roles[message.role:lower()] or message.role
    end
  end
  return messages
end

return M

---@class agent_sdk.ACPAdapter
---@field name string
---@field formatted_name string
---@field type "acp"
---@field roles table
---@field opts? table
---@field commands { default: string[], selected?: string[], [string]: string[] }
---@field command? string[] The command that starts the agent, resolved from `commands`
---@field defaults? { mcpServers?: table, timeout?: number, auth_method?: string, session_config_options?: table<string, string> }
---@field parameters? table<string, string> The agent's session config options by category, e.g. `mode`, `model` or `thought_level`. Merged over `defaults.session_config_options`
---@field env? table
---@field env_replaced? table
---@field initialize table The params sent with `initialize`. CodeCompanion calls this `parameters`
---@field handlers? agent_sdk.ACPAdapter.Handlers

---@class agent_sdk.ACPAdapter.Handlers
---@field lifecycle? { setup?: (fun(self): boolean), auth?: (fun(self): boolean), on_exit?: fun(self, args: { code: number }), teardown?: fun(self) }
---@field request? { build_messages?: (fun(self, args: { messages: table, capabilities: table }): table) }

local Adapter = {}

---@param adapter agent_sdk.ACPAdapter
---@param name string
---@return function|nil
function Adapter.get_handler(adapter, name)
  for _, category in ipairs({ "lifecycle", "request" }) do
    local handlers = adapter.handlers and adapter.handlers[category]
    if handlers and handlers[name] then
      return handlers[name]
    end
  end
end

---@param adapter agent_sdk.ACPAdapter
---@param name string
---@param args? table
---@return any|nil
function Adapter.call_handler(adapter, name, args)
  local handler = Adapter.get_handler(adapter, name)
  if handler then
    return handler(adapter, args or {})
  end
end

return Adapter

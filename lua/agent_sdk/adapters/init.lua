local M = {}

---@class agent_sdk.Capabilities
---@field tools boolean
---@field vision boolean
---@field reasoning boolean
---@field models string[]

---@class agent_sdk.Adapter
---@field name string
---@field type "http"|"acp"
---@field model string?
---@field capabilities agent_sdk.Capabilities
---@field connect fun(adapter: agent_sdk.Adapter, opts: { model: string?, system_prompt: string? }): agent_sdk.Connection
---@field has_model fun(self: agent_sdk.Adapter, model: string): boolean

local configured = {}

local Adapter = {}
Adapter.__index = Adapter

function Adapter:has_model(model)
  local models = self.capabilities.models
  return #models == 0 or vim.tbl_contains(models, model)
end

---@return agent_sdk.Capabilities
function M.default_capabilities()
  return { tools = false, vision = false, reasoning = false, models = {} }
end

---@param adapters table<string, table|string>?
function M.configure(adapters)
  configured = adapters or {}
end

---@param name string
---@return table?
local function load_builtin(name)
  local ok, adapter = pcall(require, "agent_sdk.adapters." .. name)
  if ok and type(adapter) == "table" then
    return adapter
  end
end

---@param name string
---@return agent_sdk.Adapter?, string?
function M.resolve(name)
  local value = configured[name]
  if value == nil then
    return nil,
      ('agent-sdk.nvim: no adapter named "%s". Add it to require("agent_sdk").setup({ adapters = ... })'):format(
        tostring(name)
      )
  end

  if type(value) == "string" then
    local builtin = load_builtin(value)
    if not builtin then
      return nil, ('agent-sdk.nvim: adapter "%s" names the built-in "%s", which does not exist'):format(name, value)
    end
    value = builtin
  end

  if type(value) ~= "table" then
    return nil, ('agent-sdk.nvim: adapter "%s" must be a table or the name of a built-in adapter'):format(name)
  end

  local adapter = vim.deepcopy(value)
  adapter.name = name
  adapter.capabilities = vim.tbl_deep_extend("force", M.default_capabilities(), adapter.capabilities or {})
  return setmetatable(adapter, Adapter)
end

---@param base table|string
---@param overrides table?
---@return table
function M.extend(base, overrides)
  local base_table = base
  if type(base) == "string" then
    base_table = load_builtin(base)
    if not base_table then
      error(('agent-sdk.nvim: no built-in adapter named "%s"'):format(base), 2)
    end
  end
  return vim.tbl_deep_extend("force", vim.deepcopy(base_table), overrides or {})
end

return M

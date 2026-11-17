local M = {}

---@class agent_sdk.Capabilities
---@field tools boolean
---@field vision boolean
---@field reasoning boolean
---@field models string[]

---@class agent_sdk.Model
---@field formatted_name? string
---@field meta? { context_window?: number, max_tokens?: number }
---@field opts? { can_reason?: boolean, has_vision?: boolean }

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
  for _, kind in ipairs({ "http", "acp" }) do
    local ok, adapter = pcall(require, ("agent_sdk.adapters.%s.%s"):format(kind, name))
    if ok and type(adapter) == "table" then
      return adapter
    end
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
    value = { base = value }
  end
  if type(value) ~= "table" then
    return nil, ('agent-sdk.nvim: adapter "%s" must be a table or the name of a built-in adapter'):format(name)
  end

  local adapter, err = M.from_base(value)
  if not adapter then
    return nil, ('agent-sdk.nvim: adapter "%s" %s'):format(name, err)
  end
  adapter.name = name
  -- The session sends its model with every request, so without this the user's parameters.model would never win
  if type(adapter.parameters) == "table" and type(adapter.parameters.model) == "string" then
    adapter.model = adapter.parameters.model
  end
  local opts = adapter.opts or {}
  local models = type(adapter.models) == "table" and vim.tbl_keys(adapter.models) or {}
  table.sort(models)
  adapter.capabilities = vim.tbl_deep_extend(
    "force",
    M.default_capabilities(),
    { tools = opts.tools == true, vision = opts.vision == true, models = models },
    adapter.capabilities or {}
  )
  if adapter.type == "http" and adapter.connect == nil then
    adapter.connect = require("agent_sdk.http").connect
  elseif adapter.type == "acp" and adapter.connect == nil then
    adapter.connect = require("agent_sdk.acp").connect
  end
  return setmetatable(adapter, Adapter)
end

---Copy the built-in that `config.base` names and merge the rest of `config` over it
---A config without `base` is a complete adapter and is copied as it is
---@param config table
---@return table|nil adapter, string|nil err
function M.from_base(config)
  local overrides = vim.deepcopy(config)
  local name = overrides.base
  overrides.base = nil
  if name == nil then
    return overrides
  end

  local base = type(name) == "string" and load_builtin(name)
  if not base then
    return nil, ('has the base "%s", which isn\'t a built-in adapter'):format(tostring(name))
  end

  local adapter = vim.tbl_deep_extend("force", vim.deepcopy(base), overrides)

  -- Merging would leave the base's models in the list, e.g. GPT models for DeepSeek built on openai
  if overrides.models ~= nil then
    adapter.models = overrides.models
  end

  return adapter
end

return M

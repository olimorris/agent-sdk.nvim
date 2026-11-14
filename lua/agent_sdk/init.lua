local adapters = require("agent_sdk.adapters")

local M = {}

---@class agent_sdk.Config
---@field adapters table<string, table|string>

---@param opts agent_sdk.Config?
function M.setup(opts)
  adapters.configure((opts or {}).adapters)
end

---@param name string
---@return agent_sdk.Adapter?, string?
function M.adapter(name)
  return adapters.resolve(name)
end

---@param opts agent_sdk.SessionOpts
---@return agent_sdk.Session
function M.session(opts)
  return require("agent_sdk.session").new(opts)
end

return M

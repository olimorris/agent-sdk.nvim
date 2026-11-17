local adapters = require("agent_sdk.adapters")

local M = {}

---@class agent_sdk.Config
---@field adapters? table<string, table|string>
---@field log_level? vim.log.levels|"trace"|"debug"|"info"|"warn"|"error"|"off"

---@param level any
---@return vim.log.levels|nil
local function to_level(level)
  if type(level) == "number" then
    return level
  end
  if type(level) == "string" then
    return vim.log.levels[level:upper()]
  end
end

---@param opts agent_sdk.Config?
---@return boolean ok, string|nil err
function M.setup(opts)
  opts = opts or {}
  adapters.configure(opts.adapters)
  if opts.log_level ~= nil then
    local level = to_level(opts.log_level)
    if not level then
      return false,
        ("agent-sdk.nvim: log_level %s isn't one of trace, debug, info, warn, error or off"):format(
          vim.inspect(opts.log_level)
        )
    end
    vim.log.set_level(M.log, level)
  end
  return true
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

-- Created on first use, so requiring the SDK doesn't create the log directory
return setmetatable(M, {
  __index = function(_, key)
    if key == "log" then
      return require("agent_sdk.log")
    end
  end,
})

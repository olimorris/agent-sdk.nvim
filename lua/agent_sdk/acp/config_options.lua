--=============================================================================
-- Session config options - Ported from CodeCompanion's codecompanion/acp/defaults.lua
--=============================================================================
local M = {}

---Flatten grouped select options into a list of values
---@param options table[]
---@return table[]
function M.flatten(options)
  return vim
    .iter(options or {})
    :map(function(item)
      -- Ref: https://agentclientprotocol.com/protocol/schema#sessionconfigselectgroup
      return item.group and item.options or { item }
    end)
    :flatten()
    :totable()
end

---@param config_options table[]
---@param category string
---@return table|nil
function M.find(config_options, category)
  for _, opt in ipairs(config_options or {}) do
    if opt.category == category and opt.type == "select" then
      return opt
    end
  end
end

---@param opt table
---@return string[]
function M.values(opt)
  return vim.tbl_map(function(val)
    return val.value
  end, M.flatten(opt.options))
end

---Match a user's value against an option's values or names, ignoring case
---@param opt table
---@param value string
---@return string|nil
local function resolve(opt, value)
  local wanted = value:lower()
  for _, val in ipairs(M.flatten(opt.options)) do
    if val.value == value or tostring(val.value):lower() == wanted or tostring(val.name):lower() == wanted then
      return val.value
    end
  end
end

---The user's desired option categories, model first as some agents offer different options per model
---@param desired table
---@return string[]
function M.categories(desired)
  local categories = vim.tbl_keys(desired)
  table.sort(categories, function(a, b)
    if (a == "model") ~= (b == "model") then
      return a == "model"
    end
    return a < b
  end)
  return categories
end

---The `session/set_option` change a desired value needs, if any
---@param config_options table[]
---@param category string
---@param value string
---@return { id: string, value: string }|nil change, string|nil err
function M.change(config_options, category, value)
  local opt = M.find(config_options, category)
  if not opt then
    return nil, ("the agent has no %s option"):format(category)
  end
  local resolved = resolve(opt, value)
  if not resolved then
    return nil,
      ("%s isn't one of the agent's %s options: %s"):format(value, category, table.concat(M.values(opt), ", "))
  end
  if resolved ~= opt.currentValue then
    return { id = opt.id, value = resolved }
  end
end

return M

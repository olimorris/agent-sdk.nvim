--=============================================================================
-- Parameters - map the SDK's shared parameters to each API's own fields
--=============================================================================
-- One file per API in this folder, each a table keyed by the SDK's parameter name.
-- Keys a mapping doesn't name pass through unchanged.

---@class agent_sdk.adapters.parameters.Mapping
---@field needs? string A model flag, from `models[model].opts`, that must be true for the value to be sent
---@field omit? string[] Values that mean "the provider's default", so nothing is sent
---@field ref string The vendor's documentation for the field
---@field to string|false Where the value goes: a dotted path for an HTTP body, a category for ACP. `false` drops it

local M = {}

---The parameters every adapter understands, and so the only ones a session can set
M.SHARED = { "mode", "model", "thought_level" }

---@param tbl table
---@param path string
---@param value any
local function set_path(tbl, path, value)
  local keys = vim.split(path, ".", { plain = true })
  local node = tbl
  for i = 1, #keys - 1 do
    if value == nil and type(node[keys[i]]) ~= "table" then
      return
    end
    node[keys[i]] = type(node[keys[i]]) == "table" and node[keys[i]] or {}
    node = node[keys[i]]
  end
  node[keys[#keys]] = value
end

---@param target string The mapping's file name, e.g. "openai" or "acp"
---@return table<string, agent_sdk.adapters.parameters.Mapping>
function M.mapping(target)
  return require("agent_sdk.adapters.parameters." .. target)
end

---Turn the SDK's parameters into the target API's
---@param target string The mapping's file name, e.g. "openai" or "acp"
---@param params table
---@param model? agent_sdk.Model The model's entry in the adapter's `models`, for `needs`
---@return table
function M.translate(target, params, model)
  local mapping = M.mapping(target)
  local result = vim.deepcopy(params or {})

  for key, entry in pairs(mapping) do
    local value = result[key]
    result[key] = nil

    if entry.to then
      local allowed = not entry.needs or vim.tbl_get(model or {}, "opts", entry.needs) == true
      if not allowed then
        -- Also clears a value the user set under the vendor's own name, which the model would reject
        set_path(result, entry.to, nil)
      elseif value ~= nil and not vim.list_contains(entry.omit or {}, value) then
        set_path(result, entry.to, value)
      end
    end
  end

  return result
end

return M

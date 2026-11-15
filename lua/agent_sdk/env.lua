local M = {}

---@param value string|fun(): string?
---@return string?, string?
function M.resolve(value)
  if type(value) == "function" then
    return value()
  end

  local command = type(value) == "string" and value:match("^cmd:(.*)$")
  if command then
    local result = vim.system({ "sh", "-c", command }, { text = true }):wait()
    local output = vim.trim(result.stdout or "")
    if result.code ~= 0 or output == "" then
      local detail = vim.trim(result.stderr or "")
      return nil, ("agent-sdk.nvim: the command `%s` failed%s"):format(command, detail ~= "" and ": " .. detail or "")
    end
    return output
  end

  local found = vim.env[value]
  if found == nil then
    return nil, ("agent-sdk.nvim: the environment variable %s is not set"):format(value)
  end
  return found
end

---@param tbl table<string, string|fun(): string?>?
---@return table<string, string>?, string?
function M.resolve_all(tbl)
  local values = {}
  for key, value in pairs(tbl or {}) do
    local resolved, err = M.resolve(value)
    if not resolved then
      return nil, err or ("agent-sdk.nvim: could not resolve %s"):format(key)
    end
    values[key] = resolved
  end
  return values
end

return M

local M = {}

---Filter a message down to the allowed keys, returning a new table
---@param params { message: table, allowed_words: string[] }
---@return table
function M.filter_out_messages(params)
  local message = params.message
  local allowed = params.allowed_words
  local filtered_message = {}

  for key, value in pairs(message) do
    if vim.tbl_contains(allowed, key) then
      filtered_message[key] = value
    end
  end

  return filtered_message
end

---Merge consecutive messages with the same role, together
---@param messages table
---@param allowed_keys? table Additional keys to preserve beyond role and content
---@param ignored_roles? table Roles that should not be merged even if consecutive
---@return table
function M.merge_messages(messages, allowed_keys, ignored_roles)
  allowed_keys = allowed_keys or { "tools" }
  ignored_roles = ignored_roles or { "tool" }

  local no_merge = {}
  for _, role in ipairs(ignored_roles) do
    no_merge[role] = true
  end

  return vim.iter(messages):fold({}, function(acc, msg)
    local last = acc[#acc]
    if last and last.role == msg.role and not no_merge[msg.role] then
      local a, b = last.content, msg.content
      if type(a) == "string" and type(b) == "string" then
        last.content = a .. "\n\n" .. b
      elseif type(a) == "table" and type(b) == "table" then
        if not vim.islist(a) then
          a = { a }
        end
        if not vim.islist(b) then
          b = { b }
        end
        for _, item in ipairs(b) do
          table.insert(a, item)
        end
        last.content = a
      else
        local list = {}
        if type(a) == "table" then
          vim.list_extend(list, a)
        else
          table.insert(list, a)
        end
        if type(b) == "table" then
          vim.list_extend(list, b)
        else
          table.insert(list, b)
        end
        last.content = list
      end

      for _, key in ipairs(allowed_keys) do
        if msg[key] then
          last[key] = msg[key]
        end
      end
    else
      local new_entry = { role = msg.role, content = msg.content }
      for _, key in ipairs(allowed_keys) do
        if msg[key] then
          new_entry[key] = msg[key]
        end
      end
      table.insert(acc, new_entry)
    end
    return acc
  end)
end

---Strip the SSE prefix from a streamed line, e.g. `data: { "id": 12345 }`
---@param data string | { body: string }
---@return string
function M.clean_streamed_data(data)
  if type(data) == "table" then
    return data.body
  end
  local find_json_start = string.find(data, "{") or 1
  return string.sub(data, find_json_start)
end

---@param var string
---@return boolean
local function is_cmd(var)
  return var:match("^cmd:") ~= nil
end

---@param var string
---@return boolean
local function is_file(var)
  return var:match("^file:") ~= nil
end

---@param var string
---@return string|nil, string|nil
local function read_file(var)
  local path = vim.fs.normalize(var:sub(6))
  local file = io.open(path, "rb")
  if not file then
    return nil, ("agent-sdk.nvim: could not read the file %s"):format(path)
  end
  local content = file:read("*a")
  file:close()
  return (content:gsub("%s+$", ""))
end

local cmd_cache = {}

---Run the command in the environment variable, reusing the output of an earlier successful run
---@param opts { var: string, timeout: number }
---@return string|nil, string|nil
local function run_cmd(opts)
  -- The command runs in the working directory, so the same command can give another project's value
  local cwd = vim.uv.cwd() or ""
  local cached = cmd_cache[opts.var]
  if cached and cached[cwd] then
    return cached[cwd]
  end

  local cmd = opts.var:sub(5)
  local result = vim.system({ vim.o.shell, vim.o.shellcmdflag, cmd }, { text = true, timeout = opts.timeout }):wait()
  local output = (result.stdout or ""):gsub("%s+$", "")
  if result.code ~= 0 or output == "" then
    local detail = vim.trim(result.stderr or "")
    return nil, ("agent-sdk.nvim: the command `%s` failed%s"):format(cmd, detail ~= "" and ": " .. detail or "")
  end

  cmd_cache[opts.var] = cmd_cache[opts.var] or {}
  cmd_cache[opts.var][cwd] = output
  return output
end

---Drop the cached output of `cmd:` env values so the next request runs them again
---@param adapter? table
function M.clear_cached_cmds(adapter)
  if not adapter then
    cmd_cache = {}
    return
  end

  for _, value in pairs(adapter.env or {}) do
    if type(value) == "string" and is_cmd(value) then
      cmd_cache[value] = nil
    end
  end
end

---@param adapter table
---@param opts { var: string }
---@return any
local function get_schema(adapter, opts)
  local node = adapter
  for key in opts.var:gmatch("[^%.]+") do
    if type(node) ~= "table" then
      return nil
    end
    node = node[key]
    if node == nil then
      return nil
    end
  end
  return node
end

---Replace a variable with its value e.g. "${var}" -> "value"
---@param adapter table
---@param opts { str: string }
---@return string
local function replace_var(adapter, opts)
  local str = opts.str
  if type(str) ~= "string" then
    return str
  end

  local result = str:gsub("${(.-)}", function(var)
    return adapter.env_replaced[var]
  end)

  return result
end

---Resolve the adapter's env into `adapter.env_replaced`
---@param adapter table
---@param args? { timeout: number }
---@return table|nil adapter, string|nil err
function M.get_env_vars(adapter, args)
  adapter.env_replaced = {}

  for k, v in pairs(adapter.env or {}) do
    local value, err
    if type(v) == "string" and is_cmd(v) then
      value, err = run_cmd({ var = v, timeout = (args and args.timeout) or 5000 })
    elseif type(v) == "string" and is_file(v) then
      value, err = read_file(v)
    elseif type(v) == "string" and os.getenv(v) then
      value = os.getenv(v)
    elseif type(v) == "function" then
      value = v(adapter)
    else
      value = get_schema(adapter, { var = v })
      if value == nil then
        value = v
      end
    end
    if err then
      return nil, err
    end
    adapter.env_replaced[k] = value
  end

  return adapter
end

---Set env vars in a given object in the adapter
---@param adapter table
---@param object string|table
---@return string|table|nil
function M.set_env_vars(adapter, object)
  local obj_copy = vim.deepcopy(object)

  if type(obj_copy) == "string" then
    return replace_var(adapter, { str = obj_copy })
  elseif type(obj_copy) == "table" then
    local replaced = {}
    for k, v in pairs(obj_copy) do
      if type(v) == "string" then
        replaced[k] = replace_var(adapter, { str = v })
      elseif type(v) == "function" then
        replaced[k] = replace_var(adapter, { str = v(adapter) })
      else
        replaced[k] = v
      end
    end
    return replaced
  end
end

---Get the id that pairs a tool call with its result
---@param tool_call table
---@return string|nil
function M.pairing_id(tool_call)
  return tool_call.call_id or tool_call.id
end

---Obtain the model from the given adapter's schema
---@param adapter table
---@return string|nil
function M.model(adapter)
  local default = adapter.schema and adapter.schema.model and adapter.schema.model.default
  return type(default) == "string" and default or nil
end

---Return the model's entry in the schema's choices
---@param adapter table
---@return table|nil
function M.model_choice(adapter)
  local choices = adapter.schema and adapter.schema.model and adapter.schema.model.choices
  if type(choices) ~= "table" then
    return nil
  end
  return choices[M.model(adapter)]
end

return M

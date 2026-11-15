--=============================================================================
-- Curl - Ported from CodeCompanion's codecompanion/utils/curl.lua
--=============================================================================
local fmt = string.format

local M = {}

---@class agent_sdk.Curl.Request
---@field url string
---@field method string
---@field headers_file string
---@field args string[]
---@field body_file? string
---@field raw? string[]
---@field stream? fun(line: string)
---@field callback? fun(response: { status: number, headers: string[], body: string })
---@field on_error? fun(err: { message: string, stderr: string, exit: number })

---@param request agent_sdk.Curl.Request
---@return string[]
local function build_args(request)
  local args = { "curl", "-sSL", "--dump-header", request.headers_file, "--request", request.method }
  if request.body_file then
    vim.list_extend(args, { "--data-binary", "@" .. request.body_file })
  end
  vim.list_extend(args, request.raw or {})
  table.insert(args, request.url)
  return args
end

---@param headers_file string
---@return number status, string[] headers
local function read_headers(headers_file)
  local status, headers = 0, {}
  local file = io.open(headers_file, "rb")
  if not file then
    return status, headers
  end
  local content = file:read("*a")
  file:close()

  for _, line in ipairs(vim.split(content, "\r?\n")) do
    local code = line:match("^HTTP/%S+%s+(%d+)")
    if code then
      status = tonumber(code) --[[@as number]]
    elseif line ~= "" then
      table.insert(headers, line)
    end
  end

  return status, headers
end

local function build_response(opts)
  local request, result = opts.request, opts.result
  local status, headers = read_headers(request.headers_file)
  os.remove(request.headers_file)

  if result.code ~= 0 or result.signal ~= 0 then
    local stderr = vim.trim(result.stderr or "")
    local message = stderr ~= "" and stderr or fmt("curl exited with code %d", result.code)
    return nil, { message = message, stderr = stderr, exit = result.code }
  end

  return { status = status, headers = headers, body = result.stdout or "", exit = result.code }
end

local function read_stdout(opts)
  local partial = ""

  return function(_, chunk)
    if chunk then
      table.insert(opts.chunks, chunk)
    end
    if not opts.request.stream then
      return
    end

    local text = partial .. (chunk or "")
    if not chunk and text == "" then
      return
    end
    local lines = vim.split(text, "\n", { plain = true })
    partial = chunk and table.remove(lines) or ""

    vim.schedule(function()
      for _, line in ipairs(lines) do
        opts.request.stream(line)
      end
    end)
  end
end

local function report_result(opts)
  local response, err = build_response(opts)
  if err then
    if opts.request.on_error then
      opts.request.on_error(err)
    end
    return
  end
  if opts.request.callback then
    opts.request.callback(response)
  end
end

---@param request agent_sdk.Curl.Request
---@return { args: string[], shutdown: fun() }
local function async(request)
  local chunks = {}
  local stdout = read_stdout({ request = request, chunks = chunks })

  local ok, process = pcall(vim.system, request.args, { stdout = stdout }, function(result)
    result.stdout = table.concat(chunks)
    vim.schedule(function()
      report_result({ request = request, result = result })
    end)
  end)

  if not ok then
    vim.schedule(function()
      if request.on_error then
        request.on_error({ message = fmt("could not start curl: %s", process), stderr = tostring(process), exit = -1 })
      end
    end)
    return { args = request.args, shutdown = function() end }
  end

  return {
    args = request.args,
    shutdown = function()
      process:kill("sigterm")
    end,
  }
end

---@param opts table
---@return agent_sdk.Curl.Request
local function build_request(opts)
  local request = vim.tbl_extend("force", { method = "GET" }, opts) --[[@as agent_sdk.Curl.Request]]
  request.method = request.method:upper()
  request.headers_file = vim.fn.tempname() .. ".headers"
  request.args = build_args(request)
  return request
end

function M.request(opts)
  return async(build_request(opts))
end

function M.post(opts)
  return M.request(vim.tbl_extend("force", opts, { method = "POST" }))
end

return M

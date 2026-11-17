--=============================================================================
-- Awaitable versions of the blocking calls the SDK makes. Each must run inside a vim.async task
--=============================================================================
local M = {}

---Await a libuv-style function, resuming on the main loop so the task can call vim.fn afterwards
---@param argc integer The callback's position in `func`'s arguments
---@param func function
---@return any ...
function M.uv(argc, func, ...)
  local args = { ... }
  return vim.async.await(function(done)
    args[argc] = vim.schedule_wrap(done)
    func(unpack(args, 1, argc))
  end)
end

---Run a command without blocking Neovim, killing it if the task is closed
---@param cmd string[]
---@param opts? vim.SystemOpts
---@return vim.SystemCompleted
function M.system(cmd, opts)
  return vim.async.await(function(done)
    local resume = vim.schedule_wrap(done)
    local ok, process = pcall(vim.system, cmd, opts, resume)
    if not ok then
      resume({ code = -1, signal = 0, stdout = "", stderr = tostring(process) })
      return
    end
    return {
      close = function(_, callback)
        process:kill("sigterm")
        if callback then
          callback()
        end
      end,
    }
  end)
end

---Run `func` in a child task and give up on it after `ms`
---@param ms integer
---@param func async fun(): any
---@return boolean ok, any ... The results, or false and "timeout"
function M.timeout(ms, func)
  local results = { pcall(vim.async.timeout, ms, vim.async.run(func)) }
  -- vim.async.timeout resumes inside its timer's callback, where vim.fn can't be called
  vim.async.await(1, vim.schedule)
  if not results[1] then
    -- Re-raises if it was this task being closed, not the deadline
    vim.async.checkpoint()
    if results[2] == "timeout" then
      return false, "timeout"
    end
    error(results[2], 0)
  end
  return unpack(results, 1, table.maxn(results))
end

---@param path string
---@return string|nil text, string|nil err
function M.read_file(path)
  local err, fd = M.uv(4, vim.uv.fs_open, path, "r", 438)
  if not fd then
    return nil, err
  end
  local stat_err, stat = M.uv(2, vim.uv.fs_fstat, fd)
  local read_err, text
  if stat then
    read_err, text = M.uv(4, vim.uv.fs_read, fd, stat.size, 0)
  end
  M.uv(2, vim.uv.fs_close, fd)
  if not text then
    return nil, stat_err or read_err
  end
  return text
end

---Write a file only the user can read, as request files hold API keys
---@param path string
---@param text string
---@return boolean ok, string|nil err
function M.write_file(path, text)
  local err, fd = M.uv(4, vim.uv.fs_open, path, "w", 384)
  if not fd then
    return false, err
  end
  local write_err = M.uv(4, vim.uv.fs_write, fd, text, 0)
  M.uv(2, vim.uv.fs_close, fd)
  return write_err == nil, write_err
end

---Delete files in the background
---@param paths string[]
function M.remove(paths)
  for _, path in ipairs(paths) do
    vim.uv.fs_unlink(path, function() end)
  end
end

return M

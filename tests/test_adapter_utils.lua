local utils = require("agent_sdk.adapters.utils")

local eq = MiniTest.expect.equality

local function get_env_vars(adapter)
  return vim.async.run(utils.get_env_vars, adapter):wait(2000)
end

local function env_replaced(env)
  local adapter, err = get_env_vars({ env = env })
  return adapter and adapter.env_replaced, err
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      utils.clear_cached_cmds()
    end,
  },
})

T["an environment variable is read by name"] = function()
  vim.env.AGENT_SDK_TEST_VAR = "from-env"
  eq(env_replaced({ key = "AGENT_SDK_TEST_VAR" }), { key = "from-env" })
  vim.env.AGENT_SDK_TEST_VAR = nil
end

T["a function is called with the adapter"] = function()
  eq(
    env_replaced({
      key = function(adapter)
        return adapter.env.other
      end,
      other = "x",
    }).key,
    "x"
  )
end

T["cmd: returns stdout without the trailing newline"] = function()
  eq(env_replaced({ key = "cmd:printf 'secret\\n'" }), { key = "secret" })
end

T["cmd: that fails is an error with its stderr"] = function()
  local values, err = env_replaced({ key = "cmd:echo nope >&2; exit 3" })
  eq(values, nil)
  eq(err, "agent-sdk.nvim: the command `echo nope >&2; exit 3` failed: nope")
end

T["cmd: output is reused, so a password manager is asked once"] = function()
  local counter = vim.fn.tempname()
  local command = ("cmd:echo x >> %s; printf secret"):format(counter)
  env_replaced({ key = command })
  env_replaced({ key = command })
  eq(#vim.fn.readfile(counter), 1)
end

T["${var} in headers is replaced with the resolved value"] = function()
  local adapter = get_env_vars({ env = { api_key = "cmd:printf k" } })
  eq(utils.set_env_vars(adapter, { ["x-api-key"] = "${api_key}" }), { ["x-api-key"] = "k" })
end

T["cmd: started by two tasks at once runs once"] = function()
  local counter = vim.fn.tempname()
  local command = ("cmd:echo x >> %s; sleep 0.1; printf secret"):format(counter)
  local first = vim.async.run(utils.get_env_vars, { env = { key = command } })
  local second = vim.async.run(utils.get_env_vars, { env = { key = command } })
  eq(first:wait(2000).env_replaced.key, "secret")
  eq(second:wait(2000).env_replaced.key, "secret")
  eq(#vim.fn.readfile(counter), 1)
end

T["cmd: doesn't block Neovim while it runs"] = function()
  local ticked = false
  vim.defer_fn(function()
    ticked = true
  end, 20)
  local task = vim.async.run(utils.get_env_vars, { env = { key = "cmd:sleep 0.3; printf k" } })
  vim.wait(150, function()
    return ticked
  end)
  eq(ticked, true)
  eq(task:completed(), false)
  eq(task:wait(2000).env_replaced.key, "k")
end

T["file: is read"] = function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "from-file" }, path)
  eq(env_replaced({ key = "file:" .. path }), { key = "from-file" })
end

T["cmd: that runs too long is an error that says so"] = function()
  local adapter, err = vim.async
    .run(utils.get_env_vars, { env = { key = "cmd:sleep 2" } }, { timeout = 100 })
    :wait(3000)
  eq(adapter, nil)
  eq(err, "agent-sdk.nvim: the command `sleep 2` timed out after 0.1 seconds")
end

T["a pasted key is used as it is"] = function()
  eq(env_replaced({ api_key = "sk-ant-api03-pasted" }), { api_key = "sk-ant-api03-pasted" })
end

return T

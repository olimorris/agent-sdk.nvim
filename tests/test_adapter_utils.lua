local utils = require("agent_sdk.adapters.utils")

local eq = MiniTest.expect.equality

local function env_replaced(env)
  local adapter, err = utils.get_env_vars({ env = env })
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
  local adapter = utils.get_env_vars({ env = { api_key = "cmd:printf k" } })
  eq(utils.set_env_vars(adapter, { ["x-api-key"] = "${api_key}" }), { ["x-api-key"] = "k" })
end

return T

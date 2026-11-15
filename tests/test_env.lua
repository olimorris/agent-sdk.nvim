local env = require("agent_sdk.env")

local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["resolves an environment variable by name"] = function()
  vim.env.AGENT_SDK_TEST_VAR = "from-env"
  eq({ env.resolve("AGENT_SDK_TEST_VAR") }, { "from-env" })
  vim.env.AGENT_SDK_TEST_VAR = nil
end

T["an unset variable is an error naming it"] = function()
  vim.env.AGENT_SDK_TEST_VAR = nil
  local value, err = env.resolve("AGENT_SDK_TEST_VAR")
  eq(value, nil)
  eq(err, "agent-sdk.nvim: the environment variable AGENT_SDK_TEST_VAR is not set")
end

T["calls a function"] = function()
  eq({ env.resolve(function()
    return "from-function"
  end) }, { "from-function" })
end

T["cmd: returns trimmed stdout"] = function()
  eq({ env.resolve("cmd:printf '  secret\\n'") }, { "secret" })
end

T["cmd: fails on a non-zero exit"] = function()
  local value, err = env.resolve("cmd:echo nope >&2; exit 3")
  eq(value, nil)
  eq(err:find("failed", 1, true) ~= nil and err:find("nope", 1, true) ~= nil, true)
end

T["cmd: fails on empty output"] = function()
  local value, err = env.resolve("cmd:printf ''")
  eq(value, nil)
  eq(type(err), "string")
end

T["resolve_all resolves every entry"] = function()
  vim.env.AGENT_SDK_TEST_VAR = "a"
  local values, err = env.resolve_all({
    one = "AGENT_SDK_TEST_VAR",
    two = "cmd:printf b",
    three = function()
      return "c"
    end,
  })
  eq(values, { one = "a", two = "b", three = "c" })
  eq(err, nil)
  vim.env.AGENT_SDK_TEST_VAR = nil
end

T["resolve_all returns the first error"] = function()
  vim.env.AGENT_SDK_TEST_VAR = nil
  local values, err = env.resolve_all({ key = "AGENT_SDK_TEST_VAR" })
  eq(values, nil)
  eq(err, "agent-sdk.nvim: the environment variable AGENT_SDK_TEST_VAR is not set")
end

return T

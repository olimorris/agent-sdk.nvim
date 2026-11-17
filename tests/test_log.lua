local sdk = require("agent_sdk")
local fake_acp = dofile("tests/fake_acp.lua")

local eq = MiniTest.expect.equality

local log = require("agent_sdk.log")
local entries, agent

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      entries = {}
      vim.log.set_format_func(log, function(min_level, level, ...)
        if level >= min_level then
          entries[#entries + 1] = { level = level, args = { ... } }
        end
      end)
      agent = fake_acp.install()
    end,
    post_case = function()
      agent.restore()
      vim.log.set_level(log, vim.log.levels.OFF)
    end,
  },
})

local function messages(level)
  return vim
    .iter(entries)
    :filter(function(entry)
      return entry.level == level
    end)
    :map(function(entry)
      return entry.args[1]
    end)
    :totable()
end

T["sdk.log is the SDK's logger"] = function()
  eq(sdk.log, log)
end

T["log_level takes a name or a vim.log.levels value"] = function()
  sdk.setup({ log_level = "debug" })
  eq(vim.log.get_level(log), vim.log.levels.DEBUG)
  sdk.setup({ log_level = vim.log.levels.ERROR })
  eq(vim.log.get_level(log), vim.log.levels.ERROR)
end

T["an unknown log_level is returned as an error"] = function()
  local ok, err = sdk.setup({ log_level = "loud" })
  eq(ok, false)
  eq(err, 'agent-sdk.nvim: log_level "loud" isn\'t one of trace, debug, info, warn, error or off')
end

T["at debug, ACP messages are logged both ways"] = function()
  sdk.setup({ adapters = { agent = { base = "acp", commands = { default = { "some-agent" } } } }, log_level = "debug" })
  agent.on_prompt = function(message)
    agent.send({ id = message.id, result = { stopReason = "end_turn" } })
  end
  sdk.session({ adapter = sdk.adapter("agent") }):prompt("hi"):wait(1000)

  local debug = messages(vim.log.levels.DEBUG)
  eq(vim.list_contains(debug, "acp send"), true)
  eq(vim.list_contains(debug, "acp recv"), true)
  eq(vim.list_contains(messages(vim.log.levels.INFO), "agent started"), true)
end

T["a failed prompt is logged as an error, and nothing below warn by default"] = function()
  sdk.setup({ adapters = { agent = { base = "acp" } }, log_level = "warn" })
  sdk.session({ adapter = sdk.adapter("agent") }):prompt("hi"):wait(1000)

  eq(#messages(vim.log.levels.DEBUG), 0)
  local errors = vim.tbl_filter(function(entry)
    return entry.level == vim.log.levels.ERROR
  end, entries)
  eq(#errors, 1)
  eq(errors[1].args[1], "agent")
  eq(errors[1].args[2]:find("has no command", 1, true) ~= nil, true)
end

return T

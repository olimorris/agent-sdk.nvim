local acp = require("agent_sdk.acp")

local M = {}

local MODEL_OPTION = {
  id = "model",
  category = "model",
  type = "select",
  currentValue = "opus",
  options = { { value = "opus", name = "Opus" }, { value = "sonnet", name = "Sonnet" } },
}

local MODE_OPTION = {
  id = "mode",
  category = "mode",
  type = "select",
  currentValue = "auto",
  options = { { value = "default", name = "Manual" }, { value = "auto", name = "Auto" } },
}

---An agent that answers the setup methods itself and hands each session/prompt to `agent.on_prompt`
function M.install()
  local original = acp.system
  local agent = {
    spawns = {},
    sent = {},
    system_prompt = true,
    config_options = { MODEL_OPTION, MODE_OPTION },
  }

  local function reply(message)
    message.jsonrpc = "2.0"
    agent.stdout(nil, vim.json.encode(message) .. "\n")
  end

  function agent.send(message)
    vim.schedule(function()
      reply(message)
    end)
  end

  function agent.update(session_update)
    agent.send({
      method = "session/update",
      params = { sessionId = "s1", update = session_update },
    })
  end

  function agent.methods(name)
    return vim.tbl_filter(function(message)
      return message.method == name
    end, agent.sent)
  end

  function agent.exit(code, stderr)
    vim.schedule(function()
      if stderr then
        agent.stderr(nil, stderr)
      end
      agent.on_exit({ code = code, signal = 0 })
    end)
  end

  local function handle(message)
    agent.sent[#agent.sent + 1] = message
    local method = message.method
    if method == "initialize" then
      agent.send({
        id = message.id,
        result = {
          protocolVersion = 1,
          agentCapabilities = {
            sessionCapabilities = agent.system_prompt and { systemPrompt = { mode = {} } } or {},
          },
          authMethods = {},
        },
      })
    elseif method == "authenticate" then
      agent.send({ id = message.id, result = {} })
    elseif method == "session/new" then
      agent.send({ id = message.id, result = { sessionId = "s1", configOptions = agent.config_options } })
    elseif method == "session/set_config_option" then
      local updated = vim.deepcopy(agent.config_options)
      for _, option in ipairs(updated) do
        if option.id == message.params.configId then
          option.currentValue = message.params.value
        end
      end
      agent.send({ id = message.id, result = { configOptions = updated } })
    elseif method == "session/prompt" and agent.on_prompt then
      vim.schedule(function()
        agent.on_prompt(message)
      end)
    end
  end

  acp.system = function(cmd, opts, on_exit)
    if cmd[1] == "missing-agent" then
      error("ENOENT: no such file or directory", 0)
    end
    agent.spawns[#agent.spawns + 1] = { cmd = cmd, opts = opts }
    agent.stdout = opts.stdout
    agent.stderr = opts.stderr
    agent.on_exit = on_exit
    local job = {}
    local partial = ""
    function job:write(data)
      partial = partial .. data
      while true do
        local newline = partial:find("\n", 1, true)
        if not newline then
          break
        end
        local line = partial:sub(1, newline - 1)
        partial = partial:sub(newline + 1)
        handle(vim.json.decode(line))
      end
    end
    function job:kill(signal)
      self.killed = signal
    end
    agent.job = job
    return job
  end

  function agent.restore()
    acp.system = original
  end

  return agent
end

return M

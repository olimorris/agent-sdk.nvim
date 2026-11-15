local sdk = require("agent_sdk")
local fake_acp = dofile("tests/fake_acp.lua")

local eq = MiniTest.expect.equality

local agent

local function chunk(text)
  return { sessionUpdate = "agent_message_chunk", content = { type = "text", text = text } }
end

local function finish(message, result)
  agent.send({ id = message.id, result = result or { stopReason = "end_turn" } })
end

local function claude_code(overrides)
  return require("agent_sdk.adapters").extend(
    "claude_code",
    vim.tbl_deep_extend("force", { commands = { default = { "some-agent" } } }, overrides or {})
  )
end

local function make(session_opts, adapter)
  sdk.setup({ adapters = { agent = adapter or claude_code() } })
  session_opts = session_opts or {}
  session_opts.adapter = sdk.adapter("agent")
  return sdk.session(session_opts)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      agent = fake_acp.install()
    end,
    post_case = function()
      agent.restore()
    end,
  },
})

T["the agent is started on the first prompt, not before"] = function()
  local session = make()
  vim.wait(20)
  eq(#agent.spawns, 0)

  agent.on_prompt = finish
  session:prompt("hi"):wait(1000)
  eq(#agent.spawns, 1)
  eq(agent.spawns[1].cmd, { "some-agent" })
end

T["the Claude Code adapter starts claude-agent-acp"] = function()
  agent.on_prompt = finish
  make(nil, "claude_code"):prompt("hi"):wait(1000)
  eq(agent.spawns[1].cmd, { "claude-agent-acp" })
end

T["the editor offers no file access or terminals"] = function()
  agent.on_prompt = finish
  make():prompt("hi"):wait(1000)

  local capabilities = agent.methods("initialize")[1].params.clientCapabilities
  eq(capabilities.fs, { readTextFile = false, writeTextFile = false })
  eq(capabilities.terminal, false)
end

T["streams text and reasoning, then done with usage"] = function()
  agent.on_prompt = function(message)
    agent.update({ sessionUpdate = "agent_thought_chunk", content = { type = "text", text = "hmm" } })
    agent.update(chunk("Hel"))
    agent.update(chunk("lo"))
    finish(message, { stopReason = "end_turn", usage = { inputTokens = 10, outputTokens = 4 } })
  end

  local texts = {}
  local reply = make({ on = {
      text = function(event)
        texts[#texts + 1] = event.text
      end,
    } })
    :prompt("hi")
    :wait(1000)

  eq(texts, { "Hel", "lo" })
  eq(reply.text, "Hello")
  eq(reply.reasoning, "hmm")
  eq(reply.usage, { input_tokens = 10, output_tokens = 4 })
end

T["usage keeps ACP's names for counts beyond input and output"] = function()
  agent.on_prompt = function(message)
    finish(message, {
      stopReason = "end_turn",
      usage = { inputTokens = 10, outputTokens = 4, cachedReadTokens = 900, cachedWriteTokens = 20 },
    })
  end
  local reply = make():prompt("hi"):wait(1000)
  eq(reply.usage, { input_tokens = 10, output_tokens = 4, cachedReadTokens = 900, cachedWriteTokens = 20 })
end

T["the prompt is sent as content blocks to the agent's session"] = function()
  agent.on_prompt = finish
  make():prompt("hi"):wait(1000)

  local prompt = agent.methods("session/prompt")[1].params
  eq(prompt.sessionId, "s1")
  eq(prompt.prompt, { { type = "text", text = "hi" } })
end

T["one agent process serves every prompt in the session"] = function()
  agent.on_prompt = finish
  local session = make()
  session:prompt("one"):wait(1000)
  session:prompt("two"):wait(1000)

  eq(#agent.spawns, 1)
  eq(#agent.methods("session/new"), 1)
  eq(#agent.methods("session/prompt"), 2)
end

T["the system prompt is appended to the agent's own"] = function()
  agent.on_prompt = finish
  make({ system_prompt = "Be brief." }):prompt("hi"):wait(1000)

  eq(agent.methods("session/new")[1].params.systemPrompt, {
    mode = "append",
    content = { { type = "text", text = "Be brief." } },
  })
end

T["the system prompt isn't sent to an agent that can't take one"] = function()
  agent.system_prompt = false
  agent.on_prompt = finish
  make({ system_prompt = "Be brief." }):prompt("one"):wait(1000)

  eq(agent.methods("session/new")[1].params.systemPrompt, nil)
  eq(agent.methods("session/prompt")[1].params.prompt, { { type = "text", text = "one" } })
end

T["the session's model is chosen through the agent's model option"] = function()
  agent.on_prompt = finish
  make({ model = "sonnet" }):prompt("hi"):wait(1000)

  local set = agent.methods("session/set_config_option")[1].params
  eq(set, { sessionId = "s1", configId = "model", value = "sonnet" })
end

T["the agent's models are known once a session has started"] = function()
  agent.on_prompt = finish
  local session = make()
  eq(session.adapter.capabilities.models, {})
  eq(session.adapter:has_model("anything"), true)

  session:prompt("hi"):wait(1000)
  eq(session.adapter.capabilities.models, { "opus", "sonnet" })
  eq(session.adapter:has_model("haiku"), false)
end

T["a model the agent doesn't have ends the prompt in an error"] = function()
  agent.on_prompt = finish
  local _, err = make({ model = "gpt" }):prompt("hi"):wait(1000)

  eq(err.message, "agent-sdk.nvim: gpt isn't one of the agent's model options: opus, sonnet")
  eq(#agent.methods("session/prompt"), 0)
end

T["the user sets the agent's session options in their config"] = function()
  agent.on_prompt = finish
  make(nil, claude_code({ defaults = { session_config_options = { mode = "Manual" } } })):prompt("hi"):wait(1000)

  eq(agent.methods("session/set_config_option")[1].params, { sessionId = "s1", configId = "mode", value = "default" })
end

T["tool calls carry the spec's fields and needs_result false"] = function()
  agent.on_prompt = function(message)
    agent.update({
      sessionUpdate = "tool_call",
      toolCallId = "t1",
      title = "Read lua/init.lua",
      kind = "read",
      rawInput = { path = "lua/init.lua" },
      _meta = { claudeCode = { toolName = "Read" } },
    })
    finish(message)
  end

  local seen
  local reply = make({ on = {
      request = {
        tool_call = function(call)
          seen = call
        end,
      },
    } })
    :prompt("hi")
    :wait(1000)

  eq({ seen.id, seen.title, seen.kind, seen.needs_result }, { "t1", "Read lua/init.lua", "read", false })
  eq(seen.name, nil)
  eq(seen.rawInput, { path = "lua/init.lua" })
  eq(seen.arguments, nil)
  eq(seen.meta, { claudeCode = { toolName = "Read" } })
  eq(#reply.tool_calls, 1)
end

T["a permission request reaches the plugin and its choice goes back to the agent"] = function()
  agent.on_prompt = function(message)
    agent.send({
      id = 99,
      method = "session/request_permission",
      params = {
        sessionId = "s1",
        toolCall = { toolCallId = "t1", title = "rm -rf build", kind = "execute" },
        options = {
          { optionId = "yes", name = "Allow", kind = "allow_once" },
          { optionId = "no", name = "Reject", kind = "reject_once" },
        },
      },
    })
    agent.on_permission = function()
      finish(message)
    end
  end

  local seen
  make({
      on = {
        request = {
          permission = function(request)
            seen = request
            request.respond("yes")
            agent.on_permission()
          end,
        },
      },
    })
    :prompt("hi")
    :wait(1000)

  eq(seen.tool_call.kind, "execute")
  eq(seen.options[1], { id = "yes", name = "Allow", kind = "allow_once" })
  local answer = vim.tbl_filter(function(message)
    return message.id == 99
  end, agent.sent)[1]
  eq(answer.result, { outcome = { outcome = "selected", optionId = "yes" } })
end

T["stopping a reply cancels the agent's turn and its open permission requests"] = function()
  agent.on_prompt = function()
    agent.send({
      id = 99,
      method = "session/request_permission",
      params = {
        sessionId = "s1",
        toolCall = { toolCallId = "t1", kind = "edit" },
        options = { { optionId = "yes", kind = "allow_once" } },
      },
    })
  end

  local task, stopped
  task = make({
    on = {
      error = function(event)
        stopped = event
      end,
      request = {
        permission = function()
          task:close()
        end,
      },
    },
  }):prompt("hi")
  task:pwait(1000)
  vim.wait(50)

  eq(stopped.cancelled, true)
  eq(agent.methods("session/cancel")[1].params, { sessionId = "s1" })
  local answer = vim.tbl_filter(function(message)
    return message.id == 99
  end, agent.sent)[1]
  eq(answer.result, { outcome = { outcome = "cancelled" } })
end

T["a refusal ends the prompt in an error"] = function()
  agent.on_prompt = function(message)
    finish(message, { stopReason = "refusal" })
  end
  local _, err = make():prompt("hi"):wait(1000)
  eq(err.message, "The agent declined this request")
end

T["an error from the agent ends the prompt in an error"] = function()
  agent.on_prompt = function(message)
    agent.send({ id = message.id, error = { code = -32603, message = "Overloaded" } })
  end
  local _, err = make():prompt("hi"):wait(1000)
  eq(err.message, "Overloaded")
end

T["the agent exiting ends the prompt with its last words"] = function()
  agent.on_prompt = function()
    agent.exit(1, "starting\nnot logged in\n")
  end
  local _, err = make():prompt("hi"):wait(1000)
  eq(err.message, "the agent exited with code 1: not logged in")
end

T["once the agent has exited, every later prompt in the session ends in an error"] = function()
  agent.on_prompt = function()
    agent.exit(1, "crashed\n")
  end
  local session = make()
  session:prompt("one"):wait(1000)

  agent.on_prompt = finish
  local _, err = session:prompt("two"):wait(1000)
  eq(err.message, "agent-sdk.nvim: the agent exited with code 1: crashed")
  eq(#agent.spawns, 1)
end

T["an agent that exits before its session starts is started again on the next prompt"] = function()
  agent.silent.initialize = true
  local session = make()
  local task = session:prompt("one")
  vim.wait(50, function()
    return #agent.methods("initialize") == 1
  end)
  agent.exit(1)
  task:pwait(1000)

  agent.silent.initialize = nil
  agent.on_prompt = finish
  local reply = session:prompt("two"):wait(1000)
  eq(#agent.spawns, 2)
  eq(reply ~= nil, true)
end

T["a stopped turn's late updates don't reach the next prompt, which waits for the turn to end"] = function()
  local first
  agent.on_prompt = function(message)
    first = message
    agent.update(chunk("old"))
  end

  local session
  local task
  session = make({
    on = {
      text = function()
        task:close()
      end,
    },
  })
  task = session:prompt("one")
  task:pwait(1000)

  session.on.text = nil
  agent.on_prompt = function(message)
    agent.update(chunk("new"))
    finish(message)
  end
  local second = session:prompt("two")
  vim.wait(50)
  eq(#agent.methods("session/prompt"), 1)

  agent.update(chunk("late"))
  finish(first, { stopReason = "cancelled" })
  local reply = second:wait(1000)
  eq(reply.text, "new")
end

T["a request the editor doesn't handle is answered with method not found"] = function()
  agent.on_prompt = function(message)
    agent.send({ id = 7, method = "fs/read_text_file", params = { sessionId = "s1", path = "/etc/hosts" } })
    finish(message)
  end
  make():prompt("hi"):wait(1000)

  local answer = vim.tbl_filter(function(message)
    return message.id == 7
  end, agent.sent)[1]
  eq(answer.error.code, -32601)
end

T["a prompt the agent answers without a stop reason ends in an error"] = function()
  agent.on_prompt = function(message)
    agent.send({ id = message.id, result = vim.NIL })
  end
  local _, err = make():prompt("hi"):wait(1000)
  eq(err.message, "the agent ended its turn without a stop reason")
end

T["an agent that never answers session/new ends the prompt in an error"] = function()
  agent.silent["session/new"] = true
  local _, err = make(nil, claude_code({ defaults = { timeout = 50 } })):prompt("hi"):wait(1000)
  eq(err.message, "agent-sdk.nvim: the agent couldn't start a session: session/new timed out")
end

T["an agent that can't be started ends the prompt in an error"] = function()
  local _, err = make(nil, claude_code({ commands = { default = { "missing-agent" } } })):prompt("hi"):wait(1000)
  eq(err.message, "agent-sdk.nvim: couldn't start missing-agent: ENOENT: no such file or directory")
end

T["closing the session stops the agent"] = function()
  agent.on_prompt = finish
  local session = make()
  session:prompt("hi"):wait(1000)
  session:close()
  eq(agent.job.killed, "sigterm")
end

T["the adapter's env reaches the agent's process"] = function()
  vim.env.AGENT_SDK_TEST_TOKEN = "secret"
  agent.on_prompt = finish
  make(nil, claude_code({ env = { TOKEN = "AGENT_SDK_TEST_TOKEN" } })):prompt("hi"):wait(1000)
  vim.env.AGENT_SDK_TEST_TOKEN = nil

  eq(agent.spawns[1].opts.env.TOKEN, "secret")
end

T["tool updates reach the plugin and fill in the reply's tool call"] = function()
  agent.on_prompt = function(message)
    agent.update({
      sessionUpdate = "tool_call",
      toolCallId = "t1",
      title = "Run tests",
      kind = "execute",
      status = "pending",
    })
    agent.update({
      sessionUpdate = "tool_call_update",
      toolCallId = "t1",
      status = "completed",
      rawOutput = { exit = 0 },
      _meta = { claudeCode = { toolName = "Bash" } },
    })
    finish(message)
  end

  local updates = {}
  local reply = make({ on = {
      tool_update = function(update)
        updates[#updates + 1] = update
      end,
    } })
    :prompt("hi")
    :wait(1000)

  eq(#updates, 1)
  eq({ updates[1].id, updates[1].status }, { "t1", "completed" })
  eq(updates[1].rawOutput, { exit = 0 })
  eq(updates[1].meta, { claudeCode = { toolName = "Bash" } })
  eq({ reply.tool_calls[1].title, reply.tool_calls[1].status }, { "Run tests", "completed" })
end

return T

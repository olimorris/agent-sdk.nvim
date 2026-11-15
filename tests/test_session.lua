local sdk = require("agent_sdk")
local test = require("agent_sdk.test")

local eq = MiniTest.expect.equality

local function text(s)
  return { type = "text", text = s }
end

local DONE = { type = "done" }

local function make(opts, session_opts)
  local scripted = test.adapter(opts)
  sdk.setup({ adapters = { scripted = scripted } })
  session_opts = session_opts or {}
  session_opts.adapter = sdk.adapter("scripted")
  return scripted, sdk.session(session_opts)
end

local function recorder(types)
  local log = {}
  local on = { request = {} }
  for _, kind in ipairs(types) do
    local handlers = kind == "tool_call" and on.request or on
    handlers[kind] = function(event)
      log[#log + 1] = { kind, event }
    end
  end
  return log, on
end

local function kinds(log)
  return vim.tbl_map(function(entry)
    return entry[1]
  end, log)
end

local permission_request = {
  type = "permission_request",
  tool_call = { id = "t", kind = "execute" },
  options = { { id = "allow", name = "Allow", kind = "allow_once" } },
}

local function many_texts()
  return { text("1"), text("2"), text("3"), text("4"), DONE }
end

local ALL = { "text", "reasoning", "tool_call", "usage", "done", "error" }

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      sdk.setup({ adapters = {} })
    end,
  },
})

T["nothing is requested until the first prompt"] = function()
  local scripted = make({ replies = { { text("a"), DONE } } })
  vim.wait(20)
  eq(#scripted.requests, 0)
end

T["streams text then done with the full reply"] = function()
  local _, session = make({ replies = { { text("Hel"), text("lo"), DONE } } })
  local log, on = recorder({ "text", "done" })
  local reply, err = session:prompt("hi", { on = on }):wait(1000)

  eq(kinds(log), { "text", "text", "done" })
  eq(log[1][2].text, "Hel")
  eq(log[2][2].text, "lo")
  eq(log[3][2].text, "Hello")
  eq(reply.text, "Hello")
  eq(err, nil)
end

T["accumulates reasoning, usage and tool calls"] = function()
  local _, session = make({
    type = "acp",
    replies = {
      {
        { type = "reasoning", text = "think " },
        { type = "reasoning", text = "more" },
        { type = "usage", input = 1, output = 2 },
        { type = "usage", output = 5 },
        { type = "tool_call", id = "t1", title = "Read", kind = "read" },
        text("x"),
        DONE,
      },
    },
  })
  local reply = session:prompt("hi"):wait(1000)
  eq(reply.reasoning, "think more")
  eq(reply.usage, { input = 1, output = 5 })
  eq(reply.tool_calls, { { id = "t1", title = "Read", kind = "read" } })
end

T["reply fields are nil or empty when absent"] = function()
  local _, session = make({ replies = { { text("x"), DONE } } })
  local reply = session:prompt("hi"):wait(1000)
  eq(reply.reasoning, nil)
  eq(reply.usage, nil)
  eq(reply.tool_calls, {})
end

T["needs_result is true on http and false on acp"] = function()
  for type_, expected in pairs({ http = true, acp = false }) do
    local _, session = make({
      type = type_,
      replies = { { { type = "tool_call", id = "t" }, DONE }, { text("after"), DONE } },
    })
    local seen
    session
      :prompt("hi", {
        on = {
          request = {
            tool_call = function(call)
              seen = call
              call.respond("result")
            end,
          },
        },
      })
      :wait(1000)
    eq(seen.needs_result, expected)
  end
end

T["stream = false holds events until the reply is complete"] = function()
  local _, session = make({
    type = "acp",
    replies = {
      {
        text("a"),
        { type = "reasoning", text = "r" },
        permission_request,
        { type = "usage", input = 1 },
        text("b"),
        DONE,
      },
    },
  })
  local log, on = recorder(ALL)
  local delivered_at_permission
  on.request.permission = function(request)
    delivered_at_permission = #log
    request.respond("allow")
  end
  session:prompt("hi", { stream = false, on = on }):wait(1000)

  eq(delivered_at_permission, 0)
  eq(kinds(log), { "text", "reasoning", "usage", "text", "done" })
  eq(log[5][2].text, "ab")
end

T["stream = false ending in error delivers only error"] = function()
  local _, session = make({ replies = { { text("a"), { type = "error", message = "bad" } } } })
  local log, on = recorder(ALL)
  local reply, err = session:prompt("hi", { stream = false, on = on }):wait(1000)
  eq(kinds(log), { "error" })
  eq(reply, nil)
  eq(err.message, "bad")
end

T["a scripted error reaches the handler and leaves history unchanged"] = function()
  local _, session = make({ replies = { { text("a"), { type = "error", message = "bad" } } } })
  local log, on = recorder(ALL)
  local reply, err = session:prompt("hi", { on = on }):wait(1000)
  eq(kinds(log), { "text", "error" })
  eq(log[2][2].message, "bad")
  eq(reply, nil)
  eq(err.message, "bad")
  eq(session.messages, {})
end

T["an error carries the prompt so the plugin can send it again"] = function()
  local _, session = make({ replies = { { { type = "error", message = "bad" } }, { text("ok"), DONE } } })
  local blocks = { text("hi"), text("there") }
  local _, err = session:prompt(blocks):wait(1000)
  eq(err.prompt, blocks)

  local reply = session:prompt(err.prompt):wait(1000)
  eq(reply.text, "ok")
  eq(session.messages[1], { role = "user", content = blocks })
end

T["a stopped reply carries the prompt"] = function()
  local _, session = make({ replies = { many_texts() } })
  local stopped
  local task = session:prompt("hi", {
    on = {
      error = function(event)
        stopped = event
      end,
    },
  })
  task:close()
  task:pwait(1000)
  vim.wait(50)
  eq(stopped.cancelled, true)
  eq(stopped.prompt, "hi")
end

T["prompt handlers replace session handlers for that event only"] = function()
  local session_log, session_on = recorder({ "text", "done" })
  local _, session = make({ replies = { { text("a"), DONE }, { text("b"), DONE } } }, { on = session_on })
  local prompt_log, prompt_on = recorder({ "text" })

  session:prompt("one", { on = prompt_on }):wait(1000)
  eq(kinds(prompt_log), { "text" })
  eq(kinds(session_log), { "done" })

  session:prompt("two"):wait(1000)
  eq(kinds(session_log), { "done", "text", "done" })
  eq(#prompt_log, 1)
end

T["prompting during a reply raises"] = function()
  local _, session = make({ replies = { { text("a"), DONE } } })
  local task = session:prompt("one")
  MiniTest.expect.error(function()
    session:prompt("two")
  end, "a reply is already in progress")
  task:wait(1000)
end

T["prompting after close raises"] = function()
  local _, session = make({ replies = { { text("a"), DONE } } })
  session:close()
  session:close()
  MiniTest.expect.error(function()
    session:prompt("one")
  end, "closed")
end

T["a done handler can prompt again"] = function()
  local _, session = make({ replies = { { text("a"), DONE }, { text("b"), DONE } } })
  local second
  local first = session:prompt("one", {
    on = {
      done = function()
        second = session:prompt("two")
      end,
    },
  })
  first:wait(1000)
  eq((second:wait(1000)).text, "b")
end

T["closing the task mid-stream cancels exactly once"] = function()
  local scripted, session = make({ replies = { many_texts() } })
  local log, on = recorder({ "text", "done", "error" })
  local task
  on.text = function(event)
    log[#log + 1] = { "text", event }
    task:close()
  end
  task = session:prompt("hi", { on = on })
  local ok, err = task:pwait(1000)
  vim.wait(50)

  eq(ok, false)
  eq(err, "closed")
  eq(kinds(log), { "text", "error" })
  eq(log[2][2].cancelled, true)
  eq(session.messages, {})
  eq(#scripted.requests, 1)
  session:prompt("again"):close()
end

T["closing the task before the request starts sends nothing"] = function()
  local scripted, session = make({ replies = { many_texts() } })
  local log, on = recorder({ "text", "error" })
  local task = session:prompt("hi", { on = on })
  task:close()
  vim.wait(50)
  eq(kinds(log), { "error" })
  eq(#scripted.requests, 0)
  eq(task:pwait(1000), false)
end

T["session:close mid-stream cancels exactly once"] = function()
  local _, session = make({ replies = { many_texts() } })
  local log, on = recorder({ "text", "done", "error" })
  on.text = function(event)
    log[#log + 1] = { "text", event }
    session:close()
  end
  local reply, err = session:prompt("hi", { on = on }):wait(1000)
  vim.wait(50)

  eq(kinds(log), { "text", "error" })
  eq(log[2][2].cancelled, true)
  eq(reply, nil)
  eq(err.cancelled, true)
  eq(session.messages, {})
end

T["a throwing handler does not stop the turn"] = function()
  local _, session = make({ replies = { { text("a"), DONE } } })
  local surfaced = {}
  local schedule = vim.schedule
  vim.schedule = function(fn)
    schedule(function()
      local ok, err = pcall(fn)
      if not ok then
        surfaced[#surfaced + 1] = err
      end
    end)
  end

  local ok, reply = pcall(function()
    return session
      :prompt("hi", {
        on = {
          text = function()
            error("boom", 0)
          end,
        },
      })
      :wait(1000)
  end)
  vim.wait(50)
  vim.schedule = schedule

  eq(ok, true)
  eq(reply.text, "a")
  eq(surfaced, { "boom" })
end

T["history alternates and the second request holds the first exchange"] = function()
  local scripted, session = make({ replies = { { text("one"), DONE }, { text("two"), DONE } } })
  session:prompt("first"):wait(1000)
  session:prompt("second"):wait(1000)

  eq(
    vim.tbl_map(function(m)
      return m.role
    end, session.messages),
    { "user", "llm", "user", "llm" }
  )
  eq(session.messages[1].content, "first")
  eq(session.messages[4].content, "two")
  eq(scripted.requests[2].messages, {
    { role = "user", content = "first" },
    { role = "llm", content = "one" },
    { role = "user", content = "second" },
  })
end

local function read_file_call(id)
  return { type = "tool_call", id = id, name = "read_file", arguments = { path = id .. ".lua" } }
end

local function answering(log)
  return {
    text = function(event)
      log[#log + 1] = "text:" .. event.text
    end,
    request = {
      tool_call = function(call)
        log[#log + 1] = "tool_call:" .. call.id
        call.respond("contents of " .. call.arguments.path)
      end,
    },
    done = function(reply)
      log[#log + 1] = "done:" .. reply.text
    end,
  }
end

T["a tool call is answered and the same prompt carries on to one done"] = function()
  local scripted, session = make({
    replies = {
      { { type = "reasoning", text = "r" }, text("Reading. "), read_file_call("a"), DONE },
      { text("It moved."), DONE },
    },
  })
  local log = {}
  local reply = session:prompt("why?", { on = answering(log) }):wait(1000)

  eq(log, { "text:Reading. ", "tool_call:a", "text:It moved.", "done:Reading. It moved." })
  eq(reply.tool_calls, { { id = "a", name = "read_file", arguments = { path = "a.lua" } } })
  eq(#scripted.requests, 2)
  eq(session.messages, {
    { role = "user", content = "why?" },
    {
      role = "llm",
      content = "Reading. ",
      reasoning = { content = "r" },
      tools = { calls = { { id = "a", name = "read_file", arguments = { path = "a.lua" } } } },
    },
    { role = "tool", content = "contents of a.lua", tools = { call_id = "a" } },
    { role = "llm", content = "It moved." },
  })
  eq(scripted.requests[2].messages, vim.list_slice(session.messages, 1, 3))
end

T["nothing is sent until every tool call is answered, and results keep call order"] = function()
  local scripted, session = make({
    replies = { { read_file_call("a"), read_file_call("b"), DONE }, { text("ok"), DONE } },
  })
  local calls = {}
  local task = session:prompt("go", {
    on = {
      request = {
        tool_call = function(call)
          calls[call.id] = call
        end,
      },
    },
  })
  vim.wait(50)
  eq(#scripted.requests, 1)

  calls.b.respond("B")
  vim.wait(50)
  eq(#scripted.requests, 1)

  calls.a.respond("A")
  calls.a.respond("again")
  local reply = task:wait(1000)
  eq(reply.text, "ok")
  eq(session.messages[3], { role = "tool", content = "A", tools = { call_id = "a" } })
  eq(session.messages[4], { role = "tool", content = "B", tools = { call_id = "b" } })
end

T["a failed tool call is sent as an error result"] = function()
  local _, session = make({ replies = { { read_file_call("a"), DONE }, { text("ok"), DONE } } })
  session
    :prompt("go", {
      on = {
        request = {
          tool_call = function(call)
            call.fail("Could not read a.lua")
          end,
        },
      },
    })
    :wait(1000)
  eq(
    session.messages[3],
    { role = "tool", content = "Could not read a.lua", tools = { call_id = "a", is_error = true } }
  )
end

T["without a tool_call handler the session fails the call"] = function()
  local _, session = make({ replies = { { read_file_call("a"), DONE }, { text("ok"), DONE } } })
  local reply = session:prompt("go"):wait(1000)
  eq(reply.text, "ok")
  eq(session.messages[3].tools.is_error, true)
end

T["usage adds up across the requests of one prompt"] = function()
  local _, session = make({
    replies = {
      { { type = "usage", input_tokens = 10, output_tokens = 2 }, read_file_call("a"), DONE },
      { { type = "usage", input_tokens = 30 }, { type = "usage", output_tokens = 5 }, text("ok"), DONE },
    },
  })
  local reply = session:prompt("go", { on = answering({}) }):wait(1000)
  eq(reply.usage, { input_tokens = 40, output_tokens = 7 })
end

T["stream = false with a tool call delivers each request's events in order"] = function()
  local _, session = make({
    replies = { { text("Reading. "), read_file_call("a"), DONE }, { text("It moved."), DONE } },
  })
  local log = {}
  session:prompt("why?", { stream = false, on = answering(log) }):wait(1000)
  eq(log, { "text:Reading. ", "tool_call:a", "text:It moved.", "done:Reading. It moved." })
end

T["an error after a tool call leaves the history unchanged"] = function()
  local _, session = make({ replies = { { read_file_call("a"), DONE }, { { type = "error", message = "bad" } } } })
  local _, err = session:prompt("go", { on = answering({}) }):wait(1000)
  eq(err.message, "bad")
  eq(err.prompt, "go")
  eq(session.messages, {})
end

T["stopping while a tool call is unanswered sends nothing more"] = function()
  local scripted, session = make({ replies = { { read_file_call("a"), DONE }, { text("ok"), DONE } } })
  local pending, stopped
  local task = session:prompt("go", {
    on = {
      request = {
        tool_call = function(call)
          pending = call
        end,
      },
      error = function(event)
        stopped = event
      end,
    },
  })
  vim.wait(50)
  task:close()
  task:pwait(1000)
  vim.wait(50)
  pending.respond("late")
  vim.wait(50)

  eq(stopped.cancelled, true)
  eq(#scripted.requests, 1)
  eq(session.messages, {})
end

T["on acp, respond and fail do nothing"] = function()
  local scripted, session =
    make({ type = "acp", replies = { { { type = "tool_call", id = "t", kind = "read" }, text("ok"), DONE } } })
  local reply = session
    :prompt("go", {
      on = {
        request = {
          tool_call = function(call)
            call.respond("ignored")
            call.fail("ignored")
          end,
        },
      },
    })
    :wait(1000)
  eq(reply.text, "ok")
  eq(#scripted.requests, 1)
  eq(#session.messages, 2)
end

T["set_messages replaces the history on http"] = function()
  local scripted, session = make({ replies = { { text("a"), DONE } } })
  local history = { { role = "user", content = "old" }, { role = "llm", content = "older" } }
  session:set_messages(history)
  history[1].content = "changed"
  eq(session.messages[1].content, "old")

  session:prompt("new"):wait(1000)
  eq(scripted.requests[1].messages[1].content, "old")
end

T["set_messages on acp changes nothing and says why"] = function()
  local _, session = make({ type = "acp", replies = { { text("a"), DONE }, { text("b"), DONE } } })
  session:prompt("one"):wait(1000)
  local before = vim.deepcopy(session.messages)

  local ok, err = session:set_messages({})
  eq(ok, false)
  eq(err:find("ACP agent owns its history", 1, true) ~= nil, true)
  eq(session.messages, before)

  local reply = session:prompt("two"):wait(1000)
  eq(reply.text, "b")
end

T["set_messages raises during a reply"] = function()
  local _, http = make({ replies = { { text("a"), DONE } } })
  local task = http:prompt("hi")
  MiniTest.expect.error(function()
    http:set_messages({})
  end, "in progress")
  task:wait(1000)
end

T["acp sessions record the conversation but send no messages"] = function()
  local scripted, session = make({
    type = "acp",
    replies = {
      { { type = "reasoning", text = "hm" }, { type = "tool_call", id = "t", kind = "read" }, text("a"), DONE },
      { text("b"), DONE },
    },
  })
  session:prompt("one"):wait(1000)
  session:prompt("two"):wait(1000)

  eq(#session.messages, 4)
  eq(session.messages[1], { role = "user", content = "one" })
  eq(session.messages[2].content, "a")
  eq(session.messages[2].reasoning, { content = "hm" })
  eq(session.messages[2].tools.calls[1].id, "t")
  eq(session.messages[4], { role = "llm", content = "b" })
  eq(scripted.requests[2].messages, nil)
end

local ALLOW_AND_REJECT = {
  { id = "allow", name = "Allow", kind = "allow_once" },
  { id = "reject_always", name = "Never", kind = "reject_always" },
  { id = "reject", name = "Reject", kind = "reject_once" },
}

local function permission(options)
  return {
    type = "permission_request",
    tool_call = { id = "t", kind = "execute" },
    options = options,
  }
end

T["a prompt's request handler replaces the session's for that request only"] = function()
  local _, session = make({
    type = "acp",
    replies = { { permission(ALLOW_AND_REJECT), { type = "tool_call", id = "t" }, DONE } },
  }, {
    on = {
      request = {
        permission = function(request)
          request.respond("allow")
        end,
        tool_call = function()
          error("the prompt's handler should have run")
        end,
      },
    },
  })
  local seen
  session
    :prompt("go", {
      on = {
        request = {
          tool_call = function(call)
            seen = call.id
          end,
        },
      },
    })
    :wait(1000)
  eq(seen, "t")
end

T["a permission handler's response is recorded and the reply continues"] = function()
  local scripted, session = make({
    type = "acp",
    replies = { { text("before"), permission(ALLOW_AND_REJECT), text("after"), DONE } },
  })
  local seen
  local reply = session
    :prompt("hi", {
      on = {
        request = {
          permission = function(request)
            seen = request
            request.respond("allow")
          end,
        },
      },
    })
    :wait(1000)

  eq(scripted.responses, { "allow" })
  eq(seen.tool_call.kind, "execute")
  eq(seen.options[1].id, "allow")
  eq(reply.text, "beforeafter")
end

T["without a handler the session rejects with the reject_once option"] = function()
  local scripted, session = make({ type = "acp", replies = { { permission(ALLOW_AND_REJECT), DONE } } })
  session:prompt("hi"):wait(1000)
  eq(scripted.responses, { "reject" })
end

T["without a handler the session falls back to reject_always"] = function()
  local scripted, session = make({
    type = "acp",
    replies = {
      { permission({ { id = "allow", kind = "allow_once" }, { id = "never", kind = "reject_always" } }), DONE },
    },
  })
  session:prompt("hi"):wait(1000)
  eq(scripted.responses, { "never" })
end

T["without a reject option the session responds nil"] = function()
  local scripted, session = make({
    type = "acp",
    replies = { { permission({ { id = "allow", kind = "allow_once" } }), DONE } },
  })
  session:prompt("hi"):wait(1000)
  eq(scripted.responses, { vim.NIL })
end

T["respond twice records once"] = function()
  local scripted, session = make({ type = "acp", replies = { { permission(ALLOW_AND_REJECT), DONE } } })
  session
    :prompt("hi", {
      on = {
        request = {
          permission = function(request)
            request.respond("allow")
            request.respond("reject")
          end,
        },
      },
    })
    :wait(1000)
  eq(scripted.responses, { "allow" })
end

T["permission requests are not held when stream = false"] = function()
  local scripted, session = make({ type = "acp", replies = { { text("a"), permission(ALLOW_AND_REJECT), DONE } } })
  local order = {}
  session
    :prompt("hi", {
      stream = false,
      on = {
        text = function()
          order[#order + 1] = "text"
        end,
        request = {
          permission = function(request)
            order[#order + 1] = "permission"
            request.respond("allow")
          end,
        },
      },
    })
    :wait(1000)
  eq(order, { "permission", "text" })
  eq(scripted.responses, { "allow" })
end

T["respond does nothing once the turn has finished"] = function()
  local scripted, session = make({ type = "acp", replies = { { permission(ALLOW_AND_REJECT), DONE } } })
  local late
  session:prompt("hi", {
    on = {
      request = {
        permission = function(request)
          late = request.respond
        end,
      },
    },
  })
  vim.wait(30)
  session:close()
  late("allow")
  eq(scripted.responses, {})
end

T["ask returns reply and fires session handlers"] = function()
  local log, on = recorder({ "text" })
  local _, session = make({ replies = { { text("a"), text("b"), DONE } } }, { on = on })
  local task = vim.async.run(function()
    return session:ask("hi")
  end)
  local reply, err = task:wait(1000)
  eq(reply.text, "ab")
  eq(err, nil)
  eq(#log, 2)
end

T["ask returns nil and the error on error"] = function()
  local _, session = make({ replies = { { { type = "error", message = "bad" } } } })
  local task = vim.async.run(function()
    return session:ask("hi")
  end)
  local reply, err = task:wait(1000)
  eq(reply, nil)
  eq(err.message, "bad")
end

T["closing the outer task stops the reply"] = function()
  local scripted, session = make({ replies = { many_texts() } })
  local log, on = recorder({ "error" })
  local outer
  on.text = function()
    outer:close()
  end
  session.on = on
  outer = vim.async.run(function()
    return session:ask("hi")
  end)
  local ok, err = outer:pwait(1000)
  vim.wait(50)

  eq(ok, false)
  eq(err, "closed")
  eq(#log, 1)
  eq(log[1][2].cancelled, true)
  eq(session.turn, nil)
  eq(#scripted.requests, 1)
end

T["handlers run off the fast context"] = function()
  local in_fast = {}
  local adapter = {
    type = "http",
    connect = function()
      return {
        request = function(_, _, emit)
          local timer = vim.uv.new_timer()
          timer:start(1, 0, function()
            timer:close()
            emit({ type = "text", text = "a" })
            emit({ type = "text", text = "b" })
            emit({ type = "done" })
          end)
        end,
        close = function() end,
      }
    end,
  }
  sdk.setup({ adapters = { fast = adapter } })
  local session = sdk.session({ adapter = sdk.adapter("fast") })
  local seen = {}
  local reply = session
    :prompt("hi", {
      on = {
        text = function(event)
          in_fast[#in_fast + 1] = vim.in_fast_event()
          seen[#seen + 1] = event.text
        end,
        done = function()
          in_fast[#in_fast + 1] = vim.in_fast_event()
        end,
      },
    })
    :wait(1000)

  eq(in_fast, { false, false, false })
  eq(seen, { "a", "b" })
  eq(reply.text, "ab")
end

T["a failing connect becomes an error event"] = function()
  sdk.setup({
    adapters = {
      broken = {
        type = "http",
        connect = function()
          error("no network", 0)
        end,
      },
    },
  })
  local session = sdk.session({ adapter = sdk.adapter("broken") })
  local reply, err = session:prompt("hi"):wait(1000)
  eq(reply, nil)
  eq(err.message, "no network")
  eq(session.turn, nil)
end

T["a failing request becomes an error event"] = function()
  sdk.setup({
    adapters = {
      broken = {
        type = "http",
        connect = function()
          return {
            request = function()
              error("refused", 0)
            end,
            close = function() end,
          }
        end,
      },
    },
  })
  local session = sdk.session({ adapter = sdk.adapter("broken") })
  local _, err = session:prompt("hi"):wait(1000)
  eq(err.message, "refused")
end

T["connects once and closes the connection on session close"] = function()
  local connects, closes = 0, 0
  sdk.setup({
    adapters = {
      counting = {
        type = "http",
        connect = function()
          connects = connects + 1
          return {
            request = function(_, _, emit)
              vim.schedule(function()
                emit({ type = "done" })
              end)
            end,
            close = function()
              closes = closes + 1
            end,
          }
        end,
      },
    },
  })
  local session = sdk.session({ adapter = sdk.adapter("counting") })
  session:prompt("a"):wait(1000)
  session:prompt("b"):wait(1000)
  session:close()
  eq({ connects, closes }, { 1, 1 })
end

T["VimLeavePre closes every connected session"] = function()
  local closes = 0
  sdk.setup({
    adapters = {
      counting = {
        type = "http",
        connect = function()
          return {
            request = function(_, _, emit)
              vim.schedule(function()
                emit({ type = "done" })
              end)
            end,
            close = function()
              closes = closes + 1
            end,
          }
        end,
      },
    },
  })
  local first = sdk.session({ adapter = sdk.adapter("counting") })
  local second = sdk.session({ adapter = sdk.adapter("counting") })
  first:prompt("a"):wait(1000)
  second:prompt("a"):wait(1000)

  vim.api.nvim_exec_autocmds("VimLeavePre", { group = "agent_sdk" })
  eq(closes, 2)
  eq(first.closed and second.closed, true)
end

T["the effective model is the session's or the adapter's"] = function()
  local scripted, session = make({ model = "default", replies = { { DONE }, { DONE } } })
  session:prompt("a"):wait(1000)
  eq(scripted.requests[1].model, "default")

  scripted = test.adapter({ model = "default", replies = { { DONE } } })
  sdk.setup({ adapters = { scripted = scripted } })
  sdk.session({ adapter = sdk.adapter("scripted"), model = "override" }):prompt("a"):wait(1000)
  eq(scripted.requests[1].model, "override")
end

T["done data is stored on the assistant message and not shown to handlers"] = function()
  local _, session =
    make({ replies = { { text("hi"), { type = "done", data = { provider = "x", content = { 1 } } } } } })
  local log, on = recorder(ALL)
  local reply = session:prompt("q", { on = on }):wait(1000)

  eq(session.messages[2], { role = "llm", content = "hi", data = { provider = "x", content = { 1 } } })
  eq(reply.data, nil)
  eq(log[#log][2].data, nil)
end

return T

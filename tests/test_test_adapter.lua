local sdk = require("agent_sdk")
local test = require("agent_sdk.test")

local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["rejects a reply that does not end in done or error"] = function()
  MiniTest.expect.error(function()
    test.adapter({ replies = { { { type = "text", text = "x" } } } })
  end, "must end with a done or error")
end

T["records requests including model and system prompt"] = function()
  local scripted = test.adapter({ model = "m1", replies = { { { type = "done" } } } })
  sdk.setup({ adapters = { scripted = scripted } })
  local session = sdk.session({ adapter = sdk.adapter("scripted"), system_prompt = "be brief" })
  session:prompt("hi", { stream = false }):wait(1000)

  eq(#scripted.requests, 1)
  eq(scripted.requests[1].model, "m1")
  eq(scripted.requests[1].system_prompt, "be brief")
  eq(scripted.requests[1].stream, false)
  eq(scripted.requests[1].content, { { type = "text", text = "hi" } })
end

T["the reply cursor is shared across sessions"] = function()
  local scripted = test.adapter({
    replies = {
      { { type = "text", text = "one" }, { type = "done" } },
      { { type = "text", text = "two" }, { type = "done" } },
    },
  })
  sdk.setup({ adapters = { scripted = scripted } })
  local first = sdk.session({ adapter = sdk.adapter("scripted") })
  local second = sdk.session({ adapter = sdk.adapter("scripted") })

  eq((first:prompt("a"):wait(1000)).text, "one")
  eq((second:prompt("b"):wait(1000)).text, "two")
end

T["errors when no reply is left"] = function()
  local scripted = test.adapter({ replies = { { { type = "done" } } } })
  sdk.setup({ adapters = { scripted = scripted } })
  local session = sdk.session({ adapter = sdk.adapter("scripted") })
  session:prompt("a"):wait(1000)

  local reply, err = session:prompt("b"):wait(1000)
  eq(reply, nil)
  eq(err.message, "agent_sdk.test: no scripted reply for request 2")
end

T["scripted.responses fills in through setup and sdk.adapter"] = function()
  local scripted = test.adapter({
    type = "acp",
    replies = {
      {
        {
          type = "permission_request",
          tool_call = { kind = "read" },
          options = { { id = "yes", name = "Yes", kind = "allow_once" } },
        },
        { type = "done" },
      },
    },
  })
  sdk.setup({ adapters = { scripted = scripted } })
  local session = sdk.session({
    adapter = sdk.adapter("scripted"),
    on = {
      request = {
        permission = function(request)
          request.respond("yes")
        end,
      },
    },
  })
  session:prompt("a"):wait(1000)
  eq(scripted.responses, { "yes" })
end

return T

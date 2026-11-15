local adapters = require("agent_sdk.adapters")
local sdk = require("agent_sdk")
local test = require("agent_sdk.test")

local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      sdk.setup({ adapters = {} })
    end,
  },
})

T["returns nil and an error for an unknown name"] = function()
  local adapter, err = sdk.adapter("claude")
  eq(adapter, nil)
  eq(err, 'agent-sdk.nvim: no adapter named "claude". Add it to require("agent_sdk").setup({ adapters = ... })')
end

T["returns nil and an error for an unresolvable built-in"] = function()
  sdk.setup({ adapters = { claude = "no_such_builtin" } })
  local adapter, err = sdk.adapter("claude")
  eq(adapter, nil)
  eq(type(err), "string")
  MiniTest.expect.no_equality(err:find("no_such_builtin", 1, true), nil)
end

T["setup replaces the previous adapters"] = function()
  sdk.setup({ adapters = { one = test.adapter() } })
  sdk.setup({ adapters = { two = test.adapter() } })
  eq(sdk.adapter("one"), nil)
  eq(sdk.adapter("two").name, "two")
end

T["sets name and type"] = function()
  sdk.setup({ adapters = { scripted = test.adapter({ type = "acp" }) } })
  local adapter = sdk.adapter("scripted")
  eq(adapter.name, "scripted")
  eq(adapter.type, "acp")
end

T["defaults capabilities"] = function()
  sdk.setup({ adapters = { bare = { type = "http", connect = function() end } } })
  eq(sdk.adapter("bare").capabilities, { tools = false, vision = false, reasoning = false, models = {} })
end

T["keeps capabilities the adapter sets"] = function()
  sdk.setup({ adapters = { scripted = test.adapter({ capabilities = { tools = true } }) } })
  local capabilities = sdk.adapter("scripted").capabilities
  eq(capabilities.tools, true)
  eq(capabilities.vision, false)
end

T["has_model is true when no models are known"] = function()
  sdk.setup({ adapters = { scripted = test.adapter() } })
  eq(sdk.adapter("scripted"):has_model("anything"), true)
end

T["has_model is true for a listed model"] = function()
  sdk.setup({ adapters = { scripted = test.adapter({ capabilities = { models = { "a", "b" } } }) } })
  eq(sdk.adapter("scripted"):has_model("b"), true)
end

T["has_model is false for an unlisted model"] = function()
  sdk.setup({ adapters = { scripted = test.adapter({ capabilities = { models = { "a", "b" } } }) } })
  eq(sdk.adapter("scripted"):has_model("c"), false)
end

T["changing a returned adapter leaves the next one untouched"] = function()
  local user = test.adapter({ model = "a", capabilities = { models = { "a" } } })
  sdk.setup({ adapters = { scripted = user } })

  local first = sdk.adapter("scripted")
  first.model = "changed"
  first.capabilities.models[1] = "changed"
  first.capabilities.tools = true

  local second = sdk.adapter("scripted")
  eq(second.model, "a")
  eq(second.capabilities.models, { "a" })
  eq(second.capabilities.tools, false)
  eq(user.model, "a")
end

T["extend merges overrides over a table base"] = function()
  local base = { type = "http", model = "a", capabilities = { tools = true } }
  local extended = adapters.extend(base, { model = "b", capabilities = { vision = true } })
  eq(extended, { type = "http", model = "b", capabilities = { tools = true, vision = true } })
  eq(base.model, "a")
end

T["extend errors for an unknown built-in"] = function()
  MiniTest.expect.error(function()
    adapters.extend("no_such_builtin", {})
  end, "no_such_builtin")
end

T["session errors without connect"] = function()
  sdk.setup({ adapters = { bare = { type = "acp" } } })
  MiniTest.expect.error(function()
    sdk.session({ adapter = sdk.adapter("bare") })
  end, "connect")
end

return T

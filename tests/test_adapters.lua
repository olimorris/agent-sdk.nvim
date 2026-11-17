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

T["base merges the user's table over the built-in"] = function()
  sdk.setup({ adapters = { custom = { base = "anthropic", env = { other = "X" }, url = "https://example.com" } } })
  local adapter = sdk.adapter("custom")
  eq(adapter.url, "https://example.com")
  eq(adapter.env, { api_key = "ANTHROPIC_API_KEY", other = "X" })
  eq(adapter.base, nil)
  eq(require("agent_sdk.adapters.http.anthropic").url, "https://api.anthropic.com/v1/messages")
end

T["a string is shorthand for a base with nothing changed"] = function()
  sdk.setup({ adapters = { custom = "anthropic" } })
  eq(sdk.adapter("custom").url, "https://api.anthropic.com/v1/messages")
end

T["base replaces the model list rather than merging it"] = function()
  sdk.setup({ adapters = { custom = { base = "anthropic", models = { mine = {} } } } })
  eq(sdk.adapter("custom").models, { mine = {} })
end

T["capabilities list the adapter's models"] = function()
  sdk.setup({ adapters = { custom = { base = "openai", models = { b = {}, a = {} } } } })
  local adapter = sdk.adapter("custom")
  eq(adapter.capabilities.models, { "a", "b" })
  eq(adapter:has_model("c"), false)
end

T["a base that isn't a built-in returns an error"] = function()
  sdk.setup({ adapters = { custom = { base = "no_such_builtin" } } })
  local adapter, err = sdk.adapter("custom")
  eq(adapter, nil)
  eq(err, 'agent-sdk.nvim: adapter "custom" has the base "no_such_builtin", which isn\'t a built-in adapter')
end

T["setup loads no built-in until a plugin asks for one"] = function()
  package.loaded["agent_sdk.adapters.http.openai"] = nil
  sdk.setup({ adapters = { custom = { base = "openai" } } })
  eq(package.loaded["agent_sdk.adapters.http.openai"], nil)
  sdk.adapter("custom")
  eq(type(package.loaded["agent_sdk.adapters.http.openai"]), "table")
end

T["session errors without connect"] = function()
  sdk.setup({ adapters = { bare = { type = "websocket" } } })
  MiniTest.expect.error(function()
    sdk.session({ adapter = sdk.adapter("bare") })
  end, "connect")
end

return T

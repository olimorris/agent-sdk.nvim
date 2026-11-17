local parameters = require("agent_sdk.adapters.parameters")

local eq = MiniTest.expect.equality

local TARGETS = { "acp", "anthropic", "openai" }
local REASONS = { opts = { can_reason = true } }

local T = MiniTest.new_set()

T["every mapping covers every shared parameter with a link to the vendor's docs"] = function()
  for _, target in ipairs(TARGETS) do
    local mapping = parameters.mapping(target)
    for _, key in ipairs(parameters.SHARED) do
      local entry = mapping[key]
      eq({ target, key, type(entry) }, { target, key, "table" })
      eq({ target, key, vim.startswith(entry.ref or "", "https://") }, { target, key, true })
    end
  end
end

T["the reference docs show each mapping's field"] = function()
  local docs = table.concat(vim.fn.readfile("doc/reference/adapters.mdx"), "\n")
  for _, key in ipairs(parameters.SHARED) do
    local row = docs:match("\n| `" .. key .. "` |([^\n]*)")
    MiniTest.expect.no_equality(row, nil)
    for _, target in ipairs({ "anthropic", "openai" }) do
      local to = parameters.mapping(target)[key].to
      local shown = to and ("`" .. to .. "`") or "Ignored"
      eq({ key, target, row:find(shown, 1, true) ~= nil }, { key, target, true })
    end
  end
end

T["acp"] = MiniTest.new_set()

T["acp"]["passes every parameter through as a category, default included"] = function()
  eq(
    parameters.translate("acp", { mode = "plan", model = "opus", model_config = "fast", thought_level = "default" }),
    { mode = "plan", model = "opus", model_config = "fast", thought_level = "default" }
  )
end

T["anthropic"] = MiniTest.new_set()

T["anthropic"]["thought_level becomes output_config.effort, beside the user's own output_config"] = function()
  eq(
    parameters.translate(
      "anthropic",
      { model = "m", output_config = { format = { type = "json_schema" } }, thought_level = "max" },
      REASONS
    ),
    { model = "m", output_config = { effort = "max", format = { type = "json_schema" } } }
  )
end

T["anthropic"]["mode is dropped and other keys pass through"] = function()
  eq(parameters.translate("anthropic", { mode = "plan", top_p = 0.9 }, REASONS), { top_p = 0.9 })
end

T["anthropic"]["default sends nothing"] = function()
  eq(parameters.translate("anthropic", { thought_level = "default" }, REASONS), {})
end

T["anthropic"]["a model that can't reason gets no effort, even one set as output_config.effort"] = function()
  eq(parameters.translate("anthropic", { thought_level = "high" }, nil), {})
  eq(
    parameters.translate("anthropic", { output_config = { effort = "high", format = {} } }, nil),
    { output_config = { format = {} } }
  )
end

T["openai"] = MiniTest.new_set()

T["openai"]["thought_level becomes reasoning_effort"] = function()
  eq(parameters.translate("openai", { model = "gpt-5", thought_level = "low" }, REASONS), {
    model = "gpt-5",
    reasoning_effort = "low",
  })
end

T["openai"]["a model that can't reason gets no reasoning_effort, even one the user set directly"] = function()
  eq(parameters.translate("openai", { reasoning_effort = "high", temperature = 0 }, { opts = {} }), { temperature = 0 })
end

T["translate leaves the caller's table untouched"] = function()
  local params = { mode = "plan", thought_level = "high" }
  parameters.translate("openai", params, REASONS)
  eq(params, { mode = "plan", thought_level = "high" })
end

return T

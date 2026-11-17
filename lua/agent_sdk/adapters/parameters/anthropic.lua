--=============================================================================
-- Anthropic - parameters become the Messages API's request body
-- Ref: https://platform.claude.com/docs/en/api/messages/create
--=============================================================================

---@type table<string, agent_sdk.adapters.parameters.Mapping>
return {
  mode = {
    ref = "https://platform.claude.com/docs/en/api/messages/create",
    to = false,
  },
  model = {
    ref = "https://platform.claude.com/docs/en/api/messages/create",
    to = "model",
  },
  thought_level = {
    needs = "can_reason",
    omit = { "default" },
    ref = "https://platform.claude.com/docs/en/build-with-claude/effort",
    to = "output_config.effort",
  },
}

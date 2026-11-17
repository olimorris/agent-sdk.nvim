--=============================================================================
-- OpenAI - parameters become the Chat Completions request body
-- Ref: https://platform.openai.com/docs/api-reference/chat/create
--=============================================================================

---@type table<string, agent_sdk.adapters.parameters.Mapping>
return {
  mode = {
    ref = "https://platform.openai.com/docs/api-reference/chat/create",
    to = false,
  },
  model = {
    ref = "https://platform.openai.com/docs/api-reference/chat/create#chat-create-model",
    to = "model",
  },
  thought_level = {
    needs = "can_reason",
    omit = { "default" },
    ref = "https://platform.openai.com/docs/api-reference/chat/create#chat-create-reasoning_effort",
    to = "reasoning_effort",
  },
}

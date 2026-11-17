--=============================================================================
-- ACP - parameters become the agent's session config options, by category
-- Ref: https://agentclientprotocol.com/protocol/session-config-options#option-categories
--=============================================================================

---@type table<string, agent_sdk.adapters.parameters.Mapping>
return {
  mode = {
    ref = "https://agentclientprotocol.com/protocol/session-config-options#option-categories",
    to = "mode",
  },
  model = {
    ref = "https://agentclientprotocol.com/protocol/session-config-options#option-categories",
    to = "model",
  },
  thought_level = {
    ref = "https://agentclientprotocol.com/protocol/session-config-options#option-categories",
    to = "thought_level",
  },
}

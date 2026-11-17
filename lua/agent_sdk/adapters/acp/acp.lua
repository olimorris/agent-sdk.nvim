--=============================================================================
-- ACP - one adapter for every ACP agent. A user's config names the command,
-- the credentials and, if the agent needs one, the auth method
--=============================================================================
local helpers = require("agent_sdk.adapters.acp.helpers")

---@type agent_sdk.ACPAdapter
return {
  name = "acp",
  formatted_name = "ACP",
  type = "acp",
  roles = {
    llm = "assistant",
    user = "user",
  },
  opts = {
    vision = true,
  },
  commands = {},
  defaults = {
    mcpServers = {},
    timeout = 20000,
  },
  env = {},
  initialize = {
    protocolVersion = 1,
    clientCapabilities = {
      fs = { readTextFile = false, writeTextFile = false },
      terminal = false,
    },
    clientInfo = {
      name = "agent-sdk.nvim",
      version = "0.1.0",
    },
  },
  handlers = {
    lifecycle = {
      setup = function(self)
        -- An unset variable resolves to its own name, which the agent would read as a credential
        for key, value in pairs(self.env_replaced or {}) do
          if value == key or value == "" then
            self.env_replaced[key] = nil
          end
        end
        return true
      end,
    },

    request = {
      build_messages = helpers.build_messages,
    },
  },
}

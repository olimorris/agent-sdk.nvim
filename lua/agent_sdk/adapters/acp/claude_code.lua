local helpers = require("agent_sdk.adapters.acp.helpers")

---@type agent_sdk.ACPAdapter
return {
  name = "claude_code",
  formatted_name = "Claude Code",
  type = "acp",
  roles = {
    llm = "assistant",
    user = "user",
  },
  opts = {
    vision = true,
  },
  commands = {
    default = {
      "claude-agent-acp",
    },
    yolo = {
      "claude-agent-acp",
      "--yolo",
    },
  },
  defaults = {
    mcpServers = {},
    timeout = 20000,
  },
  env = {
    CLAUDE_CODE_OAUTH_TOKEN = "CLAUDE_CODE_OAUTH_TOKEN",
  },
  parameters = {
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
        if self.env_replaced.CLAUDE_CODE_OAUTH_TOKEN == "CLAUDE_CODE_OAUTH_TOKEN" then
          self.env_replaced.CLAUDE_CODE_OAUTH_TOKEN = nil
        end
        return true
      end,

      auth = function(self)
        local token = self.env_replaced.CLAUDE_CODE_OAUTH_TOKEN
        return token ~= nil and token ~= ""
      end,
    },

    request = {
      build_messages = helpers.build_messages,
    },
  },
}

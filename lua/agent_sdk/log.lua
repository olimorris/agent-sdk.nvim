---The SDK's logger, writing to agent-sdk.log in stdpath("log"). Plugins can write to it and change its level
return vim.log.new({ name = "agent-sdk" })

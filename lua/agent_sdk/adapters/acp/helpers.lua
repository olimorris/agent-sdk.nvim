local M = {}

---Turn the prompt's content blocks into ACP content blocks
---@param self agent_sdk.ACPAdapter
---@param args { messages: table, capabilities: table }
---@return table
M.build_messages = function(self, args)
  local has = (args.capabilities and args.capabilities.promptCapabilities) or {}

  return vim
    .iter(args.messages)
    :filter(function(block)
      return block.type ~= "image" or has.image
    end)
    :totable()
end

return M

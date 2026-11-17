vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.getcwd() .. "/deps/mini.nvim")

require("mini.test").setup()

-- Tests mustn't write to the developer's own agent-sdk.log
vim.log.set_level(require("agent_sdk.log"), vim.log.levels.OFF)

require("agent_sdk.http").Client.static.methods.post.default = function()
  error("Test attempted a real HTTP request")
end

require("agent_sdk.acp").system = function()
  error("Test attempted to start a real agent")
end

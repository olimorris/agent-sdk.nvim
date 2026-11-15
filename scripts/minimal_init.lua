vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.getcwd() .. "/deps/mini.nvim")

require("mini.test").setup()

require("agent_sdk.http").run = function()
  error("Test attempted a real HTTP request")
end

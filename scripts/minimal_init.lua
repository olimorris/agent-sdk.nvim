vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.getcwd() .. "/deps/mini.nvim")

require("mini.test").setup()

require("agent_sdk.http").Client.static.methods.post.default = function()
  error("Test attempted a real HTTP request")
end

if vim.g.loaded_heimdall then return end
vim.g.loaded_heimdall = 1

local ok, heimdall = pcall(require, "heimdall")
if ok then
  heimdall.setup({})
end

-- reviewr.cache: JSON files under the cache directory, for what the pickers show first
local config = require("reviewr.config")

local M = {}

local function dir() return config.get().cache_dir or (vim.fn.stdpath("cache") .. "/reviewr") end

-- root: a repository root for gp's list; nil for the cross-repository one.
function M.list_path(root)
  return dir() .. "/" .. (root and ("prs-" .. vim.fn.sha256(root) .. ".json") or "prs.json")
end

function M.details_path(url) return dir() .. "/details/" .. vim.fn.sha256(url) .. ".json" end

-- The decoded table in path, or nil when there is none or it is unreadable.
function M.read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, text)
  return ok and type(data) == "table" and data or nil
end

-- A failed write only costs the next open its head start.
function M.write(path, data)
  local ok, text = pcall(vim.json.encode, data)
  if not ok then return end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  pcall(vim.fn.writefile, { text }, path)
end

return M

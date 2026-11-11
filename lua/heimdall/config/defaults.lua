local M = {}

M.defaults = {
  name = "heimdall",
  debug = false,
  log_level = "info", -- debug|info|warn|error
  log_file = nil, -- nil => stdpath('log')/heimdall.log when debug
  baseline_trigger = "auto", -- auto|open|agent|first_comment|manual
  focus_agent = true, -- bring the agent's terminal forward after sending
  refresh_on_agent = true, -- reload the review when a watched agent finishes
  send_mode = "queue", -- queue|submit
  private_ref_prefix = "refs/heimdall",
  git = {
    timeout_ms = 20000,
  },
  cache_dir = nil, -- nil => stdpath('cache')/heimdall, where the PR pickers keep their lists and details
  icons = true, -- Nerd Font icons in pickers and panels; false for plain unicode
  keymaps = true, -- false to skip, or a table of key overrides
  comment_box = "other", -- other: the box opens over the other diff pane; same: below the commented lines
  files_panel_height = 10, -- rows of the changed-files panel, under its title
  pr = {
    roots = {}, -- directories scanned two levels deep for clones of a PR's repository
    cache_dir = nil, -- nil => stdpath('cache')/heimdall/repos, where bare clones are made
  },
  adapters = { "neovim-terminal", "tmux", "rex", "wezterm", "filesystem-inbox" },
  -- programs that count as agents, matched by executable name
  agents = { "claude", "codex", "opencode", "aider", "goose", "cline", "pi" },
}

return M

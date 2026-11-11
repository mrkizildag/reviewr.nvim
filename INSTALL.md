# Installing heimdall.nvim (for coding agents)

You are a coding agent asked to install heimdall.nvim for your user. Do every
step that applies, check each one, and report what you changed. Ask before
editing a config the user keeps under version control in a way they might not
expect, and never overwrite an existing file; add to it.

Repository: https://github.com/mrkizildag/heimdall.nvim. Requirements: Neovim 0.10
or later, and git.

## 1. Add the plugin to Neovim

Find the user's plugin manager in their Neovim config (`nvim --headless -c
'lua io.stdout:write(vim.fn.stdpath("config") .. "\n")' +qa`).

With lazy.nvim, add a spec file next to their other plugin specs, matching their
style:

```lua
return {
  "mrkizildag/heimdall.nvim",
  cmd = { "HeimdallOpen", "HeimdallScope", "HeimdallPR", "HeimdallComment", "HeimdallTurn", "HeimdallExport", "HeimdallClear" },
  opts = {},
}
```

Then install it: `nvim --headless "+Lazy! install heimdall.nvim" +qa`.

With another manager, add `mrkizildag/heimdall.nvim` the way that manager expects
and call `require("heimdall").setup({})` after it loads.

Check: `nvim --headless -c 'lua io.stdout:write(tostring(pcall(require, "heimdall")) .. "\n")' +qa`
prints `true`.

## 2. Install the agent skill

`skills/heimdall-nvim/SKILL.md` teaches agents to open reviews for the user and
act on the comments that come back. Link it into your own skills directory from
the installed plugin, so it updates with the plugin:

```sh
plugin=$(nvim --headless -c 'lua io.stdout:write(vim.fn.stdpath("data") .. "/lazy/heimdall.nvim\n")' +qa)
ln -s "$plugin/skills/heimdall-nvim" ~/.claude/skills/heimdall-nvim   # Claude Code
```

Other agents: link or copy the directory into wherever that agent loads skills
from. If the agent has no skills, add the file's contents to its instructions.

## 3. Rex integration (only if the user runs Rex)

Rex is in use when `rex` is on the PATH and `~/.config/rex/init.lua` exists.
The integration binds cmd+r to show or hide a review of everything on the
focused terminal's branch, committed or not, against the default branch, in a
split to its right. Hidden reviews keep running with their comments. cmd+shift+r
(`pr_key`) shows or hides a separate PR review, opened on `:HeimdallPR` the
first time; it needs the `gh` CLI.

Rex loads the module from the copy the user's Neovim plugin manager installed,
so the two stay on one version. Find `rex/heimdall/init.lua` inside that copy
(with lazy.nvim, `$plugin/rex/heimdall/init.lua` from step 2; with vim.pack,
`<data>/nvim/site/pack/core/opt/heimdall.nvim/rex/heimdall/init.lua`) and add to
`~/.config/rex/init.lua`, after the user's other module loads, guarded:

```lua
do
  local data_home = os.getenv("XDG_DATA_HOME") or os.getenv("HOME") .. "/.local/share"
  local path = data_home .. "/nvim/lazy/heimdall.nvim/rex/heimdall/init.lua" -- the path you found
  local ok, heimdall = pcall(dofile, path)
  if ok then heimdall.setup() end   -- or setup({ key = "ctrl+a>r" }) to pick another key
end
```

Keep the `pcall`. Rex skips a bad `rex.*` call but stops loading the file at a
Lua error, and loading a file that is gone (the plugin removed or moved) is
one: every binding after it would be lost. If the user's config has other
unguarded `require` or `dofile` lines, point this out and offer to guard them
the same way.

Check the key is free first (`rex keymap`), then `rex config check` and
`rex config reload`. `rex keymap` should list the key with source
`heimdall.nvim/rex/heimdall/init.lua`. Tell the user that Rex needs
`rex config reload` after every plugin update, since it doesn't watch its
files.

## 4. tmux integration (only if the user runs tmux outside Rex)

tmux is in use when `tmux` is on the PATH and the user has a `~/.tmux.conf`
(or `~/.config/tmux/tmux.conf`). The integration binds `prefix R`, and a
sequence a terminal can send for cmd+r, to show or hide a review beside the
current pane.

Find `tmux/heimdall.tmux` in the installed copy (with lazy.nvim,
`$plugin/tmux/heimdall.tmux`) and append to the user's tmux config, guarded so
a removed plugin doesn't break it:

```tmux
if-shell 'test -f <path to>/tmux/heimdall.tmux' "run-shell '<path to>/tmux/heimdall.tmux'"
```

Check `prefix R` is free first (`tmux list-keys -T prefix | grep ' R '`); if
not, add `set -g @heimdall-key <free key>` before the line. Then
`tmux source-file <config>` and check `tmux list-keys -T prefix` lists
`toggle.sh`.

For cmd+r on macOS, add the line for the user's terminal from the README's
"cmd+r in tmux" table (Ghostty: `keybind = cmd+r=text:\x1b[9001~` in
`~/.config/ghostty/config`), and tell the user to reload the terminal's config
(Ghostty: cmd+shift+,). Skip this when the user already binds cmd+r in that
terminal; ask instead.

## 5. Verify

From the plugin directory: `nvim --headless -u NONE -l tests/run.lua` ends with
`0 failed`. Then open a review the way the skill describes, on any repository
with changes, and confirm the pane shows `changed files (N)`.

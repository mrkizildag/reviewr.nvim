# heimdall.nvim

Forked from [paul-enz/reviewr.nvim](https://github.com/paul-enz/reviewr.nvim), with a pull request picker and agent-centric review on top.

A multiplexer-agnostic Neovim plugin that brings [herdr-reviewr](https://github.com/persiyanov/herdr-reviewr)-style code review to Neovim: open a diff of two branches, comment on lines or ranges, and send the whole review to a running coding agent (Claude Code, Codex, OpenCode, Aider, …), entirely from inside Neovim.

![cmd+r in Claude Code's terminal opens a review of the branch beside it, paired with that agent. `f` moves to auth.lua, `c` on line 23 opens the comment box, `:w` saves the comment, `s` pastes the review into Claude's input (the line, the comment, and a request to act on it), and Enter submits it; Claude starts on the comment.](assets/demo.gif)

![heimdall.nvim reviewing a branch: the base on the left, the change on the right with two line comments above the lines they're about, every changed file listed along the bottom with its added and deleted lines, and the bar above the change naming the view and the comment count.](assets/screenshot.png)

![Adding a comment. `c` on a line or selection opens a small box over the other pane and marks the commented lines in the gutter. `:w` saves, `<esc>` cancels.](assets/comment.png)

![Sending with several agents running. `S` (or `s` when more than one agent is found) asks which one gets the review, the likeliest first: `j`/`k` or the arrows move, Enter sends, Esc cancels.](assets/send.png)

![Every key, behind `?`.](assets/keys.png)

![Closing with unsent comments asks once. Enter closes; Right then Enter, or Esc, keeps reviewing.](assets/close.png)

## Features

- A review tab of its own: side-by-side native Vim diff (`]c`/`[c`, folds) over a **changed-files panel** along the bottom that shows each file's added and deleted lines, like an octo.nvim review
- Scopes: uncommitted, staged, branch (everything on the branch, committed or not, against its merge base with the default branch), and **turn**: what changed since the last turn baseline
- Diffs cover files git tracks: commits, edits to tracked files, and new files once `git add`ed; untracked files are left out
- Line comments on a line or range, anchored by identity (file, side, start, end), never row index; each records the content its side showed (a commit, the index or the working tree) and shows only in views of that content
- In-memory comment store by design (ephemeral; close drops them, and asks first while any is unsent)
- All-or-none export: clipboard, agent send, or filesystem inbox
- Mux-agnostic send to a running agent: Neovim `:terminal` → tmux → Rex → WezTerm → inbox → clipboard
- Private `refs/heimdall/*` baselines only; never mutates worktree/index/branches. Baselines of removed worktrees, and in Rex of closed terminals, are pruned when a review opens
- Configurable keymaps, events (`User Heimdall…`), leveled logging
- Runs from the shell: `nvim -d …` or `:HeimdallOpen`

## Requirements

- Neovim ≥ 0.10
- git

## Install

Point your coding agent at this repository and ask it to install heimdall.nvim. [INSTALL.md](INSTALL.md) is written for agents: it adds the plugin to Neovim, installs the agent skill (`skills/heimdall-nvim`) so the agent can open reviews for you and act on the comments, and sets up the Rex key binding when you use Rex.

By hand, with lazy.nvim:

```lua
{
  "mrkizildag/heimdall.nvim",
  cmd = { "HeimdallOpen", "HeimdallScope", "HeimdallComment", "HeimdallTurn", "HeimdallExport", "HeimdallClear" },
  opts = {},
}
```

## Rex

`rex/heimdall/init.lua` is a Rex config module. Loaded from `~/.config/rex/init.lua` (see below), it binds cmd+r to show or hide a review beside the focused terminal. The first press opens a review of the terminal's branch, committed or not, against the default branch, in a split to its right; the next press hides it, still running with its comments, and the press after brings it back.

With nothing to review, the review still opens and says so (`changed files (0)`); it fills in on `r`, a view key, or when a watched agent finishes a turn.

Pressed in an agent's terminal, cmd+r opens a review **paired with that agent**: `s` sends to it without asking (`S` still offers the picker), the review follows only that agent's turns, and its turn baseline is its own. Run several agents, each with its own review beside it; with one git worktree per agent, each review's turn view shows exactly its agent's last turn. Agents sharing one working copy see each other's edits in their turn views, since git can't tell who wrote what. Pressed in any other terminal, cmd+r keeps one unpaired review per repository. `setup({ key = "...", command = "HeimdallOpen" })` changes the key or what is reviewed.

### Share Neovim's managed copy with Rex

Rex loads the module straight from the copy your Neovim plugin manager installed, so both halves stay on the same version and the plugin manager updates them together. Install the plugin in Neovim first, then add this to Rex's config:

```lua
-- ~/.config/rex/init.lua
do
  local data_home = os.getenv("XDG_DATA_HOME") or os.getenv("HOME") .. "/.local/share"
  -- lazy.nvim; with vim.pack (Neovim 0.12+) use
  -- data_home .. "/nvim/site/pack/core/opt/heimdall.nvim/rex/heimdall/init.lua"
  local path = data_home .. "/nvim/lazy/heimdall.nvim/rex/heimdall/init.lua"
  local ok, heimdall = pcall(dofile, path)
  if ok then heimdall.setup() end -- or setup({ key = "ctrl+a>r" }) to pick another key
end
```

The path assumes Neovim's default app name and data directory on macOS or Linux. For another plugin manager or a custom data directory, point it at `rex/heimdall/init.lua` inside that manager's copy of the plugin.

Keep the `pcall`: Rex stops loading `init.lua` at a Lua error, so if the Neovim copy is removed, an unguarded `dofile` would take every binding after it with it. Guarded, only cmd+r goes.

Run `rex config reload` after configuring Rex and after every plugin update: Rex doesn't watch its files, so it keeps running the old module until reloaded.

### What the plugin does inside Rex

Inside Rex the plugin also:

- lists every terminal in one `rex do` round trip, so `s` stays quick with many panes open;
- brings the agent's terminal forward after sending (`focus_agent`);
- watches the program status of agents working in the repo and of any agent it sends to: when one starts a turn, the turn baseline is snapshotted (`baseline_trigger = "agent"`, the default in Rex), so `:HeimdallScope turn` shows exactly what that turn changed; when it finishes, the open review reloads (`refresh_on_agent`);
- copies through OSC 52 as well as the `+` register, so `y` reaches your clipboard when Neovim runs on another machine.

## tmux

`tmux/heimdall.tmux` gives tmux the same key outside Rex. `prefix R` shows a review of the current pane's branch, committed or not, against the default branch, in a split to its right. The next press hides it, still running with its comments in a background session named `heimdall`, and the press after brings the same review back. Pressed in a review, it hides that review. Each window keeps one review at a time.

Load it from Neovim's managed copy, as with Rex, at the end of `~/.tmux.conf`:

```tmux
# lazy.nvim; with vim.pack use ~/.local/share/nvim/site/pack/core/opt/heimdall.nvim
if-shell 'test -f ~/.local/share/nvim/lazy/heimdall.nvim/tmux/heimdall.tmux' \
  "run-shell '~/.local/share/nvim/lazy/heimdall.nvim/tmux/heimdall.tmux'"
```

Then `tmux source-file ~/.tmux.conf`. Set options before that line to change the defaults: `set -g @heimdall-key R`, `set -g @heimdall-size 60%`, `set -g @heimdall-command "nvim -c 'lua vim.g.heimdall_standalone = true' -c 'HeimdallScope branch'"`, `set -g @heimdall-user-key 9`.

### cmd+r in tmux

macOS terminals don't pass Cmd keys to tmux, so the terminal sends a sequence tmux knows (`ESC [9001~`) instead:

| Terminal | Config |
|---|---|
| Ghostty (`~/.config/ghostty/config`) | `keybind = cmd+r=text:\x1b[9001~` |
| kitty (`kitty.conf`) | `map cmd+r send_text all \x1b[9001~` |
| WezTerm | `{ key = "r", mods = "CMD", action = wezterm.action.SendString("\x1b[9001~") }` |
| iTerm2 | Settings → Keys → Key Bindings: cmd+r, Send Escape Sequence, `[9001~` |

Outside tmux the shell receives that sequence instead, so cmd+r does nothing useful there. In Rex, use the Rex module: Rex takes cmd+r before tmux sees it.

## Shell usage

```sh
# raw diff (no comment plumbing)
nvim -d <(git show HEAD:file.txt) <(git show feature:file.txt)

# integrated review session
nvim -c 'cd /path/repo' -c 'HeimdallOpen HEAD feature'
```

## Commands

| Command | Description |
|---|---|
| `:HeimdallOpen [base] [head] [label]` | open a review; no args reviews uncommitted changes, `{base}` alone reviews the working tree against its merge base with base, `{base} {head}` diffs the commits of head against its merge base with base |
| `:HeimdallScope {scope}` | switch scope: `uncommitted`, `staged`, `branch` (the working tree against its merge base with the default branch, or the base picked with `gb`), `turn`, `commit {sha}`, `pr {number}` (a pull request of this repository against its merge base, fetched without checking it out; a PR whose branch is checked out in a worktree opens that worktree's branch view instead) |
| `:HeimdallPR [arg]` | review a pull request: `{number}`, `owner/repo#{number}` or a PR URL. Without an argument, pick among the open PRs you authored or were asked to review, from any directory. Needs the `gh` CLI |
| `:[range]HeimdallComment {text}` | comment on the current line or range |
| `:HeimdallTurn` | snapshot the working tree as the turn baseline |
| `:HeimdallExport {clipboard\|send\|inbox}` | export all comments (all-or-none) |
| `:HeimdallClear` | clear comments |

## Keys

The bar above the change pane always shows the next step. `?` lists every key.

| Key | Action |
|---|---|
| `c` | comment on the current line, or the visual selection |
| `e` | edit the comment under the cursor |
| `d` | delete the comment under the cursor |
| `n` / `N` | next / previous comment |
| `s` | send every comment to the running agent (the paired one, if any) |
| `S` | send, choosing the agent |
| `y` | copy every comment |
| `l` | list comments |
| `]c` / `[c` | next / previous change |
| `f` / `F` | next / previous changed file |
| `r` | reread the changes from git and the working tree (a pull request is fetched again first) |
| `u` `b` `t` | view: uncommitted / branch / last turn |
| `gc` | pick a commit and review just that commit |
| `gb` | pick the base branch for the branch view |
| `gp` | pick an open pull request of this repository and review it |
| `?` | all keys |
| `q` | close. With unsent comments (new, or edited since the last send or copy) it asks once: Enter closes, Right then Enter or Esc keeps reviewing. A review cmd+r opened closes its pane too |

The changed-files panel has the same keys, except those that act on a line of the diff (`c`, `e`, `d`, `n`, `N`, `]c`, `[c`); there `<CR>` opens the file under the cursor.

The pickers (`gc`, `gb`, `gp`, `S`) open a small centered list over a blank view: `j`/`k`, `Ctrl-j`/`Ctrl-k` or the arrows move, Enter picks, Esc cancels. `/` opens a search box above the list that filters as you type (every word must match, in any order, case-insensitive); Enter picks the selected match, Esc goes back to the list with the filter kept, and Esc in the list clears it. The picker is modal: window motions such as `Ctrl-h`/`Ctrl-l` do nothing while it is open. The selected row has a coloured bar and background. Pull requests take two lines (state icon and title; then repo, `#number`, author, age); `:HeimdallPR` without an argument groups them under "Yours" and "Review requested". The pull request pickers also show a Details panel beside the list (description, checks, review state) when Neovim is at least 120 columns wide; `Ctrl-d`/`Ctrl-u` scroll it: title with state, review and conflict badges at its right, branches, diff size, a checks summary with the failing and pending ones listed, and the description rendered as markdown. Once a PR's details have loaded its row shows a checks mark (`✓`, `✗` or `●`). The PR pickers open at once from the last list they fetched ("refreshing…" in the footer, "offline: …" if the fetch fails), update in place when GitHub answers, and load the details of the first eight PRs in the background. Lists and details are cached as JSON under `stdpath("cache")/heimdall` (`prs.json`, `prs-<hash of repo>.json`, `details/`; set `cache_dir` to move them), and details are reused only while the PR's update time is unchanged. Icons are Nerd Font glyphs; `setup({ icons = false })` uses plain unicode.

All buffer-local and remappable through the `keymaps` option or `require("heimdall.keymaps").set_defaults()`.

## Pull requests

`:HeimdallPR` and `gp` review a pull request without checking it out: its head is fetched into a private `refs/heimdall/pr/{n}` ref and compared with its merge base against the PR's base branch; your branches, index and HEAD are untouched. Comments go to the agent as in any other view. `gh` must be installed and logged in.

A PR outside the current repository is opened in a clone of it: one found under `pr.roots` (directories scanned two levels deep for a remote on github.com/owner/repo), else a blobless bare clone kept in `pr.cache_dir` (default `stdpath("cache")/heimdall/repos/{owner}/{repo}`). A bare clone has no working tree, so only the PR and commit views work there.

```lua
require("heimdall").setup({ pr = { roots = { "~/projects" } } })
```

With the Rex module, cmd+shift+r (`pr_key`) shows or hides a PR review kept apart from cmd+r's, opened on `:HeimdallPR` the first time and paired with the agent when pressed in an agent's terminal.

## Agents

`s` pastes the review into a running agent (`claude`, `codex`, `opencode`, `aider`, `goose`, `cline`, `pi`, or the programs the `agents` option names; a review paired with an agent always recognises it). It looks in:

1. Neovim `:terminal`s whose processes include an agent;
2. tmux panes in the repo running an agent (inside tmux);
3. Rex terminals running an agent: any terminal in Neovim's own Rex session, and terminals in other sessions working in the repo (inside Rex);
4. WezTerm panes in the repo running an agent (inside WezTerm).

With one agent found it sends straight away; with several, a picker lists them, the likeliest first, with each terminal's title. With none it writes the inbox file, and failing that copies to the clipboard. The `adapters` option limits which of these are tried.

## What the agent receives

Every comment, in file order, as plain text:

![The review as it lands in Claude Code's input: the file and line, the quoted line, the comment, and a closing request to make the changes and answer any questions.](assets/agent.png)

```
Code review comments from my editor:

1. lua/demo/parse.lua:42-48
   > local ok, err = pcall(decode, s)
   > if not ok then
   >   return nil
   > ...
   Comment: This swallows the error. Return it to the caller instead.

2. lua/demo/parse.lua:7
   > local DEFAULT_LIMIT = 5
   Comment: Why did this default change from 10 to 5?

Make the requested changes and answer any questions. Reply per item.
```

Each comment gives its file (relative to the repository) and line range, and quotes the first three lines it covers as they were in the version it was made on. Every export carries every comment; one that succeeds marks them sent, so closing no longer asks about them.

Default delivery is **queue** (pasted into the agent input, no Enter); set `send_mode = "submit"` to also submit. Filesystem inbox writes the same text to `<repo>/.heimdall/inbox/`, which git ignores.

## Configuration

```lua
require("heimdall").setup({
  baseline_trigger = "auto",   -- auto (agent in Rex, else open) | open | agent | first_comment | manual
  focus_agent = true,          -- bring the agent's terminal forward after sending
  refresh_on_agent = true,     -- reload the review when a watched agent finishes
  log_level = "info",
  send_mode = "queue",         -- queue | submit
  private_ref_prefix = "refs/heimdall",
  keymaps = true,              -- false, or a table such as { send = "S" }
  files_panel_height = 10,     -- rows of the changed-files panel
  comment_box = "other",       -- other: the comment box opens over the other diff pane; same: below the commented lines
  adapters = { "neovim-terminal", "tmux", "rex", "wezterm", "filesystem-inbox" },
  agents = { "claude", "codex", "opencode", "aider", "goose", "cline", "pi" }, -- programs that count as agents
})
```

## Testing

```sh
nvim --headless -u NONE -l tests/run.lua
```

## License

MIT

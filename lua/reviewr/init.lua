local config_mod = require("reviewr.config")
local events = require("reviewr.events")
local log = require("reviewr.log")
local store = require("reviewr.store")
local state = require("reviewr.state")
local scope_mod = require("reviewr.scope")
local git = require("reviewr.git")
local turn = require("reviewr.turn")

local M = {}
local setup_done = false

local SCOPES = { "uncommitted", "staged", "branch", "turn", "commit", "pr" }
local NEEDS_TREE = { uncommitted = true, staged = true, branch = true, turn = true }
local EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
-- the base branch picked with gb; nil means the default branch
local chosen_base
-- the PR the pr scope shows, for refresh to fetch again
local current_pr

-- open: mark the turn baseline whenever a review opens; agent: when a
-- watched agent starts working; auto: agent inside Rex, else open
local function baseline_trigger()
  local t = config_mod.get().baseline_trigger
  if t == "auto" then return require("reviewr.rex").available() and "agent" or "open" end
  return t
end

-- The agent this review was opened for (Rex sets vim.g.reviewr_agent when
-- cmd+r is pressed in an agent's terminal), or nil.
local function paired()
  local a = vim.g.reviewr_agent
  return type(a) == "table" and a.block and a or nil
end

-- A paired review keeps its own turn baseline, so other agents working in the
-- same repository don't move it.
local function turn_scope()
  local a = paired()
  return { name = a and ("turn-" .. a.block) or "turn" }
end

-- repos whose stale baselines were pruned this session
local pruned = {}

local ACTIVE = { working = true, blocked = true }
local watch_repo

-- A watched agent's turn starts when it leaves idle for work, and ends when
-- it stops working or waiting on the user.
local function on_agent(new, old, label)
  if ACTIVE[new] and not ACTIVE[old] then
    if baseline_trigger() == "agent" and watch_repo then
      turn.mark_turn({ repo = watch_repo, scope = turn_scope() })
    end
  elseif ACTIVE[old] and not ACTIVE[new] then
    local ui = require("reviewr.ui")
    if config_mod.get().refresh_on_agent and ui.is_open() then
      local here = vim.api.nvim_get_current_tabpage()
      ui.focus_tab()
      M.refresh()
      if vim.api.nvim_tabpage_is_valid(here) then vim.api.nvim_set_current_tabpage(here) end
      vim.notify("reviewr: " .. label .. " finished; review refreshed", vim.log.levels.INFO)
    end
  end
end

local function watch_agent(cand)
  local rex = require("reviewr.rex")
  if cand.transport ~= "rex" or rex.watching(cand.id) then return end
  rex.watch(cand.meta.session, cand.id, { state = cand.state, label = cand.label, cb = on_agent })
end

M._on_agent = on_agent
M.paired = paired

local function root()
  return git.git_root(vim.fn.getcwd()) or vim.fn.getcwd()
end

function M.setup(opts)
  config_mod.merge(opts)
  if setup_done then return M end
  setup_done = true
  log.info("setup")
  require("reviewr.ui").setup()
  vim.api.nvim_create_user_command("ReviewrOpen", function(o) M.open(o.fargs) end, { nargs = "*" })
  vim.api.nvim_create_user_command("ReviewrScope", function(o)
    M.set_scope(o.fargs[1], { commit = o.fargs[2], pr = tonumber(o.fargs[2]) })
  end, {
    nargs = "+",
    complete = function() return SCOPES end,
  })
  vim.api.nvim_create_user_command("ReviewrPR", function(o) M.open_pr(o.args ~= "" and o.args or nil) end,
    { nargs = "?" })
  vim.api.nvim_create_user_command("ReviewrComment", function(o)
    M.add_comment({ body = o.args, start = o.line1, ["end"] = o.line2 })
    require("reviewr.ui").redraw()
  end, { nargs = "+", range = true })
  vim.api.nvim_create_user_command("ReviewrTurn", function() M.mark_turn() end, {})
  vim.api.nvim_create_user_command("ReviewrExport", function(o)
    M.export(o.args ~= "" and o.args or nil, function(ok, res, dest)
      vim.notify("reviewr: " .. (ok and (res .. " exported to " .. tostring(dest)) or tostring(res)),
        ok and vim.log.levels.INFO or vim.log.levels.WARN)
    end)
  end, {
    nargs = "?",
    complete = function() return { "clipboard", "send", "inbox" } end,
  })
  vim.api.nvim_create_user_command("ReviewrClear", function() M.clear() end, {})
  vim.api.nvim_create_autocmd("TabClosed", {
    callback = function(args)
      local tp = tonumber(args.match)
      if tp then state.remove(tp) end
    end,
  })
  events.emit("Setup", { config = config_mod.get() })
  return M
end

-- A file's lines at ref: nil reads the working tree, ":" the index.
local function read_lines(repo, ref, path)
  if ref ~= nil then return git.show((ref == ":" and ":" or (ref .. ":")) .. path, repo) or {} end
  local full = repo .. "/" .. path
  local f = vim.fn.filereadable(full) == 1 and io.open(full, "rb")
  if not f then return {} end
  local lines = git.lines(f:read("*a"))
  f:close()
  return lines
end

-- ref: a commit-ish, ":" for the index, nil for the working tree. source:
-- where the content lives at ref when it differs from path (a rename's old
-- path). Both sides keep the bytes as git has them, CRs and NULs included.
local function buf_from_ref(repo, ref, path, side, source)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, read_lines(repo, ref, source or path))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.b[buf].reviewr_file = path
  vim.b[buf].reviewr_side = side
  local ft = vim.filetype.match({ filename = path }) or ""
  if ft ~= "" then vim.bo[buf].filetype = ft end
  return buf
end

-- Against the working tree, the diff is against a snapshot of its tracked
-- files, so staged new files count and untracked ones don't. Read
-- NUL-separated, so paths come back unquoted; a rename or copy carries its old
-- path, which the left pane reads. Each file also carries its added and
-- deleted line counts (none for a binary file).
local function changed_files(repo, base_ref, head_ref)
  local range
  if head_ref == ":" then
    range = { "--cached", base_ref }
  elseif head_ref then
    range = { base_ref, head_ref }
  else
    range = { base_ref, git.snapshot(repo) }
  end
  local function diff(format)
    local args = { "diff", format, "-z" }
    vim.list_extend(args, range)
    return vim.split(git.run_sync(args, { cwd = repo }).raw_stdout, "\0", { plain = true })
  end
  local counts, n = {}, 1
  local stats = diff("--numstat")
  while stats[n] and stats[n] ~= "" do
    local added, deleted, path = stats[n]:match("^(%S+)\t(%S+)\t(.*)$")
    if not added then break end
    if path == "" then
      path, n = stats[n + 2], n + 3
    else
      n = n + 1
    end
    if path then counts[path] = { tonumber(added), tonumber(deleted) } end
  end
  local fields = diff("--name-status")
  local files, i = {}, 1
  while fields[i] and fields[i] ~= "" and fields[i + 1] do
    local status = fields[i]:sub(1, 1)
    if status == "R" or status == "C" then
      if not fields[i + 2] then break end
      table.insert(files, { status = status, path = fields[i + 2], old = fields[i + 1] })
      i = i + 3
    else
      table.insert(files, { status = status, path = fields[i + 1] })
      i = i + 2
    end
  end
  for _, f in ipairs(files) do
    local c = counts[f.path] or {}
    f.added, f.deleted = c[1], c[2]
  end
  return files
end

local function default_branch(repo)
  local r = git.run_sync({ "rev-parse", "--abbrev-ref", "origin/HEAD" }, { cwd = repo })
  if r.ok and r.stdout[1] and r.stdout[1] ~= "origin/HEAD" then return r.stdout[1] end
  for _, b in ipairs({ "main", "master" }) do
    if git.rev_parse(b, repo) then return b end
  end
  return nil
end

-- The (base, head) pair a scope compares, and how the bar names it.
local function scope_refs(repo, name, opts)
  opts = opts or {}
  if name == "uncommitted" then return "HEAD", nil end
  if name == "staged" then return "HEAD", ":" end
  if name == "turn" then
    local sha = turn.last_turn_sha(repo, turn_scope())
    if not sha then return nil, nil, "no turn marked yet; run :ReviewrTurn" end
    return sha, nil, nil, "last turn"
  end
  if name == "branch" then
    local base = chosen_base or default_branch(repo)
    if not base then return nil, nil, "no default branch found" end
    local mb = git.run_sync({ "merge-base", base, "HEAD" }, { cwd = repo })
    if not (mb.ok and mb.stdout[1]) then return nil, nil, "no merge base with " .. base end
    return mb.stdout[1], nil, nil, "branch vs " .. base
  end
  if name == "commit" then
    local sha = opts.commit and git.rev_parse(opts.commit .. "^{commit}", repo)
    if not sha then return nil, nil, "no such commit: " .. tostring(opts.commit) end
    local parent = git.rev_parse(sha .. "^", repo) or EMPTY_TREE
    return parent, sha, nil, "commit " .. sha:sub(1, 7)
  end
  return nil, nil, "unknown scope " .. tostring(name)
end

function M.open_file(path)
  local s = state.get()
  if not s or not s.files then return false end
  local ui = require("reviewr.ui")
  local old
  for _, f in ipairs(s.files) do if f.path == path then old = f.old; break end end
  local left = buf_from_ref(s.repo, s.base_ref, path, "left", old)
  local right = buf_from_ref(s.repo, s.head_ref, path, "right")
  vim.b[left].reviewr_at, vim.b[right].reviewr_at = s.left_at, s.right_at
  vim.b[left].reviewr_source = old
  ui.show_file(left, right, path)
  local keymaps = require("reviewr.keymaps")
  keymaps.install(left)
  keymaps.install(right)
  ui.redraw(left)
  ui.redraw(right)
  ui.open_files_panel(s.files)
  return true
end

-- With nothing to review the tab still opens, saying so, and keeps its keys:
-- r, a view key or the end of an agent's turn fills it once there are changes.
local function show_empty()
  local ui = require("reviewr.ui")
  local scope = scope_mod.get() or {}
  local bufs = {}
  for i, text in ipairs({ "", "  No changes to review (" .. (scope.label or scope.name or "this view") .. ")." }) do
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
    vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].modifiable = "nofile", "wipe", false
    bufs[i] = buf
  end
  ui.show_file(bufs[1], bufs[2], nil)
  for _, buf in ipairs(bufs) do require("reviewr.keymaps").install(buf) end
  ui.open_files_panel({})
end

-- What a pane shows, as comments record it: a commit (or tree) id, the index
-- or the working tree.
local function content_at(repo, ref)
  if ref == nil then return "working tree" end
  if ref == ":" then return "index" end
  return git.rev_parse(ref, repo) or ref
end

-- Loads the session's file list (or takes `files`, already read) and shows
-- `prefer` (or the first file). keep_view: reloading the file in view keeps
-- both panes where they were.
local function load(prefer, files, keep_view)
  local s = state.get()
  s.files = files or changed_files(s.repo, s.base_ref, s.head_ref)
  s.left_at, s.right_at = content_at(s.repo, s.base_ref), content_at(s.repo, s.head_ref)
  if #s.files == 0 then
    show_empty()
    vim.notify("reviewr: no changes found", vim.log.levels.INFO)
    return false
  end
  local target = s.files[1].path
  for _, f in ipairs(s.files) do if f.path == prefer then target = prefer; break end end
  local ui = require("reviewr.ui")
  local d = ui.panes()
  local views = {}
  if keep_view and ui.is_open() and d.file == target then
    for _, win in ipairs({ d.left_win, d.right_win }) do
      views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    end
  end
  local active = vim.api.nvim_get_current_win()
  if not M.open_file(target) then return false end
  -- the active pane last, so cursorbind doesn't drag it after the other
  for _, win in ipairs({ d.left_win, d.right_win, active }) do
    if views[win] and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function() vim.fn.winrestview(views[win]) end)
    end
  end
  return true
end

local function start(repo, base_ref, head_ref, scope_name, label)
  -- the left pane shows the merge base, so a moving base branch adds no noise
  if head_ref and head_ref ~= ":" then
    local mb = git.run_sync({ "merge-base", base_ref, head_ref }, { cwd = repo })
    if mb.ok and mb.stdout[1] then base_ref = mb.stdout[1] end
  end
  local bare = git.is_bare(repo)
  if not bare and not git.git_root(repo) then
    vim.notify("reviewr: not in a git repository", vim.log.levels.WARN)
    return false
  end
  local files = changed_files(repo, base_ref, head_ref)
  local ui = require("reviewr.ui")
  local cur = vim.api.nvim_buf_get_name(0)
  local prefer = vim.startswith(cur, repo .. "/") and cur:sub(#repo + 2) or ui.panes().file
  if ui.is_open() then ui.focus_tab() else ui.open_tab() end
  scope_mod.set({ repo = repo, name = scope_name, label = label, ref = head_ref or "WORKTREE" })
  local s = state.ensure()
  s.repo, s.base_ref, s.head_ref, s.scope = repo, base_ref, head_ref, scope_mod.get()
  local shown = load(prefer, files)
  if not pruned[repo] then
    pruned[repo] = true
    local live
    if require("reviewr.rex").available() then
      local terms = require("reviewr.rex").terminals()
      -- an empty list may mean Rex didn't answer: keep every paired baseline
      if #terms > 0 then
        live = {}
        for _, t in ipairs(terms) do live[t.block_id] = true end
      end
    end
    turn.prune(repo, live)
  end
  local trigger = baseline_trigger()
  if not bare and (trigger == "open" or (trigger == "agent" and not turn.last_turn_sha(repo, turn_scope()))) then
    turn.mark_turn({ repo = repo, scope = turn_scope() })
  end
  if require("reviewr.rex").available() then
    watch_repo = repo
    local transport = require("reviewr.transport")
    local agent = paired()
    if agent then
      local cand = transport.rex_candidate(agent.block)
      if cand then watch_agent(cand) end
    else
      for _, c in ipairs(transport.rex_candidates(repo)) do
        if c.conf > 0.6 then watch_agent(c) end
      end
    end
  end
  events.emit("Opened", { repo = repo, scope = scope_mod.get(), file = ui.panes().file, files = s.files })
  log.info("opened " .. repo .. " (" .. #s.files .. " files)")
  return shown
end

function M.open(args)
  if type(args) == "string" then args = vim.split(args, "%s+", { trimempty = true }) end
  if type(args) ~= "table" then args = {} end
  local repo = root()
  local base_ref = args[1] or "HEAD"
  local head_ref = args[2] -- nil => working tree
  if args[1] and not head_ref then
    -- everything on this branch, committed or not, against where it left base
    local mb = git.run_sync({ "merge-base", base_ref, "HEAD" }, { cwd = repo })
    if mb.ok and mb.stdout[1] then base_ref = mb.stdout[1] end
  end
  local scope_name = args[3] or (head_ref and "branch" or "uncommitted")
  return start(repo, base_ref, head_ref, scope_name)
end

local function notify_warn(msg)
  vim.notify("reviewr: " .. msg, vim.log.levels.WARN)
  return nil, msg
end

-- "owner/name" of a github.com remote URL, lowercased, or nil.
local function slug_of(url)
  local slug = url:lower():gsub("/+$", ""):gsub("%.git$", ""):match("github%.com[:/]([^/:]+/[^/]+)$")
  return slug
end

-- The remotes of repo whose URL is slug's repository, origin first.
local function remotes_for(repo, slug)
  local r = git.run_sync({ "config", "--get-regexp", "^remote\\..*\\.url$" }, { cwd = repo })
  local found = {}
  for _, l in ipairs(r.stdout) do
    local name, url = l:match("^remote%.(.+)%.url (.*)$")
    if name and slug_of(url) == slug:lower() then table.insert(found, name) end
  end
  table.sort(found, function(a, b) return a == "origin" and b ~= "origin" end)
  return found
end

local function worktree_on(repo, branch)
  local r = git.run_sync({ "worktree", "list", "--porcelain" }, { cwd = repo })
  local path
  for _, l in ipairs(r.stdout) do
    local p = l:match("^worktree (.*)$")
    if p then path = p end
    if path and l == "branch refs/heads/" .. branch then return path end
  end
  return nil
end

local function pr_label(pr)
  local title = pr.title
  if vim.fn.strchars(title) > 50 then title = vim.fn.strcharpart(title, 0, 47) .. "..." end
  return "PR #" .. pr.number .. ": " .. title
end

-- Fetches the PR's head and base into private refs; the user's own refs are
-- left alone. with_head = false when a local worktree stands in for the head.
local function fetch_pr(repo, pr, with_head)
  local args = { "fetch", "--quiet", "--no-tags", pr.remote, "+refs/heads/" .. pr.base .. ":" .. pr.base_ref }
  if with_head then table.insert(args, "+refs/pull/" .. pr.number .. "/head:" .. pr.head_ref) end
  local r = git.run_sync(args, { cwd = repo, timeout = 120000 })
  if r.ok then return true end
  return nil, "could not fetch PR #" .. pr.number .. ": " .. table.concat(r.stderr, "\n")
end

-- The (base, head) commits of a fetched PR.
local function pr_commits(repo, pr)
  local base, head = git.rev_parse(pr.base_ref, repo), git.rev_parse(pr.head_ref, repo)
  if not (base and head) then return nil, nil, "PR #" .. pr.number .. " is not fetched" end
  return base, head
end

-- opts.pr: the PR number; opts.slug: its "owner/name" when the repository
-- isn't the one at `repo`.
local function open_pr_scope(repo, opts)
  local github = require("reviewr.github")
  local view, err = github.view_pr(opts.pr, opts.slug, repo)
  if not view then return notify_warn("could not read PR #" .. tostring(opts.pr) .. ": " .. err) end
  local slug = view.url:match("github%.com/([^/]+/[^/]+)/pull/")
  local prefix = config_mod.get().private_ref_prefix
  local pr = {
    number = view.number,
    title = view.title,
    base = view.baseRefName,
    remote = (slug and remotes_for(repo, slug)[1]) or "origin",
    head_ref = prefix .. "/pr/" .. view.number,
    base_ref = prefix .. "/pr-base/" .. view.number,
  }
  local owner = slug and slug:match("^[^/]+"):lower()
  local head_owner = type(view.headRepositoryOwner) == "table" and view.headRepositoryOwner.login or ""
  local wt = owner == head_owner:lower() and worktree_on(repo, view.headRefName) or nil
  local ok, ferr = fetch_pr(repo, pr, not wt)
  if not ok then return notify_warn(ferr) end
  local base, head
  if wt then
    base = git.rev_parse(pr.base_ref, wt)
    local mb = base and git.run_sync({ "merge-base", base, "HEAD" }, { cwd = wt })
    if not (mb and mb.ok and mb.stdout[1]) then return notify_warn("no merge base with " .. pr.base) end
    chosen_base = pr.base_ref
    current_pr = nil
    vim.notify("reviewr: " .. view.headRefName .. " is checked out in " .. wt .. "; reviewing it there", vim.log.levels.INFO)
    if not start(wt, mb.stdout[1], nil, "branch", "branch vs " .. pr.base .. " (PR #" .. pr.number .. ")") then return nil end
  else
    local cerr
    base, head, cerr = pr_commits(repo, pr)
    if cerr then return notify_warn(cerr) end
    if not start(repo, base, head, "pr", pr_label(pr)) then return nil end
    current_pr = pr
  end
  events.emit("ScopeChanged", { scope = scope_mod.get() })
  return scope_mod.get()
end

-- opts.commit: the commit the commit scope shows; opts.pr: the PR number of
-- the pr scope; opts.dir: the repository to review, when not the current one.
function M.set_scope(name, opts)
  opts = opts or {}
  local repo = opts.dir or (state.get() or {}).repo or root()
  if name == "pr" then
    if not opts.pr then return notify_warn("usage: ReviewrScope pr {number}") end
    return open_pr_scope(repo, opts)
  end
  if NEEDS_TREE[name] and git.is_bare(repo) then
    return notify_warn("no working tree in this clone; only PR and commit views work")
  end
  local base_ref, head_ref, err, label = scope_refs(repo, name, opts)
  if err then return notify_warn(err) end
  if not start(repo, base_ref, head_ref, name, label) then return nil end
  current_pr = nil
  events.emit("ScopeChanged", { scope = scope_mod.get() })
  return scope_mod.get()
end

local CHECK_FAILED = { FAILURE = true, TIMED_OUT = true, CANCELLED = true, ACTION_REQUIRED = true,
  STARTUP_FAILURE = true, ERROR = true }

-- "passed", "failed", "pending" or "skipped" for one statusCheckRollup entry,
-- and the name to show for it.
local function classify_check(c)
  if c.__typename == "StatusContext" then
    local state = c.state or ""
    return (state == "SUCCESS" and "passed") or (CHECK_FAILED[state] and "failed") or "pending", c.context
  end
  local name = (c.workflowName and c.workflowName ~= "") and (c.workflowName .. " / " .. c.name) or c.name
  if c.status ~= "COMPLETED" then return "pending", name end
  local conclusion = c.conclusion or ""
  if conclusion == "SUCCESS" then return "passed", name end
  if conclusion == "NEUTRAL" or conclusion == "SKIPPED" then return "skipped", name end
  return CHECK_FAILED[conclusion] and "failed" or "pending", name
end

-- "3h ago" for an ISO 8601 UTC timestamp. Both wall clocks are read the same
-- way, so the zone cancels out.
local function ago(iso)
  local y, mo, d, h, mi, s = (iso or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  local then_ = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false })
  local utc = os.date("!*t")
  utc.isdst = false
  local secs = math.max(0, os.time(utc) - then_)
  if secs < 60 then return "just now" end
  for _, unit in ipairs({ { 3600, 60, "m" }, { 86400, 3600, "h" }, { 86400 * 30, 86400, "d" },
    { 86400 * 365, 86400 * 30, "mo" } }) do
    if secs < unit[1] then return math.floor(secs / unit[2]) .. unit[3] .. " ago" end
  end
  return math.floor(secs / (86400 * 365)) .. "y ago"
end

local REVIEW_BADGE = {
  APPROVED = { "Approved", "ReviewrBadgeApproved" },
  CHANGES_REQUESTED = { "Changes requested", "ReviewrBadgeChanges" },
  REVIEW_REQUIRED = { "Review required", "ReviewrBadgeReview" },
}
local STATE_BADGE = {
  OPEN = { "Open", "ReviewrBadgeOpen" }, MERGED = { "Merged", "ReviewrBadgeMerged" },
  CLOSED = { "Closed", "ReviewrBadgeClosed" },
}

-- The details panel of a PR: lines, highlights ({ line, col_start, col_end,
-- group }, 0-based line, byte columns) and the { text, group } mark the list
-- shows for its checks (nil without any).
function M.pr_details_lines(d)
  local ui = require("reviewr.ui")
  local lines, marks = {}, {}
  local function add(text, hl)
    lines[#lines + 1] = text
    if hl then marks[#marks + 1] = { #lines - 1, 0, #text, hl } end
  end
  -- pieces: { text, hl? } joined by `sep`, each highlighted on its own
  local function add_pieces(pieces, sep)
    local text = ""
    for i, piece in ipairs(pieces) do
      if i > 1 then text = text .. sep end
      if piece[2] then marks[#marks + 1] = { #lines, #text, #text + #piece[1], piece[2] } end
      text = text .. piece[1]
    end
    lines[#lines + 1] = text
  end

  add(d.title or "", "ReviewrHeading")
  local badges = { d.isDraft and { "Draft", "ReviewrBadgeDraft" } or STATE_BADGE[d.state] or { d.state or "?" } }
  if REVIEW_BADGE[d.reviewDecision] then table.insert(badges, REVIEW_BADGE[d.reviewDecision]) end
  if d.mergeable == "CONFLICTING" then table.insert(badges, { "Conflicts", "ReviewrBadgeConflicts" }) end
  add_pieces(vim.tbl_map(function(b) return { " " .. b[1] .. " ", b[2] } end, badges), " ")
  add("")
  add(ui.icon("branch") .. " " .. (d.headRefName or "?") .. " → " .. (d.baseRefName or "?"), "ReviewrDim")
  local updated = ago(d.updatedAt)
  add(ui.icon("user") .. " " .. (d.author and d.author.login or "?") .. (updated and (" · updated " .. updated) or ""),
    "ReviewrDim")
  add_pieces({ { "+" .. (d.additions or 0), "ReviewrAdded" }, { "-" .. (d.deletions or 0), "ReviewrRemoved" },
    { "· " .. (d.changedFiles or 0) .. " files", "ReviewrDim" } }, " ")
  add(ui.RULE)

  local counts = { passed = 0, failed = 0, pending = 0, skipped = 0 }
  local failing, pending = {}, {}
  local total = 0
  for _, c in ipairs(d.statusCheckRollup or {}) do
    local kind, name = classify_check(c)
    counts[kind] = counts[kind] + 1
    total = total + 1
    if kind == "failed" then table.insert(failing, name) elseif kind == "pending" then table.insert(pending, name) end
  end
  add("Checks", "ReviewrHeading")
  if total == 0 then
    add("No checks", "ReviewrDim")
  elseif counts.failed == 0 and counts.pending == 0 then
    add(string.format("All %d checks passed", total), "ReviewrOk")
  else
    local pieces = {}
    for _, part in ipairs({ { "passed", "✓", "ReviewrOk" }, { "failed", "✗", "ReviewrFail" },
      { "pending", "●", "ReviewrPending" }, { "skipped", "○", "ReviewrDim" } }) do
      if counts[part[1]] > 0 then table.insert(pieces, { part[2] .. " " .. counts[part[1]], part[3] }) end
    end
    add_pieces(pieces, "  ")
    for _, name in ipairs(failing) do
      add("✗ " .. name)
      marks[#marks + 1] = { #lines - 1, 0, #"✗", "ReviewrFail" }
    end
    for _, name in ipairs(pending) do
      add("● " .. name)
      marks[#marks + 1] = { #lines - 1, 0, #"●", "ReviewrPending" }
    end
  end
  add(ui.RULE)
  add("Description", "ReviewrHeading")
  local body = vim.trim((d.body or ""):gsub("\r", ""))
  if body == "" then
    add("No description.", "ReviewrDim")
  else
    vim.list_extend(lines, vim.split(body, "\n"))
  end

  local mark
  if counts.failed > 0 then mark = { "✗", "ReviewrFail" }
  elseif counts.pending > 0 then mark = { "●", "ReviewrPending" }
  elseif counts.passed > 0 then mark = { "✓", "ReviewrOk" } end
  return lines, marks, mark
end

-- ui.pick's preview for PR rows; slug_of(pr): "owner/name" when not the repository at dir.
local function pr_preview(dir, slug_of)
  return function(pr, done)
    require("reviewr.github").pr_details(pr.number, slug_of and slug_of(pr) or nil, dir, function(details, err)
      if not details then return done({ "Could not load details: " .. tostring(err) }) end
      local lines, marks, mark = M.pr_details_lines(details)
      done(lines, { markdown = true, highlights = marks, mark = mark })
    end)
  end
end

-- Two-line row for a PR: state icon and title, then repo (when slug_of is
-- given), #number, author and age, dimmed.
local function pr_row(slug_of)
  local ui = require("reviewr.ui")
  return function(pr)
    local icon = pr.isDraft and { ui.icon("pr_draft"), "ReviewrDim" } or { ui.icon("pr_open"), "ReviewrOk" }
    local meta = {}
    if slug_of then table.insert(meta, { slug_of(pr), "ReviewrDim" }) end
    table.insert(meta, { "#" .. pr.number, "ReviewrNumber" })
    table.insert(meta, { pr.author and pr.author.login or "?", "ReviewrDim" })
    local age = ago(pr.updatedAt)
    if age then table.insert(meta, { age, "ReviewrDim" }) end
    local second = { { "  " } }
    for i, m in ipairs(meta) do
      if i > 1 then table.insert(second, { " · ", "ReviewrDim" }) end
      table.insert(second, m)
    end
    return { { icon, { " " .. pr.title } }, second }
  end
end

-- Picks one of the open pull requests of this repository and reviews it.
function M.pick_pr()
  local repo = (state.get() or {}).repo or root()
  local prs, err = require("reviewr.github").list_prs(repo)
  if not prs then return notify_warn("could not list pull requests: " .. err) end
  if #prs == 0 then return notify_warn("no open pull requests") end
  require("reviewr.ui").pick(prs, {
    prompt = require("reviewr.ui").title("pr_open", "Pull requests"),
    action = "review",
    render_item = pr_row(),
    preview = pr_preview(repo),
  }, function(choice)
    if choice then M.set_scope("pr", { pr = choice.number, dir = repo }) end
  end)
end

-- The first clone of slug under the configured roots, scanned two levels deep.
local function clone_in_roots(slug)
  for _, rootdir in ipairs(config_mod.get().pr.roots) do
    rootdir = vim.fn.expand(rootdir)
    for name, kind in vim.fs.dir(rootdir) do
      if kind == "directory" then
        local top = rootdir .. "/" .. name
        local candidates = { top }
        for sub, subkind in vim.fs.dir(top) do
          if subkind == "directory" then table.insert(candidates, top .. "/" .. sub) end
        end
        for _, dir in ipairs(candidates) do
          if vim.uv.fs_stat(dir .. "/.git") and #remotes_for(dir, slug) > 0 then return dir end
        end
      end
    end
  end
  return nil
end

-- A local clone of slug: one under pr.roots, else a blobless bare clone kept
-- in the cache directory.
local function clone_of(slug)
  local found = clone_in_roots(slug)
  if found then return found end
  local cache = config_mod.get().pr.cache_dir or (vim.fn.stdpath("cache") .. "/reviewr/repos")
  local dir = cache .. "/" .. slug
  if vim.uv.fs_stat(dir .. "/HEAD") then return dir end
  vim.fn.mkdir(vim.fn.fnamemodify(dir, ":h"), "p")
  local r = git.run_sync({ "clone", "--bare", "--filter=blob:none", "https://github.com/" .. slug .. ".git", dir },
    { cwd = cache, timeout = 600000 })
  if not r.ok then return nil, "could not clone " .. slug .. ": " .. table.concat(r.stderr, "\n") end
  return dir
end

local function open_pr_in(slug, number)
  local here = root()
  local dir = here
  if #remotes_for(here, slug) == 0 then
    local err
    dir, err = clone_of(slug)
    if not dir then return notify_warn(err) end
  end
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  return M.set_scope("pr", { pr = number, slug = slug, dir = dir })
end

-- arg: a number (this repository), "owner/name#number" or a PR URL. Without
-- one, picks among the open PRs I authored or was asked to review.
function M.open_pr(arg)
  if not arg then
    local prs, err = require("reviewr.github").search_prs()
    if not prs then return notify_warn("could not search pull requests: " .. err) end
    if #prs == 0 then return notify_warn("no open pull requests of yours") end
    local function slug_of(pr) return pr.repository.nameWithOwner end
    local rows = {}
    for _, section in ipairs({ { "yours", "Yours" }, { "requested", "Review requested" } }) do
      local group = vim.tbl_filter(function(pr) return pr.section == section[1] end, prs)
      if #group > 0 then
        table.insert(rows, { heading = section[2] })
        vim.list_extend(rows, group)
      end
    end
    require("reviewr.ui").pick(rows, {
      prompt = require("reviewr.ui").title("pr_open", "Pull requests"),
      action = "review",
      render_item = pr_row(slug_of),
      preview = pr_preview(nil, slug_of),
    }, function(choice)
      if choice then open_pr_in(choice.repository.nameWithOwner, choice.number) end
    end)
    return
  end
  local n = arg:match("^#?(%d+)$")
  if n then return M.set_scope("pr", { pr = tonumber(n) }) end
  local slug, number = arg:match("^([%w_.-]+/[%w_.-]+)#(%d+)$")
  if not slug then slug, number = arg:match("github%.com/([^/]+/[^/]+)/pull/(%d+)") end
  if not slug then return notify_warn("usage: ReviewrPR [number | owner/repo#number | pull request URL]") end
  return open_pr_in(slug, tonumber(number))
end

-- Picks one of the last 100 commits on HEAD and reviews just that commit.
function M.pick_commit()
  local repo = (state.get() or {}).repo or root()
  local log = git.run_sync({ "log", "-n", "100", "--format=%h%x09%s" }, { cwd = repo }).stdout or {}
  local items = vim.tbl_filter(function(l) return l ~= "" end, log)
  require("reviewr.ui").pick(items, {
    prompt = require("reviewr.ui").title("commit", "Review commit"),
    render_item = function(l)
      local sha, subject = l:match("^(%S+)\t(.*)$")
      return { { { sha, "ReviewrNumber" }, { "  " .. subject } } }
    end,
  }, function(choice)
    if choice then M.set_scope("commit", { commit = choice:match("^(%S+)") }) end
  end)
end

-- Picks the branch the branch scope compares against, then shows it.
function M.pick_base()
  local repo = (state.get() or {}).repo or root()
  local refs = git.run_sync({ "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes" },
    { cwd = repo }).stdout or {}
  local current = git.run_sync({ "branch", "--show-current" }, { cwd = repo }).stdout[1]
  local items = vim.tbl_filter(function(r)
    return r ~= "" and r ~= current and not r:match("/HEAD$") and r ~= "origin"
  end, refs)
  local ui = require("reviewr.ui")
  ui.pick(items, { prompt = ui.title("branch", "Compare the branch against") }, function(choice)
    if not choice then return end
    chosen_base = choice
    M.set_scope("branch")
  end)
end

function M.refresh()
  local s = state.get()
  if not s or not s.files then return false end
  if current_pr and (scope_mod.get() or {}).name == "pr" then
    local ok, err = fetch_pr(s.repo, current_pr, true)
    if not ok then notify_warn(err); return false end
    local base, head, cerr = pr_commits(s.repo, current_pr)
    if cerr then notify_warn(cerr); return false end
    local mb = git.run_sync({ "merge-base", base, head }, { cwd = s.repo })
    s.base_ref, s.head_ref = mb.ok and mb.stdout[1] or base, head
  end
  return load(require("reviewr.ui").panes().file, nil, true)
end

function M.add_comment(input)
  input = input or {}
  local scope = scope_mod.get() or {}
  local repo = scope.repo or root()
  local file = input.file or vim.b.reviewr_file
  if not file then
    local name = vim.api.nvim_buf_get_name(0)
    if vim.startswith(name, repo .. "/") then file = name:sub(#repo + 2) end
  end
  if not file then vim.notify("reviewr: no target file for comment", vim.log.levels.WARN); return nil, "no-file" end
  local startl = input.start or vim.fn.line(".")
  local comment = store.add({
    repo = repo,
    scope = scope.name,
    file = file,
    side = input.side or vim.b.reviewr_side or "right",
    at = input.at or (not input.file and vim.b.reviewr_at) or nil,
    source = input.source or (not input.file and vim.b.reviewr_source) or nil,
    start = startl,
    ["end"] = input["end"] or startl,
    body = input.body or "",
  })
  if baseline_trigger() == "first_comment" and not turn.last_turn_sha(repo, turn_scope()) then
    turn.mark_turn({ repo = repo, scope = turn_scope() })
  end
  events.emit("CommentAdded", { comment = comment })
  return comment
end

function M.list_comments(query)
  return store.list(query or {})
end

function M.mark_turn(opts)
  opts = opts or {}
  opts.scope = opts.scope or turn_scope()
  return turn.mark_turn(opts)
end

local function valid_comment(c)
  if not c or not c.file or c.file == "" then return false, "missing file" end
  if not c.side then return false, "missing side" end
  if type(c.start) ~= "number" or type(c["end"]) ~= "number" then return false, "missing range" end
  if c.start > c["end"] then return false, "invalid range" end
  if (c.body or "") == "" then return false, "empty body" end
  return true
end

function M.delete_comment(id)
  local c = id and store.get(id) or nil
  if not c then return nil, "no-comment" end
  store.remove(id)
  events.emit("CommentDeleted", { comment = c })
  return c
end

function M.edit_comment(id, body)
  local c = id and store.get(id) or nil
  if not c then return nil, "no-comment" end
  if not body or body == "" then return nil, "empty" end
  store.update(id, { body = body, sent = false })
  events.emit("CommentEdited", { comment = c })
  return c
end

function M.jump_comment(dir)
  local here = vim.fn.line(".")
  local ordered = store.shown(vim.b.reviewr_file, vim.b.reviewr_side, vim.b.reviewr_at)
  local target
  if dir > 0 then
    for _, c in ipairs(ordered) do
      if (c.start or 0) > here then target = c; break end
    end
    target = target or ordered[1]
  else
    for i = #ordered, 1, -1 do
      if (ordered[i].start or 0) < here then target = ordered[i]; break end
    end
    target = target or ordered[#ordered]
  end
  if target then vim.fn.cursor(target.start, 1) end
  return target
end

function M.jump_file(dir)
  local s = state.get()
  if not s or not s.files or #s.files == 0 then return nil end
  local cur = require("reviewr.ui").panes().file
  local idx = 1
  for i, f in ipairs(s.files) do if f.path == cur then idx = i; break end end
  local nxt = s.files[((idx - 1 + dir) % #s.files) + 1].path
  M.open_file(nxt)
  return nxt
end

-- The first lines a comment covers, from the content its side showed, quoted
-- without the indent they share.
local function quote(repo, c)
  local ref = c.at
  if ref == nil or ref == "working tree" then ref = nil elseif ref == "index" then ref = ":" end
  local lines = read_lines(repo, ref, c.source or c.file)
  local shown, indent = {}, math.huge
  for l = c.start, math.min(c["end"], c.start + 2) do
    if lines[l] then
      local line = lines[l]:gsub("%s+$", "")
      table.insert(shown, line)
      if line ~= "" then indent = math.min(indent, #line:match("^%s*")) end
    end
  end
  local out = {}
  for _, line in ipairs(shown) do
    table.insert(out, (("   > " .. line:sub(indent + 1)):gsub("%s+$", "")))
  end
  if c["end"] > c.start + 2 then table.insert(out, "   > ...") end
  return out
end

local function message(comments)
  local lines = { "Code review comments from my editor:" }
  for i, c in ipairs(comments) do
    local range = c.start == c["end"] and tostring(c.start) or (c.start .. "-" .. c["end"])
    vim.list_extend(lines, { "", i .. ". " .. c.file .. ":" .. range })
    vim.list_extend(lines, quote(c.repo, c))
    table.insert(lines, "   Comment: " .. (c.body:gsub("\n", "\n   ")))
  end
  vim.list_extend(lines, { "", "Make the requested changes and answer any questions. Reply per item." })
  return table.concat(lines, "\n")
end

-- Exports every comment, or none. Reports ok, the count (or the failure
-- reason) and where the comments went, through cb and, when delivery
-- finishes at once, the return values.
-- opts.pick: choose the agent even when the review is paired with one.
function M.export(target, cb, opts)
  opts = opts or {}
  local result
  local function finish(...)
    result = { ... }
    if cb then cb(...) end
    return ...
  end
  local scope = scope_mod.get() or {}
  local repo = scope.repo or root()
  local comments = store.ordered({ repo = repo })
  if #comments == 0 then return finish(false, "no comments to export") end
  for _, c in ipairs(comments) do
    local ok, reason = valid_comment(c)
    if not ok then
      log.error("export aborted: " .. reason .. " (" .. (c.id or "?") .. ")")
      events.emit("ExportFailed", { reason = reason, comment = c })
      return finish(false, reason)
    end
  end
  local text = message(comments)
  local function delivered(tname, label, cand)
    if not tname then return finish(false, label) end
    if cand then watch_repo = repo; watch_agent(cand) end
    for _, c in ipairs(comments) do c.sent = true end
    events.emit("Exported", { target = tname, label = label, count = #comments })
    return finish(true, #comments, label)
  end
  local transport = require("reviewr.transport")
  if target == "send" or target == "agent" then
    local agent = not opts.pick and paired() or nil
    local target_cand = agent and transport.rex_candidate(agent.block)
    if agent and not target_cand then
      vim.notify("reviewr: " .. agent.name .. " is no longer running in its terminal; choose an agent",
        vim.log.levels.WARN)
    end
    transport.send(text, { repo = repo, mode = config_mod.get().send_mode, target = target_cand, pick = opts.pick },
      delivered)
  elseif target == "inbox" or target == "filesystem-inbox" then
    transport.send(text, { repo = repo, inbox_only = true }, delivered)
  else
    require("reviewr.clipboard").copy(text)
    delivered("clipboard", "clipboard")
  end
  if result then return unpack(result) end
  return true, #comments, "pending"
end

function M.clear(query)
  store.clear(query or {})
  events.emit("Cleared", { query = query })
  require("reviewr.ui").redraw()
  return true
end

function M.close()
  store.clear()
  require("reviewr.rex").unwatch_all()
  -- a Neovim started only for this review (cmd+r in Rex) has nothing left to show
  if vim.g.reviewr_standalone then return vim.cmd("qall!") end
  require("reviewr.ui").close_diff()
end

return M

-- heimdall.ui: review tab, diff windows, changed-files panel, signs, extmarks, floats
local M = {}

local state = {
  ns = nil,
  panel_win = nil,
  panel_buf = nil,
  diff = {},
}

M.config = {
  panel_width = 60,
  panel_height = 20,
  border = "rounded",
}

local function ensure_ns()
  if not state.ns then
    state.ns = vim.api.nvim_create_namespace("heimdall")
  end
  return state.ns
end

local function valid_win(w)
  return w ~= nil and vim.api.nvim_win_is_valid(w)
end

local function highlights()
  for name, link in pairs({
    HeimdallCommentSign = "DiagnosticInfo",
    HeimdallCommentText = "Comment",
    HeimdallPanelBorder = "FloatBorder",
    HeimdallRange = "Visual",
    HeimdallRangeSign = "DiagnosticInfo",
    HeimdallButton = "PmenuSel",
    HeimdallAdded = "Added",
    HeimdallRemoved = "Removed",
    HeimdallPending = "DiagnosticWarn",
    HeimdallOk = "DiagnosticOk",
    HeimdallFail = "DiagnosticError",
    HeimdallDim = "Comment",
    HeimdallNumber = "Number",
    HeimdallHeading = "Title",
    HeimdallRule = "FloatBorder",
    HeimdallPickSel = "CursorLine",
    HeimdallPickBar = "Function",
    HeimdallPickBorder = "Function",
  }) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  -- pills: a colour from the theme as background, the editor background as text
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local text = normal.bg or (vim.o.background == "light" and 0xffffff or 0x000000)
  for name, source in pairs(M.BADGES) do
    local src = vim.api.nvim_get_hl(0, { name = source, link = false })
    vim.api.nvim_set_hl(0, "HeimdallBadge" .. name, { fg = text, bg = src.fg, bold = true })
  end
end

-- badge name -> the highlight group whose colour it takes
M.BADGES = {
  Open = "DiagnosticOk", Draft = "Comment", Merged = "Special", Closed = "DiagnosticError",
  Approved = "DiagnosticOk", Changes = "DiagnosticError", Review = "DiagnosticWarn", Conflicts = "DiagnosticError",
}

local ICONS = {
  pr_open = { "\u{f407}", "●" },
  pr_draft = { "\u{f4dd}", "○" },
  branch = { "\u{e725}", "⎇" },
  user = { "\u{f007}", "@" },
  commit = { "\u{f417}", "" },
}

-- The glyph for `name`: a Nerd Font icon, or plain unicode when `icons` is off.
function M.icon(name)
  return ICONS[name][require("heimdall.config").get().icons and 1 or 2]
end

-- A box title: the icon (when there is one) and the text.
function M.title(icon, text)
  local glyph = M.icon(icon)
  return glyph ~= "" and (glyph .. " " .. text) or text
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  ensure_ns()
  highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("heimdall_highlights", { clear = true }),
    callback = highlights,
  })
  -- a review often opens before its terminal reaches full size, and Neovim
  -- would hand all the new width to the right pane
  vim.api.nvim_create_autocmd("VimResized", {
    group = vim.api.nvim_create_augroup("heimdall_resize", { clear = true }),
    callback = function() M.equalize() end,
  })
end

-- ---------- review tab ----------

function M.is_open()
  return state.diff.tab ~= nil and vim.api.nvim_tabpage_is_valid(state.diff.tab)
    and valid_win(state.diff.left_win) and valid_win(state.diff.right_win)
end

-- A tab of its own, so the review never rearranges the user's windows.
function M.open_tab()
  vim.cmd("tabnew")
  local placeholder = vim.api.nvim_get_current_buf()
  vim.bo[placeholder].bufhidden = "wipe"
  local left_win = vim.api.nvim_get_current_win()
  vim.cmd("rightbelow vsplit")
  local right_win = vim.api.nvim_get_current_win()
  state.diff = { tab = vim.api.nvim_get_current_tabpage(), left_win = left_win, right_win = right_win }
  return state.diff
end

-- Splits the width of the two diff panes evenly.
function M.equalize()
  if not M.is_open() then return end
  local d = state.diff
  local total = vim.api.nvim_win_get_width(d.left_win) + vim.api.nvim_win_get_width(d.right_win)
  vim.api.nvim_win_set_width(d.left_win, math.floor(total / 2))
end

function M.focus_tab()
  if M.is_open() then vim.api.nvim_set_current_tabpage(state.diff.tab) end
end

function M.show_file(left_buf, right_buf, file)
  local d = state.diff
  -- the hint lives in the winbar: statusline plugins such as lualine own the footer
  local bars = { "  base  ", "%!v:lua.require('heimdall.ui').winbar()" }
  for i, pair in ipairs({ { d.left_win, left_buf }, { d.right_win, right_buf } }) do
    vim.api.nvim_win_call(pair[1], function()
      vim.api.nvim_win_set_buf(pair[1], pair[2])
      vim.cmd("diffthis")
    end)
    vim.wo[pair[1]].winbar = bars[i]
    -- with 'cursorline' on, Neovim underlines the cursor line across diff
    -- colours; the line number alone marks it
    vim.wo[pair[1]].cursorlineopt = "number"
  end
  d.left_buf, d.right_buf, d.file = left_buf, right_buf, file
  return d
end

function M.panes()
  return state.diff
end

-- The diff window that is not the current one: where the comment box opens.
function M.alternate_win()
  local d = state.diff
  if vim.api.nvim_get_current_win() == d.right_win and valid_win(d.left_win) then
    return d.left_win
  end
  if valid_win(d.right_win) then return d.right_win end
  return d.left_win
end

function M.close_diff()
  local tab = state.diff.tab
  state.diff = {}
  if not (tab and vim.api.nvim_tabpage_is_valid(tab)) then return end
  -- wiping buffers still in diff mode as the tab closes can crash Neovim
  vim.api.nvim_set_current_tabpage(tab)
  vim.cmd("diffoff!")
  if #vim.api.nvim_list_tabpages() == 1 then vim.cmd("tabnew") end
  vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(tab))
end

-- ---------- changed-files panel ----------
-- A list of every changed file along the bottom, the way octo.nvim shows one
-- during a review. <CR> opens the file under the cursor.
local files_panel = { win = nil, buf = nil, files = {} }

function M.files_panel()
  return files_panel
end

function M.render_files_panel()
  local buf = files_panel.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local store = require("heimdall.store")
  local function at(b) return b and vim.api.nvim_buf_is_valid(b) and vim.b[b].heimdall_at or nil end
  local left_at, right_at = at(state.diff.left_buf), at(state.diff.right_buf)
  -- each row: marker, status, path, then +added -deleted the way octo.nvim
  -- shows them, then the comment count
  local current, lines, marks = nil, {}, {}
  for i, f in ipairs(files_panel.files) do
    local here = f.path == state.diff.file
    if here then current = i end
    local n = #store.shown(f.path, "left", left_at) + #store.shown(f.path, "right", right_at)
    local line = string.format("%s %s  %s", here and "▶" or " ", f.status, f.path)
    if f.added then
      local plus, minus = "+" .. f.added, "-" .. f.deleted
      table.insert(marks, { i - 1, #line + 2, #line + 2 + #plus, "HeimdallAdded" })
      table.insert(marks, { i - 1, #line + 3 + #plus, #line + 3 + #plus + #minus, "HeimdallRemoved" })
      line = line .. "  " .. plus .. " " .. minus
    end
    lines[i] = line .. (n > 0 and ("  💬 " .. n) or "")
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ensure_ns(), 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ensure_ns(), m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  if valid_win(files_panel.win) then
    vim.wo[files_panel.win].winbar = string.format("  changed files (%d)  ", #files_panel.files)
    if current then pcall(vim.api.nvim_win_set_cursor, files_panel.win, { current, 0 }) end
  end
end

function M.open_files_panel(files)
  files_panel.files = files or files_panel.files
  if not valid_win(files_panel.win) then
    local origin = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "heimdall-files"
    -- the rows, plus the title bar
    local height = require("heimdall.config").get().files_panel_height + 1
    vim.api.nvim_win_call(state.diff.left_win, function() vim.cmd("botright " .. height .. "split") end)
    local win = vim.fn.win_getid(vim.fn.winnr("$"), vim.api.nvim_tabpage_get_number(state.diff.tab))
    vim.api.nvim_win_set_buf(win, buf)
    for opt, val in pairs({ diff = false, scrollbind = false, cursorbind = false, foldenable = false,
      foldcolumn = "0", winfixheight = true, cursorline = true, cursorlineopt = "line", number = false,
      relativenumber = false, signcolumn = "no", wrap = false }) do
      vim.wo[win][opt] = val
    end
    files_panel.win, files_panel.buf = win, buf
    -- the review keys work here too, except those that act on a diff line
    require("heimdall.keymaps").install(buf, { panel = true })
    vim.keymap.set("n", "<CR>", function()
      local f = files_panel.files[vim.fn.line(".")]
      if not f then return end
      require("heimdall").open_file(f.path)
      if valid_win(state.diff.right_win) then vim.api.nvim_set_current_win(state.diff.right_win) end
    end, { buffer = buf, silent = true, nowait = true })
    if valid_win(origin) then vim.api.nvim_set_current_win(origin) end
    M.equalize()
  end
  M.render_files_panel()
end

-- ---------- range highlight while commenting ----------

function M.mark_range(bufnr, startl, endl)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local last = vim.api.nvim_buf_line_count(bufnr)
  -- marked in the gutter: diff highlighting would hide a line highlight
  for line = startl, math.min(endl, last) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ensure_ns(), line - 1, 0, {
      sign_text = "▌", sign_hl_group = "HeimdallRangeSign", number_hl_group = "HeimdallRange", priority = 50,
    })
  end
end

function M.clear_range(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then M.redraw(bufnr) end
end

-- ---------- comments in the diff ----------

function M.redraw(bufnr)
  if bufnr == nil then
    for _, b in ipairs({ state.diff.left_buf, state.diff.right_buf }) do
      if b then M.redraw(b) end
    end
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, ensure_ns(), 0, -1)
  local file, side = vim.b[bufnr].heimdall_file, vim.b[bufnr].heimdall_side
  if file then
    local last = vim.api.nvim_buf_line_count(bufnr)
    for _, c in ipairs(require("heimdall.store").shown(file, side, vim.b[bufnr].heimdall_at)) do
      local row = math.min(c.start, last) - 1
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ensure_ns(), row, 0, {
        sign_text = "💬",
        sign_hl_group = "HeimdallCommentSign",
        virt_lines = vim.tbl_map(function(l) return { { "  " .. l, "HeimdallCommentText" } } end,
          vim.split(c.body or "", "\n", { plain = true })),
        -- Neovim draws nothing above the first line, so that one goes below
        virt_lines_above = row > 0,
      })
    end
  end
  M.render_files_panel()
  pcall(vim.cmd, "redrawstatus!")
end

-- The comment under the cursor, if the cursor sits inside its range.
function M.comment_at_cursor()
  local file = vim.b.heimdall_file
  if not file then return nil end
  local lnum = vim.fn.line(".")
  for _, c in ipairs(require("heimdall.store").shown(file, vim.b.heimdall_side, vim.b.heimdall_at)) do
    if lnum >= c.start and lnum <= c["end"] then return c end
  end
  return nil
end

-- ---------- comment list ----------

function M.toggle_panel()
  if valid_win(state.panel_win) then
    vim.api.nvim_win_close(state.panel_win, true)
    state.panel_win, state.panel_buf = nil, nil
    return false
  end
  local lines = {}
  for _, c in ipairs(require("heimdall.store").ordered()) do
    lines[#lines + 1] = string.format(" %s:%d (%s)", c.file, c.start, c.side)
    lines[#lines + 1] = "   └ " .. (c.body or ""):gsub("\n", " ")
  end
  if #lines == 0 then lines[1] = "   (no comments)" end
  state.panel_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(state.panel_buf, 0, -1, false, lines)
  vim.bo[state.panel_buf].modifiable = false
  vim.bo[state.panel_buf].bufhidden = "wipe"
  local width = math.min(M.config.panel_width, vim.o.columns - 4)
  state.panel_win = vim.api.nvim_open_win(state.panel_buf, true, {
    relative = "editor",
    width = width,
    height = math.min(M.config.panel_height, #lines),
    col = vim.o.columns - width - 2,
    row = 1,
    style = "minimal",
    border = M.config.border,
    title = " comments ",
    title_pos = "center",
  })
  vim.wo[state.panel_win].winhl = "Normal:Normal,FloatBorder:HeimdallPanelBorder"
  for _, key in ipairs({ "l", "q", "<esc>" }) do
    vim.keymap.set("n", key, M.toggle_panel, { buffer = state.panel_buf, silent = true, nowait = true })
  end
  return true
end

-- ---------- confirm ----------

-- A small yes/no box. Yes starts highlighted, so <CR> confirms; <Right> or
-- <Tab> moves to No and <Left> back, <CR> takes the highlighted choice, and
-- <Esc> cancels. y and n answer directly.
function M.confirm(title, message, on_yes)
  local width = math.max(vim.fn.strwidth(message) + 4, 26)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = 3,
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    row = math.max(0, math.floor((vim.o.lines - 5) / 2)),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })
  vim.wo[win].winhl = "Normal:Normal,FloatBorder:HeimdallPanelBorder"
  local buttons = { "  Yes  ", "  No  " }
  local gap = "   "
  local pad = math.floor((width - vim.fn.strwidth(buttons[1] .. gap .. buttons[2])) / 2)
  local selected = 1
  local function render()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      " " .. message, "", string.rep(" ", pad) .. buttons[1] .. gap .. buttons[2],
    })
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ensure_ns(), 0, -1)
    local start = pad + (selected == 1 and 0 or #buttons[1] + #gap)
    vim.api.nvim_buf_set_extmark(buf, ensure_ns(), 2, start, {
      end_col = start + #buttons[selected], hl_group = "HeimdallButton",
    })
    pcall(vim.api.nvim_win_set_cursor, win, { 3, start })
  end
  local function finish(yes)
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if yes then on_yes() end
  end
  local function map(keys, fn)
    for _, key in ipairs(keys) do
      vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true })
    end
  end
  map({ "<CR>" }, function() finish(selected == 1) end)
  map({ "<Right>", "l", "<Tab>" }, function() selected = 2; render() end)
  map({ "<Left>", "h", "<S-Tab>" }, function() selected = 1; render() end)
  map({ "<Esc>", "q", "n" }, function() finish(false) end)
  map({ "y" }, function() finish(true) end)
  render()
  return win
end

-- ---------- pick ----------

local BACKDROP_Z, PICK_Z = 55, 60
local PANEL_MIN_COLUMNS = 120
local pick_ns

-- A line of a Details panel that fills the panel's width with a thin rule.
M.RULE = "\1"

-- text cut to `width` display columns, ending in … when it was cut
function M.truncate(text, width)
  if vim.fn.strwidth(text) <= width then return text end
  local n = vim.fn.strchars(text)
  while n > 0 and vim.fn.strwidth(vim.fn.strcharpart(text, 0, n)) > width - 1 do n = n - 1 end
  return vim.fn.strcharpart(text, 0, n) .. "…"
end

-- title cut into what fits in `room` columns (at a space when there is one) and the rest
local function split_title(title, room)
  local cut = vim.fn.strchars(title)
  while cut > 0 and vim.fn.strwidth(vim.fn.strcharpart(title, 0, cut)) > room do cut = cut - 1 end
  local head = vim.fn.strcharpart(title, 0, cut)
  local space = head:match("^.*()%s")
  if space and space > 1 then head = head:sub(1, space - 1) end
  return head, vim.trim(title:sub(#head + 1))
end

-- One list row: segments { { text, hl? }, ... } inside a 1-col pad each side,
-- cut to `width`, with an optional { text, hl } right-aligned. Returns the
-- text and its highlights as { col_start, col_end, hl } (bytes).
local function compose(segments, width, mark)
  local text, spans = " ", {}
  local room = width - 2 - (mark and vim.fn.strwidth(mark[1]) + 1 or 0)
  for _, seg in ipairs(segments) do
    if room <= 0 then break end
    local piece = M.truncate(seg[1], room)
    if seg[2] then table.insert(spans, { #text, #text + #piece, seg[2] }) end
    text = text .. piece
    room = room - vim.fn.strwidth(piece)
    if piece ~= seg[1] then break end
  end
  if mark then
    text = text .. string.rep(" ", width - 1 - vim.fn.strwidth(text) - vim.fn.strwidth(mark[1]))
    table.insert(spans, { #text, #text + #mark[1], mark[2] })
    text = text .. mark[1]
  end
  return text, spans
end

-- The ruler, showcmd, statusline, tabline and cmdline show under the backdrop,
-- so they are hidden while a picker is open and put back with the last one.
local chrome = { depth = 0, saved = nil }
local CHROME = { ruler = false, showcmd = false, laststatus = 0, showtabline = 0, cmdheight = 0 }

local function hide_chrome()
  if chrome.depth == 0 then
    chrome.saved = {}
    for name in pairs(CHROME) do chrome.saved[name] = vim.o[name] end
    for name, value in pairs(CHROME) do vim.o[name] = value end
  end
  chrome.depth = chrome.depth + 1
end

local function restore_chrome()
  chrome.depth = chrome.depth - 1
  if chrome.depth == 0 then
    -- cmdheight first: restoring laststatus may need the room
    vim.o.cmdheight = chrome.saved.cmdheight
    for name, value in pairs(chrome.saved) do vim.o[name] = value end
    chrome.saved = nil
  end
end

-- A list in a centered box over a blank backdrop, taking vim.ui.select's
-- arguments: j/k or the arrows move, <CR> picks, / filters by words, <Esc>
-- clears the filter or cancels (on_choice(nil)), q cancels. Returns a handle: { win, is_open(), set_items(items),
-- set_status(text, hl), set_preview(item, lines, popts), has_preview(item) }.
--   opts.prompt       box title
--   opts.format_item  one plain line per item, or
--   opts.render_item  item -> lines, each a list of { text, hl? } segments
--   opts.action       the <CR> hint in the footer (default "select")
--   opts.key          item -> string identifying it across set_items
--   opts.stamp        item -> string; a cached preview is dropped when it changes
--   opts.mark         item -> { text, hl } shown at the right of its first line
--   opts.search_text  item -> the text `/` matches (default: its rendered rows)
--   opts.preview      (item, done) fills a Details panel beside the list when
--                     the editor is wide enough; done(lines, { markdown?,
--                     highlights?, mark?, badges? }); a mark given there replaces
--                     opts.mark; badges ({ text, hl } pills) go at the top right.
-- An item that is a table with a `heading` or `note` string (and an optional
-- `hl`) is a static row: shown, never selected.
local function open_pick(all_items, opts, on_choice, release)
  opts = opts or {}
  local items = all_items
  local format = opts.format_item or tostring
  local render = opts.render_item or function(item) return { { { format(item) } } } end
  local ns = ensure_ns()
  pick_ns = pick_ns or vim.api.nvim_create_namespace("heimdall_pick")

  local function is_static(item) return type(item) == "table" and (item.heading or item.note) ~= nil end
  local function lines_of(item)
    if is_static(item) then
      return { { { item.heading or item.note, item.hl or (item.heading and "HeimdallHeading" or "HeimdallDim") } } }
    end
    return render(item)
  end
  local function cache_key(item)
    if not opts.key then return item end
    return opts.key(item) .. "\0" .. (opts.stamp and opts.stamp(item) or "")
  end

  local widest, line_count
  local function measure()
    widest, line_count = vim.fn.strwidth(opts.prompt or "") + 4, 0
    for _, item in ipairs(all_items) do
      for _, segs in ipairs(lines_of(item)) do
        line_count = line_count + 1
        local w = 0
        for _, seg in ipairs(segs) do w = w + vim.fn.strwidth(seg[1]) end
        widest = math.max(widest, w + 2)
      end
    end
  end
  measure()

  local query, search_open = "", false
  local function haystack(item)
    if opts.search_text then return opts.search_text(item) end
    local parts = {}
    for _, segs in ipairs(render(item)) do
      for _, seg in ipairs(segs) do parts[#parts + 1] = seg[1] end
    end
    return table.concat(parts, " ")
  end
  -- the items whose text holds every word of the query, under their headings
  local function filtered()
    local words = vim.split(query:lower(), "%s+", { trimempty = true })
    if #words == 0 then return all_items end
    local out, heading = {}, nil
    for _, item in ipairs(all_items) do
      if is_static(item) then
        heading = item.heading and item or nil
      else
        local text, hit = haystack(item):lower(), true
        for _, w in ipairs(words) do
          if not text:find(w, 1, true) then hit = false; break end
        end
        if hit then
          if heading then out[#out + 1] = heading; heading = nil end
          out[#out + 1] = item
        end
      end
    end
    return #out > 0 and out or { { note = "No matches" } }
  end

  local status
  local function footer(side)
    local chunks = { { " ↵ " .. (opts.action or "select") .. "  / search  esc close" .. (side and "  ^d ^u scroll" or "") .. " ", "HeimdallDim" } }
    if status then table.insert(chunks, { status[1] .. " ", status[2] }) end
    return chunks
  end

  local function layout()
    local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
    local height = math.max(1, math.min(line_count, vim.o.lines - 6))
    local side = opts.preview ~= nil and cols >= PANEL_MIN_COLUMNS
    local list_w = math.min(math.max(widest, 36), cols - 4)
    local panel_w
    if side then
      local inner = math.min(cols - 4, 180) - 4
      list_w = math.floor(inner * 0.45)
      panel_w = inner - list_w
      height = math.max(height, math.min(15, vim.o.lines - 6))
    end
    local group = list_w + 2 + (side and panel_w + 2 or 0)
    local col = math.max(0, math.floor((cols - group) / 2))
    local search_h = search_open and 3 or 0
    local row = math.max(0, math.floor((rows - height - 2 - search_h) / 2))
    return {
      backdrop = { relative = "editor", width = cols, height = rows, row = 0, col = 0 },
      search = search_open and { relative = "editor", width = group - 2, height = 1, row = row, col = col } or nil,
      list = {
        relative = "editor", width = list_w, height = height, row = row + search_h, col = col,
        title = " " .. (opts.prompt or "") .. " ", title_pos = "center",
        footer = footer(side), footer_pos = "center",
      },
      panel = side and { relative = "editor", width = panel_w, height = height, row = row + search_h, col = col + list_w + 2 } or nil,
    }
  end
  local geo = layout()

  local backdrop_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[backdrop_buf].bufhidden = "wipe"
  local backdrop = vim.api.nvim_open_win(backdrop_buf, false, vim.tbl_extend("force", geo.backdrop, {
    focusable = false, style = "minimal", zindex = BACKDROP_Z,
  }))
  vim.wo[backdrop].winhl = "Normal:Normal"
  vim.wo[backdrop].fillchars = "eob: "

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, true, vim.tbl_extend("force", geo.list, {
    style = "minimal", border = "rounded", zindex = PICK_Z,
  }))
  vim.wo[win].winhl = "Normal:Normal,FloatBorder:HeimdallPickBorder,FloatTitle:HeimdallPickBorder,FloatFooter:HeimdallDim"
  vim.wo[win].scrolloff = 0
  -- the selection is drawn by paint_selection, not the inherited cursor line
  vim.wo[win].cursorline = false

  local panel_buf, panel_win, panel_content
  local search_buf, search_win
  local cache, shown, generation = {}, nil, 0
  local entries, sel = {}, nil -- sel: index of the selected item, nil when there is none

  local function paint_selection()
    vim.api.nvim_buf_clear_namespace(buf, pick_ns, 0, -1)
    local e = sel and entries[sel]
    if not e then return end
    for line = e.first, e.last do
      vim.api.nvim_buf_set_extmark(buf, pick_ns, line - 1, 0, { line_hl_group = "HeimdallPickSel", priority = 10 })
      vim.api.nvim_buf_set_extmark(buf, pick_ns, line - 1, 0, {
        virt_text = { { "▎", "HeimdallPickBar" } }, virt_text_pos = "overlay",
      })
    end
  end

  -- Rewrites the rows.
  local function draw()
    local width = geo.list.width
    local rows, spans = {}, {}
    entries = {}
    for i, item in ipairs(items) do
      local entry = { first = #rows + 1, static = is_static(item) }
      local mark
      if not entry.static then
        local hit = cache[cache_key(item)]
        mark = (hit and hit[2] and hit[2].mark) or (opts.mark and opts.mark(item))
      end
      for n, segs in ipairs(lines_of(item)) do
        local text, marks = compose(segs, width, n == 1 and mark or nil)
        table.insert(rows, text)
        for _, m in ipairs(marks) do table.insert(spans, { #rows - 1, m[1], m[2], m[3] }) end
      end
      entry.last = #rows
      entries[i] = entry
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, sp in ipairs(spans) do
      vim.api.nvim_buf_set_extmark(buf, ns, sp[1], sp[2], { end_col = sp[3], hl_group = sp[4] })
    end
    paint_selection()
  end

  -- draw() with the view where it was
  local function redraw()
    local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    draw()
    vim.api.nvim_win_call(win, function() vim.fn.winrestview(view) end)
  end

  local function render_panel(lines, popts)
    if not (panel_win and vim.api.nvim_win_is_valid(panel_win)) then return end
    panel_content = { lines, popts }
    popts = popts or {}
    local rule = string.rep("─", math.max(1, geo.panel.width - 2))
    local rules = {}
    lines = vim.list_slice(lines)
    local highlights = vim.list_slice(popts.highlights or {})
    local pills = popts.badges or {}
    local pills_w = 0
    for _, b in ipairs(pills) do pills_w = pills_w + vim.fn.strwidth(b[1]) + 1 end
    -- the pills sit right-aligned on the title's first row, so a title too long
    -- to share it is split there and the rest wraps below
    local room = geo.panel.width - 1 - pills_w - 1
    if pills_w > 0 and vim.fn.strwidth(lines[1]) > room then
      local head, rest = split_title(lines[1], math.max(10, room))
      lines[1] = head
      table.insert(lines, 2, rest)
      for _, h in ipairs(highlights) do
        if h[1] >= 1 then h[1] = h[1] + 1 end
      end
      for _, h in ipairs(vim.list_slice(highlights)) do
        if h[1] == 0 then
          h[3] = #head
          table.insert(highlights, { 1, 0, #rest, h[4] })
        end
      end
    end
    for i, l in ipairs(lines) do
      if l == M.RULE then
        lines[i] = rule
        table.insert(rules, i - 1)
      end
    end
    vim.bo[panel_buf].modifiable = true
    vim.api.nvim_buf_set_lines(panel_buf, 0, -1, false, lines)
    vim.bo[panel_buf].modifiable = false
    if popts.markdown then pcall(vim.treesitter.start, panel_buf, "markdown") else pcall(vim.treesitter.stop, panel_buf) end
    vim.api.nvim_buf_clear_namespace(panel_buf, ns, 0, -1)
    for _, h in ipairs(highlights) do
      vim.api.nvim_buf_set_extmark(panel_buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4], priority = 200 })
    end
    if pills_w > 0 then
      local chunks = {}
      for _, b in ipairs(pills) do vim.list_extend(chunks, { { b[1], b[2] }, { " " } }) end
      vim.api.nvim_buf_set_extmark(panel_buf, ns, 0, 0, { virt_text = chunks, virt_text_pos = "right_align" })
    end
    for _, line in ipairs(rules) do
      vim.api.nvim_buf_set_extmark(panel_buf, ns, line, 0, { end_col = #rule, hl_group = "HeimdallRule", priority = 200 })
    end
    vim.api.nvim_win_call(panel_win, function() vim.fn.winrestview({ topline = 1, lnum = 1 }) end)
  end

  local function show_preview()
    if not panel_win then return end
    if not sel then
      shown = nil
      return render_panel({ "" })
    end
    local item = items[sel]
    local ck = cache_key(item)
    if ck == shown then return end
    shown = ck
    local hit = cache[ck]
    if hit then return render_panel(hit[1], hit[2]) end
    render_panel({ "Loading…" }, { highlights = { { 0, 0, #"Loading…", "HeimdallDim" } } })
    generation = generation + 1
    local mine = generation
    vim.defer_fn(function()
      if mine ~= generation or not panel_win then return end
      opts.preview(item, function(lines, popts)
        cache[ck] = { lines, popts }
        if shown == ck then render_panel(lines, popts) end
        if popts and popts.mark and vim.api.nvim_buf_is_valid(buf) then redraw() end
      end)
    end, 80)
  end

  local function step(from, dir)
    local k = from + dir
    while entries[k] and entries[k].static do k = k + dir end
    return entries[k] and k or nil
  end

  -- Selects item k: cursor on its first line, the whole item (and a heading
  -- right above it) in view.
  local function focus(k)
    sel = k
    local e = entries[k]
    local above = entries[k - 1]
    local want_top = (above and above.static) and above.first or e.first
    vim.api.nvim_win_call(win, function()
      local top = vim.fn.winsaveview().topline
      local height = vim.api.nvim_win_get_height(win)
      if e.last > top + height - 1 then top = e.last - height + 1 end
      if want_top < top then top = want_top end
      vim.fn.winrestview({ topline = top, lnum = e.first, col = 0 })
    end)
    paint_selection()
    show_preview()
  end

  -- Keeps the selection where it is; `want` ({ key, index }) says which item
  -- to keep after the items changed.
  local function reselect(want)
    local k
    if want and want.key and opts.key then
      for i, item in ipairs(items) do
        if not is_static(item) and opts.key(item) == want.key then k = i end
      end
    end
    if not k and want and want.index then
      local at = math.min(want.index, #items)
      k = (entries[at] and not entries[at].static) and at or (step(at, 1) or step(at, -1))
    end
    k = k or step(0, 1)
    if k then focus(k) else sel = nil; paint_selection(); show_preview() end
  end

  local function relayout(want)
    geo = layout()
    vim.api.nvim_win_set_config(backdrop, geo.backdrop)
    vim.api.nvim_win_set_config(win, geo.list)
    draw()
    reselect(want or (sel and { index = sel }))
    local panel = geo.panel
    if panel and not panel_win then
      panel_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[panel_buf].bufhidden = "wipe"
      panel_win = vim.api.nvim_open_win(panel_buf, false, vim.tbl_extend("force", panel, {
        focusable = false, style = "minimal", border = "rounded", title = " Details ", title_pos = "center",
        zindex = PICK_Z,
      }))
      vim.wo[panel_win].winhl = "Normal:Normal,FloatBorder:HeimdallPanelBorder,FloatTitle:HeimdallDim,FoldColumn:Normal"
      vim.wo[panel_win].wrap = true
      vim.wo[panel_win].linebreak = true
      vim.wo[panel_win].foldcolumn = "1"
      vim.wo[panel_win].conceallevel = 2
      shown = nil
      show_preview()
    elseif panel then
      vim.api.nvim_win_set_config(panel_win, panel)
      if panel_content then render_panel(panel_content[1], panel_content[2]) end
    elseif panel_win then
      vim.api.nvim_win_close(panel_win, true)
      panel_win, panel_buf, panel_content = nil, nil, nil
    end
    if geo.search and not search_win then
      search_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[search_buf].bufhidden = "wipe"
      search_win = vim.api.nvim_open_win(search_buf, false, vim.tbl_extend("force", geo.search, {
        style = "minimal", border = "rounded", zindex = PICK_Z,
      }))
      vim.wo[search_win].winhl = "Normal:Normal,FloatBorder:HeimdallPickBorder"
      vim.api.nvim_buf_set_lines(search_buf, 0, -1, false, { query })
      vim.api.nvim_buf_set_extmark(search_buf, ns, 0, 0, {
        virt_text = { { " / ", "HeimdallPickBorder" } }, virt_text_pos = "inline", right_gravity = false,
      })
    elseif geo.search then
      vim.api.nvim_win_set_config(search_win, geo.search)
    elseif search_win then
      if vim.api.nvim_win_is_valid(search_win) then vim.api.nvim_win_close(search_win, true) end
      search_win, search_buf = nil, nil
    end
  end

  -- the list again for the query in the search box, the first match selected
  local function sync_query()
    if not (search_buf and vim.api.nvim_buf_is_valid(search_buf)) then return end
    local text = vim.api.nvim_buf_get_lines(search_buf, 0, 1, false)[1] or ""
    if text == query then return end
    query = text
    items = filtered()
    shown, sel = nil, nil
    draw()
    reselect()
  end

  local done = false
  local group = vim.api.nvim_create_augroup("heimdall_pick_" .. buf, { clear = true })
  local function finish(choice)
    if done then return end
    done = true
    vim.api.nvim_del_augroup_by_id(group)
    if vim.fn.mode() == "i" then vim.cmd.stopinsert() end
    for _, w in pairs({ win = win, panel = panel_win, search = search_win, backdrop = backdrop }) do
      if vim.api.nvim_win_is_valid(w) then vim.api.nvim_win_close(w, true) end
    end
    release()
    on_choice(choice)
  end
  local function map(keys, fn)
    for _, key in ipairs(keys) do
      vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true })
    end
  end
  local function move(dir)
    local k = sel and step(sel, dir)
    if k then focus(k) end
  end
  map({ "j", "<Down>", "<C-n>", "<C-j>" }, function() move(1) end)
  map({ "k", "<Up>", "<C-p>", "<C-k>" }, function() move(-1) end)
  -- window and pane motions (often on <C-h>/<C-l>) would leave the modal picker
  map({ "<C-h>", "<C-l>", "<C-w>" }, function() end)
  map({ "gg" }, function() local k = step(0, 1); if k then focus(k) end end)
  map({ "G" }, function() local k = step(#entries + 1, -1); if k then focus(k) end end)
  map({ "<CR>" }, function() if sel then finish(items[sel]) end end)
  map({ "q" }, function() finish(nil) end)

  local function close_search()
    vim.cmd.stopinsert()
    search_open = false
    if query ~= "" then
      query = ""
      items = all_items
      shown, sel = nil, nil
    end
    relayout()
    vim.api.nvim_set_current_win(win)
  end
  map({ "<Esc>" }, function()
    if search_open then close_search() else finish(nil) end
  end)
  map({ "/" }, function()
    if not search_open then
      search_open = true
      relayout()
      vim.api.nvim_buf_attach(search_buf, false, { on_lines = function() vim.schedule(sync_query) end })
      local function imap(keys, fn)
        for _, key in ipairs(keys) do
          vim.keymap.set("i", key, fn, { buffer = search_buf, silent = true, nowait = true })
        end
      end
      imap({ "<CR>" }, function()
        sync_query()
        if sel then finish(items[sel]) end
      end)
      imap({ "<Down>", "<C-n>", "<C-j>" }, function() sync_query(); move(1) end)
      imap({ "<Up>", "<C-p>", "<C-k>" }, function() sync_query(); move(-1) end)
      imap({ "<C-c>" }, function() finish(nil) end)
      -- Esc keeps the filter and goes back to the list; an empty query closes the box
      imap({ "<Esc>" }, function()
        sync_query()
        if query == "" then return close_search() end
        vim.cmd.stopinsert()
        vim.api.nvim_set_current_win(win)
      end)
      for _, key in ipairs({ "<Esc>", "q" }) do
        vim.keymap.set("n", key, function() vim.api.nvim_set_current_win(win) end,
          { buffer = search_buf, silent = true, nowait = true })
      end
      vim.keymap.set("n", "<CR>", function()
        sync_query()
        if sel then finish(items[sel]) end
      end, { buffer = search_buf, silent = true, nowait = true })
    end
    vim.api.nvim_set_current_win(search_win)
    vim.cmd.startinsert({ bang = true })
  end)
  if opts.preview then
    for key, scroll in pairs({ ["<C-d>"] = "\4", ["<C-u>"] = "\21" }) do
      map({ key }, function()
        if panel_win then
          vim.api.nvim_win_call(panel_win, function() vim.cmd.normal({ args = { scroll }, bang = true }) end)
        end
      end)
    end
  end

  -- The picker is modal: whatever takes focus (a notification, a window
  -- motion such as a <C-h> mapping) hands it back; only <Esc>, q or a pick close it.
  vim.api.nvim_create_autocmd("WinLeave", { group = group, callback = function(ev)
    if ev.buf ~= buf and ev.buf ~= search_buf then return end
    vim.schedule(function()
      if done then return end
      if not vim.api.nvim_win_is_valid(win) then return finish(nil) end
      local cur = vim.api.nvim_get_current_win()
      if cur == win or cur == search_win then return end
      if vim.fn.mode() == "i" then vim.cmd.stopinsert() end
      vim.api.nvim_set_current_win(win)
    end)
  end })
  vim.api.nvim_create_autocmd("VimResized", { group = group, callback = function() relayout() end })
  -- a click or any other motion lands on one item's first line
  vim.api.nvim_create_autocmd("CursorMoved", { group = group, buffer = buf, callback = function()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    for k, e in ipairs(entries) do
      if line >= e.first and line <= e.last then
        local target = e.static and (step(k, 1) or step(k, -1)) or k
        if target and (target ~= sel or line ~= entries[target].first) then focus(target) end
        return
      end
    end
  end })
  relayout()

  local handle = { win = win }
  function handle.is_open() return not done end
  function handle.set_items(new)
    if done then return end
    local current = sel and items[sel]
    local want = { index = sel, key = current and opts.key and opts.key(current) or nil }
    all_items = new
    items = filtered()
    measure()
    shown, sel = nil, nil
    relayout(want)
  end
  function handle.set_status(text, hl)
    if done then return end
    status = text and { text, hl or "HeimdallDim" } or nil
    vim.api.nvim_win_set_config(win, { footer = footer(panel_win ~= nil), footer_pos = "center" })
  end
  function handle.has_preview(item) return cache[cache_key(item)] ~= nil end
  function handle.set_preview(item, lines, popts)
    if done then return end
    local ck = cache_key(item)
    cache[ck] = { lines, popts }
    if shown == ck then render_panel(lines, popts) end
    if popts and popts.mark then redraw() end
  end
  return handle
end

function M.pick(items, opts, on_choice)
  hide_chrome()
  local released = false
  local function release()
    if released then return end
    released = true
    restore_chrome()
  end
  local ok, handle = pcall(open_pick, items, opts, on_choice, release)
  if not ok then
    release()
    error(handle, 0)
  end
  return handle
end

-- ---------- help ----------
local help_state = { win = nil, buf = nil }

function M.toggle_help(legend)
  if valid_win(help_state.win) then
    vim.api.nvim_win_close(help_state.win, true)
    help_state.win, help_state.buf = nil, nil
    return false
  end
  legend = legend or require("heimdall.keymaps").legend
  local lines = { " heimdall: keys", "" }
  local width = 28
  for _, row in ipairs(legend) do
    local key = " " .. row[1] .. string.rep(" ", math.max(1, 5 - vim.fn.strwidth(row[1])))
    lines[#lines + 1] = key .. row[2]
    width = math.max(width, vim.fn.strwidth(lines[#lines]) + 2)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = " press ? or q to close"
  help_state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(help_state.buf, 0, -1, false, lines)
  vim.bo[help_state.buf].modifiable = false
  vim.bo[help_state.buf].bufhidden = "wipe"
  help_state.win = vim.api.nvim_open_win(help_state.buf, true, {
    relative = "editor",
    width = width,
    height = #lines,
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    row = math.max(0, math.floor((vim.o.lines - #lines) / 2)),
    style = "minimal",
    border = "rounded",
    title = " ? ",
    title_pos = "center",
  })
  vim.wo[help_state.win].winhl = "Normal:Normal,FloatBorder:HeimdallPanelBorder"
  for _, key in ipairs({ "?", "q", "<esc>" }) do
    vim.keymap.set("n", key, function() M.toggle_help() end,
      { buffer = help_state.buf, silent = true, nowait = true })
  end
  return true
end

-- ---------- hint bar ----------

-- The bar says the next useful step, the way herdr-reviewr's footer does.
function M.hint(count)
  if (count or 0) == 0 then
    return "c  comment on this line    ?  all keys"
  end
  return "s  send to agent    y  copy    ?  all keys"
end

function M.winbar()
  local n = require("heimdall.store").count()
  local s = require("heimdall.scope").get()
  local agent = require("heimdall").paired()
  local name = s and (s.label or s.name)
  local left = "  change " .. (name and ("│ " .. name .. " ") or "")
    .. "│ " .. n .. (n == 1 and " comment" or " comments")
    .. (agent and ("  → " .. agent.name) or "")
  local right = M.hint(#require("heimdall.store").unsent()) .. " "
  local width = vim.api.nvim_win_get_width(vim.g.statusline_winid or 0)
  local gap = width - vim.fn.strwidth(left) - vim.fn.strwidth(right)
  if gap < 2 then return left end
  return left .. string.rep(" ", gap) .. right
end

return M

-- reviewr.github: the one place that talks to the gh CLI
local M = {}

local PR_FIELDS = "number,title,headRefName,baseRefName,author,updatedAt,isDraft"
local VIEW_FIELDS = "number,title,baseRefName,headRefName,headRepository,headRepositoryOwner,url"
local DETAIL_FIELDS = "number,title,state,isDraft,author,headRefName,baseRefName,reviewDecision,mergeable,"
  .. "additions,deletions,changedFiles,statusCheckRollup,body,url,updatedAt"
local SEARCH_FIELDS = "number,title,author,updatedAt,isDraft,url,repository"

-- Decoded JSON from `gh args`, or nil and gh's stderr.
function M.run(args, opts)
  opts = opts or {}
  local cmd = { "gh" }
  vim.list_extend(cmd, args)
  local ok, res = pcall(function() return vim.system(cmd, { cwd = opts.cwd, text = true }):wait(opts.timeout or 30000) end)
  if not ok then return nil, "gh failed to run: " .. tostring(res) end
  if res.code ~= 0 then
    local why = vim.trim(res.stderr or "")
    return nil, why ~= "" and why or ("gh exited with " .. tostring(res.code))
  end
  local decoded, data = pcall(vim.json.decode, res.stdout)
  if not decoded then return nil, "gh returned invalid JSON: " .. tostring(data) end
  return data
end

-- Async twin of M.run: cb(decoded) or cb(nil, err), on the main loop.
function M.run_async(args, opts, cb)
  local cmd = { "gh" }
  vim.list_extend(cmd, args)
  local ok, err = pcall(vim.system, cmd, { cwd = opts.cwd, text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        local why = vim.trim(res.stderr or "")
        return cb(nil, why ~= "" and why or ("gh exited with " .. tostring(res.code)))
      end
      local decoded, data = pcall(vim.json.decode, res.stdout)
      if not decoded then return cb(nil, "gh returned invalid JSON: " .. tostring(data)) end
      cb(data)
    end)
  end)
  if not ok then cb(nil, "gh failed to run: " .. tostring(err)) end
end

function M.list_prs(cwd)
  return M.run({ "pr", "list", "--state", "open", "--limit", "100", "--json", PR_FIELDS }, { cwd = cwd })
end

-- number: a PR number; repo: "owner/name" when it isn't the repository at cwd.
function M.view_pr(number, repo, cwd)
  local args = { "pr", "view", tostring(number), "--json", VIEW_FIELDS }
  if repo then vim.list_extend(args, { "--repo", repo }) end
  return M.run(args, { cwd = cwd })
end

-- What the picker's side panel shows; repo: "owner/name" when it isn't the repository at cwd.
function M.pr_details(number, repo, cwd, cb)
  local args = { "pr", "view", tostring(number), "--json", DETAIL_FIELDS }
  if repo then vim.list_extend(args, { "--repo", repo }) end
  M.run_async(args, { cwd = cwd }, cb)
end

-- Open PRs authored by me or waiting on my review, newest update first; each
-- has `section` "yours" or "requested" (a PR of mine asked of me too is "yours").
function M.search_prs()
  local seen, out = {}, {}
  for _, who in ipairs({ "--author=@me", "--review-requested=@me" }) do
    local found, err = M.run({ "search", "prs", "--state=open", who, "--limit", "50", "--json", SEARCH_FIELDS })
    if not found then return nil, err end
    for _, pr in ipairs(found) do
      if not seen[pr.url] then
        seen[pr.url] = true
        pr.section = who == "--author=@me" and "yours" or "requested"
        table.insert(out, pr)
      end
    end
  end
  table.sort(out, function(a, b) return (a.updatedAt or "") > (b.updatedAt or "") end)
  return out
end

return M

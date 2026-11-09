-- reviewr.github: the one place that talks to the gh CLI
local M = {}

local PR_FIELDS = "number,title,headRefName,baseRefName,author,updatedAt,isDraft"
local VIEW_FIELDS = "number,title,baseRefName,headRefName,headRepository,headRepositoryOwner,url"
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

function M.list_prs(cwd)
  return M.run({ "pr", "list", "--state", "open", "--limit", "100", "--json", PR_FIELDS }, { cwd = cwd })
end

-- number: a PR number; repo: "owner/name" when it isn't the repository at cwd.
function M.view_pr(number, repo, cwd)
  local args = { "pr", "view", tostring(number), "--json", VIEW_FIELDS }
  if repo then vim.list_extend(args, { "--repo", repo }) end
  return M.run(args, { cwd = cwd })
end

-- Open PRs authored by me or waiting on my review, newest update first.
function M.search_prs()
  local seen, out = {}, {}
  for _, who in ipairs({ "--author=@me", "--review-requested=@me" }) do
    local found, err = M.run({ "search", "prs", "--state=open", who, "--limit", "50", "--json", SEARCH_FIELDS })
    if not found then return nil, err end
    for _, pr in ipairs(found) do
      if not seen[pr.url] then
        seen[pr.url] = true
        table.insert(out, pr)
      end
    end
  end
  table.sort(out, function(a, b) return (a.updatedAt or "") > (b.updatedAt or "") end)
  return out
end

return M

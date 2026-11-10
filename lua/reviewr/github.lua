-- reviewr.github: the one place that talks to the gh CLI
local M = {}

local PR_FIELDS = "number,title,headRefName,baseRefName,author,updatedAt,isDraft,url"
local VIEW_FIELDS = "number,title,baseRefName,headRefName,headRepository,headRepositoryOwner,url"
local DETAIL_FIELDS = "number,title,state,isDraft,author,headRefName,baseRefName,reviewDecision,mergeable,"
  .. "additions,deletions,changedFiles,statusCheckRollup,body,url,updatedAt"
local PR_FRAGMENT = "fragment pr on PullRequest { number title url isDraft updatedAt reviewDecision "
  .. "author { login } repository { nameWithOwner } "
  .. "commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } }"
local function search_field(alias, who)
  return string.format('%s: search(query: "is:pr is:open %s archived:false sort:updated-desc", type: ISSUE, first: 50) '
    .. "{ nodes { ...pr } }", alias, who)
end
local SEARCH_QUERY = PR_FRAGMENT .. " query { " .. search_field("mine", "author:@me") .. " "
  .. search_field("review", "review-requested:@me") .. " }"

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

-- Open PRs of the repository at cwd: cb(list) or cb(nil, err).
function M.list_prs(cwd, cb)
  M.run_async({ "pr", "list", "--state", "open", "--limit", "100", "--json", PR_FIELDS }, { cwd = cwd }, cb)
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

local function present(value) return value ~= nil and value ~= vim.NIL end

-- The rows of a search response, newest update first: `section` is "yours" or
-- "requested" (a PR of mine asked of me too is "yours"), `checks` the state of
-- its last commit's check rollup when it has one.
function M.parse_search(response)
  local seen, out = {}, {}
  for _, alias in ipairs({ { "mine", "yours" }, { "review", "requested" } }) do
    for _, pr in ipairs(response.data[alias[1]].nodes) do
      if pr.url and not seen[pr.url] then
        seen[pr.url] = true
        local commit = present(pr.commits) and pr.commits.nodes[1] and pr.commits.nodes[1].commit
        local rollup = commit and present(commit.statusCheckRollup) and commit.statusCheckRollup
        table.insert(out, {
          number = pr.number, title = pr.title, url = pr.url, isDraft = pr.isDraft, updatedAt = pr.updatedAt,
          reviewDecision = present(pr.reviewDecision) and pr.reviewDecision or nil,
          author = present(pr.author) and pr.author or nil,
          repository = pr.repository, section = alias[2], checks = rollup and rollup.state or nil,
        })
      end
    end
  end
  table.sort(out, function(a, b) return (a.updatedAt or "") > (b.updatedAt or "") end)
  return out
end

-- Open PRs authored by me or waiting on my review, from one GraphQL query:
-- cb(rows) or cb(nil, err).
function M.search_prs(cb)
  M.run_async({ "api", "graphql", "-f", "query=" .. SEARCH_QUERY }, {}, function(response, err)
    if not response then return cb(nil, err) end
    if not (response.data and present(response.data.mine) and present(response.data.review)) then
      local first = response.errors and response.errors[1]
      return cb(nil, first and first.message or "GitHub returned no search results")
    end
    cb(M.parse_search(response))
  end)
end

return M

local Config = require("sidekick.config")
local Util = require("sidekick.util")

-- Experimental, existing agents only. No server creation or input API fallback.
---@class sidekick.cli.muxer.Herdr: sidekick.cli.Session
---@field endpoint {name:string, socket:string}
---@field binding {terminal:string, pane:string, kind:string, native?:table}
---@field process_identity {group:integer, starttime:string}
---@field agent_name? string
---@field agent_status? string

local M = { priority = 50, external = false, manual_input = true }
M.__index = M

local function present(value)
  return type(value) == "string" and value ~= ""
end

function M.command(args, session)
  return vim.list_extend({ "herdr", "--session", session }, args)
end

local function fail(message)
  M.last_error = "Herdr: " .. message
  if M._warned ~= M.last_error then
    M._warned = M.last_error
    Util.warn(M.last_error)
  end
  return {}
end

function M.json(args, session)
  local cmd = session and M.command(args, session) or vim.list_extend({ "herdr" }, args)
  local ok, result = pcall(function()
    return vim.system(cmd, { text = true, timeout = 1500 }):wait()
  end)
  if not ok or result.code ~= 0 then
    local detail
    if ok then
      detail = (result.stderr or ""):match("[^\r\n]+")
        or (result.stdout or ""):match("[^\r\n]+")
        or (result.code == 124 and "timed out after 1500ms" or ("exit " .. tostring(result.code)))
    else
      detail = tostring(result)
    end
    M._command_error = table.concat(args, " ") .. " failed: " .. detail
    return nil
  end
  local decoded, value = pcall(vim.json.decode, result.stdout or "")
  if not decoded or type(value) ~= "table" then
    M._command_error = table.concat(args, " ") .. " returned invalid JSON"
    return nil
  elseif value.error ~= nil and value.error ~= vim.NIL then
    local detail = type(value.error) == "table" and (value.error.message or value.error.code) or nil
    M._command_error = table.concat(args, " ")
      .. " returned an API error"
      .. (present(detail) and (": " .. detail) or "")
    return nil
  end
  return value
end

function M.endpoint()
  local opts = Config.cli.mux.herdr
  if type(opts) ~= "table" then
    M._command_error = "cli.mux.herdr must be a table with an existing server session name"
    return nil
  end
  local name = opts.session
  if not present(name) or #name > 64 or name == "." or name == ".." or not name:match("^[A-Za-z0-9._-]+$") then
    M._command_error =
      "cli.mux.herdr.session must be 1-64 ASCII letters, digits, dots, underscores or hyphens (not . or ..)"
    return nil
  end
  local list = M.json({ "session", "list", "--json" })
  local records = list and list.sessions
  if type(records) ~= "table" then
    return nil
  end
  for _, session in ipairs(records) do
    if
      type(session) == "table"
      and session.name == name
      and session.running == true
      and present(session.socket_path)
    then
      return { name = name, socket = session.socket_path }
    end
  end
end

-- Refuse unknown status output instead of guessing the answering server.
function M.server_matches(endpoint)
  local status = M.json({ "status", "server", "--json" }, endpoint.name)
  local sockets = {}
  local function walk(value)
    for key, child in pairs(value) do
      if (key == "socket_path" or key == "socket") and present(child) then
        sockets[child] = true
      elseif type(child) == "table" then
        walk(child)
      end
    end
  end
  if status then
    walk(status)
  end
  local matches = status and status.running == true and sockets[endpoint.socket] == true and vim.tbl_count(sockets) == 1
  if not matches and not M._command_error then
    M._command_error = "server is not running or its socket identity did not match"
  end
  return matches
end

function M.snapshot(endpoint)
  if not M.server_matches(endpoint) then
    return nil
  end
  local reply = M.json({ "api", "snapshot" }, endpoint.name)
  local snapshot = reply and type(reply.result) == "table" and reply.result.snapshot
  if type(snapshot) ~= "table" or type(snapshot.agents) ~= "table" or not vim.islist(snapshot.agents) then
    M._command_error = M._command_error or "server returned an invalid snapshot"
    return nil
  end
  if not present(snapshot.version) then
    M._command_error = "server snapshot is missing its version"
    return nil
  end
  local ok, result = pcall(function()
    return vim.system({ "herdr", "--version" }, { text = true, timeout = 1500 }):wait()
  end)
  -- Direct attach uses the binary protocol, unlike JSON API discovery.
  local client_version = ok and result.code == 0 and (result.stdout or ""):match("herdr%s+(%S+)") or nil
  if not present(client_version) then
    M._command_error = "herdr --version failed or returned no recognizable version"
    return nil
  elseif client_version ~= snapshot.version then
    M._command_error = "client version " .. client_version .. " differs from server version " .. snapshot.version
    return nil
  end
  return snapshot
end

function M.binding(agent)
  return {
    terminal = agent.terminal_id,
    pane = agent.pane_id,
    kind = agent.agent,
    native = agent.agent_session ~= vim.NIL and agent.agent_session or nil,
  }
end

-- This PoC is local Linux only. Names and terminal IDs can outlive an occupant.
-- Refuse unavailable process evidence instead of falling back to those IDs.
function M.process_identity(endpoint, pane)
  local reply = M.json({ "pane", "process-info", "--pane", pane }, endpoint.name)
  local info = reply and type(reply.result) == "table" and reply.result.process_info
  local group = type(info) == "table" and info.foreground_process_group_id
  local shell = type(info) == "table" and info.shell_pid
  if
    type(group) ~= "number"
    or group <= 0
    or group % 1 ~= 0
    or type(shell) ~= "number"
    or shell <= 0
    or shell % 1 ~= 0
  then
    return nil
  end
  local file = io.open("/proc/" .. group .. "/stat", "r")
  if not file then
    return nil
  end
  local stat = file:read("*a")
  file:close()
  local tail = stat and stat:match("^%d+ %(.+%) (.*)$")
  local fields = tail and vim.split(tail, "%s+", { trimempty = true })
  if not fields or not fields[20] or fields[1] == "Z" then
    return nil
  end
  if group == shell then
    return nil, "shell" -- Positive live shell evidence, not an unavailable process query.
  end
  return { group = group, starttime = fields[20] }
end

---@return sidekick.cli.session.State[]
---@return table<string,boolean>? observed_ids Configured agent IDs in a complete snapshot: true includes process-unknown records, false confirms a foreground shell; nil means absence cannot be inferred.
function M.sessions()
  M._command_error = nil
  local endpoint = M.endpoint()
  if not endpoint then
    return fail(M._command_error or "configure cli.mux.herdr.session as an existing running server name")
  end
  local snapshot = M.snapshot(endpoint)
  if not snapshot then
    return fail(M._command_error or "server socket, snapshot or client/server version did not match")
  end
  local ret, tools, unavailable = {}, Config.tools(), false
  local observed, complete = {}, true
  local prefix = "herdr:" .. vim.fn.sha256(endpoint.socket) .. ":"
  for _, agent in ipairs(snapshot.agents) do
    if
      type(agent) ~= "table"
      or not present(agent.terminal_id)
      or not present(agent.pane_id)
      or (agent.agent ~= nil and agent.agent ~= vim.NIL and type(agent.agent) ~= "string")
    then
      complete, unavailable = false, true
      M._command_error = "snapshot contains an agent record without a usable identity"
    elseif tools[agent.agent] then
      -- Presence is independent of process validation: an unknown process must
      -- not be mistaken for a confirmed missing agent.
      observed[prefix .. agent.terminal_id] = true
      local cwd = present(agent.foreground_cwd) and agent.foreground_cwd or agent.cwd
      local process, foreground = M.process_identity(endpoint, agent.pane_id)
      if present(cwd) and process then
        ret[#ret + 1] = {
          id = prefix .. agent.terminal_id,
          tool = tools[agent.agent],
          cwd = cwd,
          endpoint = endpoint,
          binding = M.binding(agent),
          process_identity = process,
          agent_name = present(agent.name) and agent.name or nil,
          agent_status = present(agent.agent_status) and agent.agent_status or nil,
          mux_session = endpoint.name,
        }
      elseif foreground == "shell" then
        observed[prefix .. agent.terminal_id] = false
      else
        unavailable = true
      end
    end
  end
  if unavailable then
    fail(
      M._command_error
        or "some matching agents lack a cwd or a live non-shell foreground process in this Linux namespace"
    )
    return ret, complete and observed or nil
  end
  M.last_error, M._warned = nil, nil
  return ret, complete and observed or nil
end

function M:same_owner(other)
  return type(self.process_identity) == "table"
    and vim.deep_equal(self.endpoint, other.endpoint)
    and vim.deep_equal(self.binding, other.binding)
    and vim.deep_equal(self.process_identity, other.process_identity)
end

function M:validate()
  M._command_error = nil
  if type(self.binding) ~= "table" or type(self.endpoint) ~= "table" or type(self.process_identity) ~= "table" then
    return false, "attachment has no complete ownership identity"
  end
  local endpoint = M.endpoint()
  if not endpoint then
    return false, M._command_error or "configured server is unavailable"
  elseif not vim.deep_equal(endpoint, self.endpoint) then
    return false, "configured server endpoint changed"
  elseif not M.server_matches(endpoint) then
    return false, M._command_error
  end
  local reply = M.json({ "agent", "get", self.binding.pane }, endpoint.name)
  local agent = reply and type(reply.result) == "table" and reply.result.agent
  if type(agent) ~= "table" then
    return false, M._command_error or "agent is no longer available"
  elseif not vim.deep_equal(M.binding(agent), self.binding) then
    return false, "agent binding changed"
  end
  if not vim.deep_equal(M.process_identity(endpoint, self.binding.pane), self.process_identity) then
    return false, M._command_error or "foreground process identity changed or became unavailable"
  end
  return true
end

function M:attach()
  local valid, reason = self:validate()
  assert(valid, "Herdr target unavailable: " .. tostring(reason) .. "; select the agent again")
  local client = vim.fn.exepath("herdr")
  assert(client ~= "", "Herdr client is unavailable")
  return {
    cmd = { client, "terminal", "attach", self.binding.terminal },
    env = { HERDR_SOCKET_PATH = self.endpoint.socket, HERDR_SESSION = false },
  }
end

function M:is_running()
  return self:validate()
end

function M:start()
  error(
    "Herdr PoC only attaches existing agents; select a running session"
      .. (M.last_error and (": " .. M.last_error) or "")
  )
end

function M:send()
  error("Herdr PoC requires manual terminal input; automatic paste and submit are disabled")
end

M.submit = M.send

return M

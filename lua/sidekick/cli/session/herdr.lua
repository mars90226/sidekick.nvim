local Config = require("sidekick.config")

-- Experimental, existing agents only. No server creation or input API fallback.
local M = { priority = 50, external = false, manual_input = true }
M.__index = M

local function present(value)
  return type(value) == "string" and value ~= ""
end

function M.command(args, session)
  return vim.list_extend({ "herdr", "--session", session }, args)
end

function M.json(args, session)
  local cmd = session and M.command(args, session) or vim.list_extend({ "herdr" }, args)
  local ok, result = pcall(function()
    return vim.system(cmd, { text = true, timeout = 1500 }):wait()
  end)
  if not ok or result.code ~= 0 then
    return nil
  end
  local decoded, value = pcall(vim.json.decode, result.stdout or "")
  return decoded and type(value) == "table" and not value.error and value or nil
end

function M.endpoint()
  local name = Config.cli.mux.herdr.session
  if not present(name) or not name:match("^[%w_-]+$") then
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
  return sockets[endpoint.socket] == true and vim.tbl_count(sockets) == 1
end

function M.snapshot(endpoint)
  if not M.server_matches(endpoint) then
    return nil
  end
  local reply = M.json({ "api", "snapshot" }, endpoint.name)
  local snapshot = reply and type(reply.result) == "table" and reply.result.snapshot
  if type(snapshot) ~= "table" or type(snapshot.agents) ~= "table" then
    return nil
  end
  local ok, result = pcall(function()
    return vim.system({ "herdr", "--version" }, { text = true, timeout = 1500 }):wait()
  end)
  -- Direct attach uses the binary protocol, unlike JSON API discovery.
  if not ok or result.code ~= 0 or (result.stdout or ""):match("herdr%s+(%S+)") ~= snapshot.version then
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
  if type(group) ~= "number" or group <= 0 or group % 1 ~= 0 or group == info.shell_pid then
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
  return { group = group, starttime = fields[20] }
end

function M.sessions()
  local endpoint = M.endpoint()
  local snapshot = endpoint and M.snapshot(endpoint)
  local ret, tools = {}, Config.tools()
  for _, agent in ipairs(snapshot and snapshot.agents or {}) do
    if type(agent) == "table" and tools[agent.agent] and present(agent.terminal_id) and present(agent.pane_id) then
      local cwd = present(agent.foreground_cwd) and agent.foreground_cwd or agent.cwd
      local process = M.process_identity(endpoint, agent.pane_id)
      if present(cwd) and process then
        ret[#ret + 1] = {
          id = "herdr:" .. vim.fn.sha256(endpoint.socket) .. ":" .. agent.terminal_id,
          tool = tools[agent.agent],
          cwd = cwd,
          endpoint = endpoint,
          binding = M.binding(agent),
          process_identity = process,
          agent_name = present(agent.name) and agent.name or nil,
          agent_status = agent.agent_status,
          mux_session = endpoint.name,
        }
      end
    end
  end
  return ret
end

function M:validate()
  local endpoint = M.endpoint()
  if not endpoint or not vim.deep_equal(endpoint, self.endpoint) or not M.server_matches(endpoint) then
    return false
  end
  local reply = M.json({ "agent", "get", self.binding.pane }, endpoint.name)
  local agent = reply and type(reply.result) == "table" and reply.result.agent
  return type(agent) == "table"
    and vim.deep_equal(M.binding(agent), self.binding)
    and type(self.process_identity) == "table"
    and vim.deep_equal(M.process_identity(endpoint, self.binding.pane), self.process_identity)
end

function M:attach()
  assert(self:validate(), "Herdr target changed or server unavailable; select the agent again")
  return { cmd = M.command({ "agent", "attach", self.binding.pane }, self.endpoint.name) }
end

function M:is_running()
  return self:validate()
end

function M:start()
  error("Herdr PoC only attaches existing agents; select a running session")
end

function M:send()
  error("Herdr PoC requires manual terminal input; automatic paste and submit are disabled")
end

M.submit = M.send

return M

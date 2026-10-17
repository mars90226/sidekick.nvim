local Config = require("sidekick.config")
local Herdr = require("sidekick.cli.session.herdr")
local Session = require("sidekick.cli.session")
local Util = require("sidekick.util")

-- Explicit creation only. Discovery, send and terminal restart never enter here.
local M = { operations = {}, pending = {}, generation = 0 }
local sequence = 0
local shells = { bash = true, zsh = true, sh = true, dash = true }

local function text(value)
  return type(value) == "string" and value ~= "" and not value:find("[%z\1-\31\127]")
end

local function reported_cwd(value)
  return type(value.foreground_cwd) == "string" and value.foreground_cwd ~= "" and value.foreground_cwd or value.cwd
end

local function same_cwd(a, b)
  return type(a) == "string" and vim.uv.fs_realpath(a) == b
end

local function redact(op, value)
  value = value or ""
  for _, secret in ipairs(op.secrets) do
    value = value:gsub(vim.pesc(secret), "[redacted]")
    local encoded = vim.json.encode(secret):sub(2, -2)
    value = value:gsub(vim.pesc(encoded), "[redacted]")
  end
  return value
end

-- Preserve operational metadata while sanitizing configured values elsewhere.
local identity_fields = {
  pane_id = true,
  terminal_id = true,
  workspace_id = true,
  tab_id = true,
  name = true,
  agent = true,
  cwd = true,
  foreground_cwd = true,
  socket = true,
  socket_path = true,
  agent_status = true,
  status = true,
  version = true,
  type = true,
}
local function redact_reply(op, value, json)
  if not json then
    return redact(op, value)
  end
  local ok, decoded = pcall(vim.json.decode, value or "")
  if not ok or type(decoded) ~= "table" then
    return redact(op, value)
  end
  local function sanitize(node)
    for key, child in pairs(node) do
      if type(child) == "table" then
        sanitize(child)
      elseif type(child) == "string" and not identity_fields[key] then
        node[key] = redact(op, child)
      end
    end
  end
  sanitize(decoded)
  return vim.json.encode(decoded)
end

local function complete(op)
  if M.pending[op.key] == op and (op.phase == "attached" or op.phase == "ready" or not op.workspace_dispatched) then
    M.pending[op.key] = nil
  end
  if not op.notified and op.on_done then
    op.notified = true
    op.on_done(op)
  end
end

-- A received creation reply remains useful ownership evidence if disk writes fail.
local function capture_workspace(op, value)
  local root = value and value.result and value.result.root_pane
  if
    type(root) ~= "table"
    or not text(root.workspace_id)
    or not text(root.tab_id)
    or not text(root.pane_id)
    or not text(root.terminal_id)
  then
    return false
  end
  op.workspace, op.tab, op.pane, op.terminal = root.workspace_id, root.tab_id, root.pane_id, root.terminal_id
  return true
end

local function save(op, preserve_outcome)
  op.persist_error = nil
  local data = {}
  for _, key in ipairs({
    "id",
    "name",
    "tool",
    "backend",
    "cwd",
    "phase",
    "error",
    "persist_error",
    "endpoint",
    "workspace",
    "pane",
    "terminal",
    "tab",
    "workspace_dispatched",
    "start_dispatched",
    "start_error",
    "cancelled",
    "records",
  }) do
    data[key] = op[key]
  end
  local ok, err = pcall(function()
    local encoded = vim.json.encode(data) .. "\n"
    local dir = vim.fs.dirname(op.journal)
    vim.fn.mkdir(dir, "p", 448)
    local fd = assert(vim.uv.fs_open(op.journal .. ".tmp", "w", 384))
    local wrote, written, why = pcall(vim.uv.fs_write, fd, encoded, 0)
    local closed, close_error = vim.uv.fs_close(fd)
    assert(wrote, written)
    assert(written == #encoded, why or "Short creation journal write")
    assert(closed, close_error)
    assert(vim.uv.fs_rename(op.journal .. ".tmp", op.journal))
  end)
  if not ok then
    op.persist_error = "Cannot save creation journal: " .. tostring(err)
    if not preserve_outcome and op.phase ~= "cancelled" then
      op.phase, op.error =
        (op.workspace_dispatched or op.start_dispatched) and "unknown" or "failed", op.error or op.persist_error
    end
    Util.error(op.persist_error .. "; inspect operation " .. op.id)
  end
  return ok
end

local function finish(op, phase, reason)
  if op.start_error and (phase == "unknown" or phase == "blocked") then
    reason = (reason or "Agent startup is uncertain") .. "; agent start: " .. op.start_error
  end
  op.phase, op.error = phase, reason and redact(op, reason) or nil
  save(op, true)
  if reason then
    Util.warn(
      "New "
        .. op.tool
        .. ": "
        .. op.error
        .. (op.pane and ("; pane " .. op.pane) or "")
        .. (op.persist_error and ("; " .. op.persist_error) or "")
        .. "; operation "
        .. op.id
        .. ", journal "
        .. op.journal
    )
  end
  complete(op)
end

-- A failed journal cannot be retried safely after a remote mutation. Keep the
-- live ownership evidence visible even when it could not be written to disk.
local function stop_persistence(op)
  Util.warn(
    "New "
      .. op.tool
      .. ": "
      .. op.phase
      .. "; journal unavailable; resources, if any, are preserved; not retried"
      .. (op.workspace and ("; workspace " .. op.workspace) or "")
      .. (op.pane and ("; pane " .. op.pane) or "")
      .. "; operation "
      .. op.id
      .. ", journal "
      .. op.journal
  )
  complete(op)
end

local function call(op, args, timeout, json, cb)
  -- Pin every operation to the captured endpoint; tool env is only for the new workspace.
  local env = vim.uv.os_environ()
  env.HERDR_SESSION, env.HERDR_SOCKET_PATH = nil, op.endpoint.socket
  local ok, err = pcall(
    vim.system,
    Herdr.command(args, op.endpoint.name),
    {
      text = true,
      clear_env = true,
      env = env,
      timeout = timeout,
    },
    vim.schedule_wrap(function(result)
      if M.operations[op.id] ~= op then
        return
      end
      -- Preserve the response before parsing, including nonzero and malformed replies.
      op.records[#op.records + 1] = {
        command = args[1] .. " " .. (args[2] or ""),
        code = result.code,
        stdout = redact_reply(op, result.stdout, json),
        stderr = redact(op, result.stderr),
      }
      local persisted = save(op)
      local value
      if json then
        local decoded
        decoded, value = pcall(vim.json.decode, result.stdout or "")
        if not decoded or type(value) ~= "table" then
          value = nil
        end
      else
        value = result.stdout or ""
      end
      local failure = result.code ~= 0 or not value or (json and value.error ~= nil and value.error ~= vim.NIL)
      if json and value and args[1] ~= "status" and type(value.result) ~= "table" then
        failure = true -- null/primitive success envelopes are not usable replies.
      end
      if not persisted then
        if not failure and args[1] == "workspace" and args[2] == "create" then
          capture_workspace(op, value)
        end
        stop_persistence(op) -- No further mutation/attachment when the journal is unavailable.
        return
      end
      if failure then
        local api_error = json and value and type(value.error) == "table" and value.error or nil
        local detail
        if result.code == 124 then
          detail = "CLI timed out"
        elseif result.signal and result.signal ~= 0 then
          detail = "CLI interrupted by signal " .. tostring(result.signal)
        elseif api_error then
          detail = type(api_error.message) == "string" and api_error.message
            or ("herdr API error: " .. tostring(api_error.code or "unknown"))
        else
          detail = result.stderr and result.stderr:match("[^\r\n]+")
        end
        cb(nil, detail or "CLI failed or returned an invalid reply", result)
      else
        cb(value, nil, result)
      end
    end)
  )
  if not ok then
    cb(nil, tostring(err), { code = -1 })
  end
end

local function server(op, cb, observe)
  call(op, { "status", "server", "--json" }, 2000, true, function(value, err)
    if op.cancelled and op.phase == "cancelled" and not observe then
      return -- The late reply is recorded, but cannot overwrite a settled cancellation.
    end
    if
      not value
      or value.running ~= true
      or value.socket ~= op.endpoint.socket
      or value.protocol ~= 22
      or value.version ~= op.version
    then
      finish(op, op.workspace_dispatched and "unknown" or "failed", err or "Server identity/version changed")
    elseif op.cancelled and not observe then
      finish(op, "cancelled", "Observation cancelled; created resources are preserved")
    else
      cb()
    end
  end)
end

local function pane_matches(op, pane)
  return type(pane) == "table"
    and pane.pane_id == op.pane
    and pane.terminal_id == op.terminal
    and pane.workspace_id == op.workspace
    and pane.tab_id == op.tab
    and same_cwd(reported_cwd(pane), op.real_cwd)
end

local function shell_matches(op, info)
  if
    type(info) ~= "table"
    or info.pane_id ~= op.pane
    or type(info.shell_pid) ~= "number"
    or info.shell_pid <= 0
    or info.shell_pid % 1 ~= 0
    or info.foreground_process_group_id ~= info.shell_pid
    or type(info.foreground_processes) ~= "table"
    or #info.foreground_processes ~= 1
  then
    return false
  end
  local proc = info.foreground_processes[1]
  return type(proc) == "table"
    and proc.pid == info.shell_pid
    and shells[proc.name] == true
    and same_cwd(proc.cwd, op.real_cwd)
end

local function empty_prompt(visible)
  local line = (visible or ""):match("([^\r\n]+)[\r\n%s]*$") or ""
  -- One prompt marker, no trailing input. A second marker can be shell draft
  -- syntax (comments/redirection); `>` may be a continuation prompt, so reject it.
  local prefix = line:match("^(.-)[$#%%] ?$") or line:match("^(.-)❯ ?$")
  return prefix ~= nil and not prefix:find("[$#%%>]") and not prefix:find("❯", 1, true)
end

local function check_shell(op, cb)
  call(op, { "pane", "get", op.pane }, 2000, true, function(value, err)
    if not value or not pane_matches(op, value.result and value.result.pane) then
      return finish(op, "unknown", err or "Created pane identity/cwd changed")
    end
    local shell_attempts = 0
    local function read_process()
      shell_attempts = shell_attempts + 1
      call(op, { "pane", "process-info", "--pane", op.pane }, 2000, true, function(process, why)
        if op.cancelled then
          return finish(op, "cancelled", "Created shell is preserved; no agent started")
        end
        local info = process and process.result and process.result.process_info
        -- Shell startup/prompt rendering may briefly have child commands in the
        -- shell's foreground group. Wait without input until only its shell remains.
        if
          type(info) == "table"
          and info.foreground_process_group_id == info.shell_pid
          and type(info.foreground_processes) == "table"
          and #info.foreground_processes > 1
          and shell_attempts < 20
          and not op.cancelled
        then
          local shell_present, same_directory = false, true
          for _, proc in ipairs(info.foreground_processes) do
            if type(proc) ~= "table" then
              same_directory = false
              break
            end
            same_directory = same_directory and same_cwd(proc.cwd, op.real_cwd)
            shell_present = shell_present or (proc.pid == info.shell_pid and shells[proc.name] == true)
          end
          if shell_present and same_directory then
            return vim.defer_fn(read_process, 100)
          end
        end
        if
          shell_attempts >= 20
          and type(info) == "table"
          and type(info.foreground_processes) == "table"
          and #info.foreground_processes > 1
        then
          return finish(op, "unknown", "Timed out waiting for shell startup to settle; no agent started")
        end
        if not process or not shell_matches(op, info) then
          return finish(op, "unknown", why or "Created pane is not at its expected plain shell")
        end
        local attempts = 0
        local function read_prompt()
          attempts = attempts + 1
          call(op, { "pane", "read", op.pane, "--source", "visible" }, 2000, false, function(visible, failure)
            if op.cancelled then
              return finish(op, "cancelled", "Created shell is preserved; no agent started")
            end
            -- Workspace creation may return before shell startup has drawn any output.
            -- Only an empty screen gets bounded passive waiting; drafts are never cleared.
            if visible and visible:match("^%s*$") and attempts < 20 then
              return vim.defer_fn(read_prompt, 100)
            end
            if visible and visible:match("^%s*$") and attempts >= 20 then
              return finish(op, "unknown", "Timed out waiting for shell prompt; no agent started")
            end
            if not visible or not empty_prompt(visible) then
              return finish(op, "unknown", failure or "Shell prompt is unrecognized or has input; no agent started")
            end
            cb()
          end)
        end
        read_prompt()
      end)
    end
    read_process()
  end)
end

local function verify(op, attach)
  op.phase = "verifying"
  call(op, { "agent", "get", op.name }, 2000, true, function(value, err)
    local agent = value and value.result and value.result.agent
    if
      type(agent) ~= "table"
      or agent.name ~= op.name
      or agent.agent ~= op.tool
      or not pane_matches(op, agent)
      or (op.binding and not vim.deep_equal(op.binding, Herdr.binding(agent)))
    then
      return finish(op, "unknown", err or "Agent identity is not confirmed; no start was retried")
    end
    if agent.agent_status == "blocked" then
      return finish(op, "blocked", "Startup needs manual attention in " .. op.pane .. "; no input was sent")
    elseif
      agent.interactive_ready ~= true
      or (agent.agent_status ~= "idle" and agent.agent_status ~= "done")
      or agent.launch_pending == true
    then
      return finish(op, "unknown", "Agent is not confirmed ready; inspect " .. op.pane .. " and refresh")
    end
    Herdr._command_error = nil
    local process, foreground = Herdr.process_identity(op.endpoint, op.pane)
    local reason = not process
        and (foreground or Herdr._command_error or "Process identity/query evidence is unavailable")
      or nil
    op.records[#op.records + 1] = {
      command = "pane process-info",
      kind = "identity",
      process_identity = process,
      reason = reason and redact(op, reason) or nil,
    }
    if not save(op) then
      return stop_persistence(op)
    end
    if not process then
      return finish(op, "unknown", foreground == "shell" and "Agent exited; pane is back at its shell" or reason)
    end
    local source = Session.new({
      id = "herdr:" .. vim.fn.sha256(op.endpoint.socket) .. ":" .. op.terminal,
      backend = "herdr",
      started = true,
      tool = op.tool,
      cwd = reported_cwd(agent),
      endpoint = op.endpoint,
      binding = Herdr.binding(agent),
      process_identity = process,
      agent_name = op.name,
      agent_status = agent.agent_status,
      mux_session = op.endpoint.name,
    })
    if not attach or op.cancelled or op.generation ~= M.generation then
      return finish(op, "ready", "Agent is ready; select the existing session explicitly")
    end
    for _, existing in pairs(Session._attached) do
      if existing.source_id == source.id then
        return finish(op, "ready", "Agent already has a registered attachment; select it explicitly")
      end
    end
    local ok, result = pcall(function()
      local terminal = Session.attach(source)
      terminal:show()
      if op.focus ~= false then
        terminal:focus()
      end
      return terminal
    end)
    if not ok then
      return finish(op, "ready", "Agent was created but attachment failed: " .. tostring(result))
    end
    op.session = result
    finish(op, "attached")
  end)
end

local function start_agent(op)
  check_shell(op, function()
    server(op, function()
      assert(not op.start_dispatched, "Agent start already dispatched")
      op.phase, op.start_dispatched = "launching", true
      if not save(op) then
        op.start_dispatched = false -- The start command has not been invoked.
        return stop_persistence(op)
      end
      local args =
        { "agent", "start", op.name, "--kind", op.tool, "--pane", op.pane, "--timeout", tostring(op.timeout), "--" }
      vim.list_extend(args, op.args)
      call(op, args, op.timeout + 15000, true, function(value, err)
        op.start_error = err and redact(op, err) or nil
        local agent = value and value.result and value.result.agent
        if type(agent) == "table" then
          if agent.name ~= op.name or agent.agent ~= op.tool or not pane_matches(op, agent) then
            return finish(op, "unknown", "Start response did not identify the created agent")
          end
          op.binding = Herdr.binding(agent)
        end
        -- Even a timeout/agent_not_ready may have launched the agent. Only read it now.
        verify(op, true)
      end)
    end)
  end)
end

local function probe(op)
  check_shell(op, function()
    server(op, function()
      op.phase = "checking_executable"
      local marker = "SK_EXEC_" .. op.id .. "="
      local command = "printf '\\n" .. marker .. "'; command -v " .. op.tool
      call(op, { "pane", "run", op.pane, command }, 2000, false, function(value, err)
        if not value then
          return finish(op, "unknown", err)
        end
        local attempts = 0
        local function read()
          attempts = attempts + 1
          call(op, { "pane", "read", op.pane, "--source", "visible" }, 2000, false, function(visible, why)
            local path = visible and visible:match("[\r\n]" .. marker .. "([^\r\n]+)")
            if path then
              if path ~= op.executable then
                return finish(op, "unknown", "Pane canonical executable differs from the expected local executable")
              end
              start_agent(op)
            elseif attempts >= 10 or not visible then
              finish(op, "unknown", why or "Canonical executable probe could not be verified")
            elseif op.cancelled then
              finish(op, "cancelled", "Created shell is preserved")
            else
              vim.defer_fn(read, 100)
            end
          end)
        end
        read()
      end)
    end)
  end)
end

local function begin(op)
  if op.cancelled then
    return
  end
  op.phase = "checking_server"
  Herdr._command_error = nil
  local endpoint = Herdr.endpoint()
  local snapshot = endpoint and Herdr.snapshot(endpoint)
  if not snapshot then
    return finish(op, "failed", Herdr._command_error or "Existing herdr server is unavailable")
  end
  op.endpoint, op.version = endpoint, snapshot.version
  server(op, function()
    op.phase, op.workspace_dispatched = "creating_workspace", true
    if not save(op) then
      op.workspace_dispatched = false -- No command was invoked; release this reservation.
      op.phase = "failed"
      return complete(op)
    end
    local args =
      { "workspace", "create", "--cwd", op.cwd, "--label", "sidekick:" .. op.tool .. ":" .. op.id, "--no-focus" }
    for _, key in ipairs(vim.tbl_keys(op.env)) do
      vim.list_extend(args, { "--env", key .. "=" .. op.env[key] })
    end
    call(op, args, 10000, true, function(value, err)
      if not capture_workspace(op, value) then
        return finish(
          op,
          "unknown",
          (err or "Workspace response is incomplete") .. "; workspace may exist; do not retry creation"
        )
      end
      op.phase = "workspace_created"
      if not save(op) then
        return stop_persistence(op)
      end
      if op.cancelled then
        return finish(op, "cancelled", "Created workspace is preserved; no agent started")
      end
      probe(op)
    end)
  end)
end

local function plan(opts)
  Session.setup()
  local tool = assert(Config.tools()[opts.name], "Unknown CLI tool")
  local backend, cwd = Session.primary(), Session.cwd({ cwd = opts.cwd })
  assert(vim.fn.isdirectory(cwd) == 1 and text(cwd), "New agent cwd must be an existing local directory")
  local env, args, secrets = {}, {}, {}
  local timeout = 30000
  if backend == "herdr" then
    assert(vim.uv.os_uname().sysname == "Linux", "Herdr creation requires local Linux")
    local config = Config.cli.mux.herdr.create
    assert(
      type(config) == "table" and config.enabled == true,
      "Herdr creation is disabled; enable cli.mux.herdr.create.enabled"
    )
    assert(config.workspace == "new", "Herdr creation only supports dedicated new workspaces")
    timeout = config.startup_timeout_ms
    assert(
      type(timeout) == "number" and timeout % 1 == 0 and timeout > 3000 and timeout <= 300000,
      "Invalid herdr startup timeout"
    )
    assert(
      (opts.name == "claude" or opts.name == "codex") and vim.islist(tool.cmd) and tool.cmd[1] == opts.name,
      "Herdr New requires canonical claude/codex commands"
    )
    local i = 2
    while i <= #tool.cmd do
      local flag, value = tool.cmd[i], tool.cmd[i + 1]
      assert(
        (flag == "--model" or (opts.name == "claude" and flag == "--effort")) and text(value) and value:sub(1, 1) ~= "-",
        "Unsupported interactive launch arguments"
      )
      args[#args + 1], args[#args + 2] = flag, value
      secrets[#secrets + 1] = value
      i = i + 2
    end
    for key, value in pairs(tool.env or {}) do
      assert(
        type(key) == "string" and key:match("^[A-Za-z_][A-Za-z0-9_]*$") and not key:match("^HERDR_"),
        "Unsupported environment key"
      )
      assert(
        type(value) == "string" and not value:find("%z"),
        "Herdr workspace environment values must be strings; unsets are unsupported"
      )
      env[key] = value
      if value ~= "" then
        secrets[#secrets + 1] = value
      end
    end
  end
  local key = backend .. "\0" .. opts.name .. "\0" .. cwd
  if M.pending[key] then
    local previous = M.pending[key]
    Util.warn(
      "Creation already exists for this tool/cwd; operation "
        .. previous.id
        .. " is "
        .. previous.phase
        .. (
          previous.start_dispatched and "; inspect/refresh its startup"
          or "; no agent start dispatched, inspect its journal"
        )
    )
    return previous, true
  end
  local executable = backend == "herdr" and vim.fn.exepath(opts.name) or nil
  assert(backend ~= "herdr" or text(executable), "Canonical agent executable is unavailable locally")
  table.sort(secrets, function(a, b)
    return #a > #b
  end)
  sequence = sequence + 1
  M.generation = M.generation + 1
  local id = vim.fn.sha256(tostring(vim.uv.hrtime()) .. ":" .. vim.fn.getpid() .. ":" .. sequence):sub(1, 16)
  local op = {
    id = id,
    name = "sk-" .. opts.name .. "-" .. id,
    key = key,
    tool = opts.name,
    backend = backend,
    cwd = cwd,
    real_cwd = assert(vim.uv.fs_realpath(cwd)),
    env = env,
    args = args,
    secrets = secrets,
    timeout = timeout,
    executable = executable,
    phase = "planned",
    records = {},
    generation = M.generation,
    journal = vim.fn.stdpath("state") .. "/sidekick/herdr-create/" .. id .. ".json",
    focus = opts.focus,
    on_done = opts.on_done,
  }
  M.operations[id], M.pending[key] = op, op
  return op
end

function M.new(opts)
  opts = opts or {}
  if not opts.name then
    local cwd = Session.cwd({ cwd = opts.cwd }) -- Capture before asynchronous tool selection.
    local names = vim.tbl_filter(function(name)
      return Session.primary() ~= "herdr" or name == "claude" or name == "codex"
    end, vim.tbl_keys(Config.tools()))
    table.sort(names)
    vim.ui.select(names, { prompt = "New agent: choose tool" }, function(name)
      if name then
        M.new(vim.tbl_extend("force", opts, { name = name, cwd = cwd }))
      end
    end)
    return
  end
  local op, existing = plan(opts)
  if existing then
    return op
  elseif not save(op) then
    complete(op)
    return op
  end
  op.phase = "confirming"
  vim.ui.select({ op }, {
    prompt = (op.backend == "tmux" or op.backend == "zellij") and "Open mux session (may reuse existing)?"
      or "Create new agent?",
    format_item = function()
      return op.tool .. " via " .. op.backend .. " in " .. op.cwd
    end,
  }, function(selected)
    if op.phase ~= "confirming" then
      return
    end
    if not selected or op.cancelled then
      return finish(op, "cancelled")
    end
    if op.backend == "herdr" then
      begin(op)
    else
      local ok, err = pcall(function()
        local sid = Session.sid({ tool = op.tool, cwd = op.cwd })
        local Terminal = require("sidekick.cli.terminal")
        assert(
          not (
              Session._attached[sid]
              or Session._attached["terminal: " .. sid]
              or Terminal.get(sid)
              or Terminal.get("terminal: " .. sid)
            ),
          "A session is already registered for this tool/cwd; select it explicitly"
        )
        local session = Session.attach(Session.new({ tool = op.tool, cwd = op.cwd, backend = op.backend }))
        if session.show then
          session:show()
        end
        if op.focus ~= false and session.focus then
          session:focus()
        end
        op.session = session
      end)
      finish(op, ok and "attached" or "failed", not ok and tostring(err) or nil)
    end
  end)
  return op
end

-- Cancellation prevents future input/automatic attachment; late replies are still recorded.
function M.cancel(id)
  local op = assert(M.operations[id], "Unknown creation operation")
  op.cancelled = true
  if vim.tbl_contains({ "unknown", "blocked", "ready", "attached", "failed", "cancelled" }, op.phase) then
    save(op, true) -- Preserve an already observed outcome and its diagnostics.
  else
    finish(op, "cancelled", "Created resources, if any, are preserved")
  end
  return op
end

-- Read-only reconciliation of a known operation, never another create/start attempt.
function M.refresh(id)
  local op = assert(M.operations[id], "Unknown creation operation; inspect its saved journal")
  if not op.start_dispatched or not op.pane then
    Util.warn(
      "Operation "
        .. op.id
        .. " is "
        .. op.phase
        .. "; no agent startup to refresh; inspect journal "
        .. op.journal
        .. (op.workspace and ("; workspace " .. op.workspace .. " is preserved") or "")
    )
    return op
  end
  if not vim.tbl_contains({ "unknown", "blocked", "ready", "cancelled" }, op.phase) then
    return op
  end
  op.phase = "checking_server"
  server(op, function()
    verify(op, false)
  end, true)
  return op
end

return M

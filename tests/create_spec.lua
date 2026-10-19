local T = require("mini.test").new_set()
local expect = MiniTest.expect
if vim.uv.os_uname().sysname ~= "Linux" then
  return T -- The local herdr process-identity fixture requires /proc.
end
local Config = require("sidekick.config")
local Create = require("sidekick.cli.create")
local Herdr = require("sidekick.cli.session.herdr")
local Session = require("sidekick.cli.session")
local Terminal = require("sidekick.cli.terminal")
local Util = require("sidekick.util")
local state, original, root, calls, notices, attached, held, violations
local function result(stdout, code, stderr)
  return {
    stdout = type(stdout) == "table" and vim.json.encode(stdout) or stdout,
    code = code or 0,
    stderr = stderr or "",
  }
end
local function count(first, second)
  return #vim.tbl_filter(function(cmd)
    return cmd[1] == "--session" and cmd[3] == first and cmd[4] == second
  end, calls)
end
local function agent()
  return {
    name = state.name,
    agent = state.kind,
    pane_id = "w-mvp:p1",
    terminal_id = "term-mvp",
    workspace_id = "w-mvp",
    tab_id = "w-mvp:t1",
    cwd = root,
    foreground_cwd = state.foreground_null and vim.NIL or nil,
    agent_status = state.status or "idle",
    interactive_ready = state.ready ~= false,
  }
end
local function pane()
  return {
    pane_id = "w-mvp:p1",
    terminal_id = "term-mvp",
    workspace_id = "w-mvp",
    tab_id = "w-mvp:t1",
    cwd = state.cwd or root,
    foreground_cwd = state.foreground_null and vim.NIL or nil,
  }
end
local function checked(fn)
  local ok, value = pcall(fn)
  if not ok then
    violations[#violations + 1] = tostring(value)
    error(value)
  end
  return value
end
local function respond(cmd)
  if cmd[1] == "--version" then
    return result("herdr 0.9.5")
  end
  if cmd[1] == "session" then
    return result({ sessions = { { name = "poc", running = true, socket_path = "/tmp/mvp.sock" } } })
  end
  expect.equality(cmd[1], "--session")
  expect.equality(cmd[2], "poc")
  local a = vim.list_slice(cmd, 3)
  if a[1] == "status" then
    return result({
      running = true,
      socket = state.socket or "/tmp/mvp.sock",
      protocol = state.protocol or 22,
      version = state.server_version or "0.9.5",
    })
  elseif a[1] == "api" then
    return result({ result = { snapshot = { version = "0.9.5", agents = {} } } })
  elseif a[1] == "workspace" and a[2] == "create" then
    state.created = true
    if state.socket_after_create then
      state.socket = state.socket_after_create
    end
    if state.workspace_reply then
      return state.workspace_reply
    end
    if state.workspace_error then
      return result("{bad", 124, "synthetic timeout")
    end
    return result({ result = { root_pane = pane() } })
  elseif a[1] == "pane" and a[2] == "get" then
    return result({ result = { pane = pane() } })
  elseif a[1] == "pane" and a[2] == "process-info" then
    if state.started and state.process_error then
      return result({ error = { message = "synthetic process query failure" } }, 1, "synthetic process query failure")
    end
    local info = {
      pane_id = "w-mvp:p1",
      shell_pid = 1,
      foreground_process_group_id = state.started and not state.return_to_shell and vim.fn.getpid() or 1,
      foreground_processes = { { pid = 1, name = state.shell_name or "bash", cwd = root } },
    }
    if state.null_process_entry then
      info.foreground_processes = { vim.NIL }
    end
    if state.null_process_child then
      info.foreground_processes[2] = vim.NIL
    end
    if state.shell_children and state.shell_children > 0 then
      state.shell_children = state.shell_children - 1
      table.insert(info.foreground_processes, { pid = 2, name = "starship", cwd = root })
    end
    return result({ result = { process_info = info } })
  elseif a[1] == "pane" and a[2] == "read" then
    if state.marker and state.marker_prompt then
      return result("\n" .. state.marker .. "shell$ ")
    end
    if state.blank_reads and state.blank_reads > 0 then
      state.blank_reads = state.blank_reads - 1
      return result("")
    end
    return result(
      (
        state.marker
          and ("shell$ command\n" .. state.marker .. (state.executable or vim.fn.exepath(state.kind or "codex")) .. "\n")
        or ""
      )
        .. (state.draft and (type(state.draft) == "string" and state.draft or "shell$ unfinished draft") or "shell$ ")
    )
  elseif a[1] == "pane" and a[2] == "run" then
    state.marker = assert(a[4]:match("(SK_EXEC_%x+=)"))
    state.kind = assert(a[4]:match("command %-v (%w+)$"))
    return result("command submitted")
  elseif a[1] == "agent" and a[2] == "start" then
    state.started, state.name, state.kind = true, a[3], a[5]
    if state.start_reply then
      return state.start_reply
    end
    if state.start_error then
      return result("", 124, "synthetic start timeout")
    end
    return result({ result = { agent = agent(), diagnostic = state.echo_secrets } })
  elseif a[1] == "agent" and a[2] == "get" then
    if state.agent_missing then
      return result({ error = { code = "not_found" } }, 1, "not found")
    end
    local value = agent()
    if state.replaced then
      value.terminal_id = "replacement"
    end
    return result({ result = { agent = value } })
  end
  error("Forbidden or unexpected command: " .. vim.inspect(cmd))
end
local function wait(op)
  expect.equality(
    vim.wait(3000, function()
      return vim.tbl_contains({ "attached", "ready", "failed", "unknown", "blocked", "cancelled" }, op.phase)
    end),
    true
  )
  return op
end
getmetatable(T).opts.hooks = {
  pre_case = function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    original = {
      primary = Config.cli.primary_backend,
      discovery = Config.cli.discovery,
      mux = vim.deepcopy(Config.cli.mux),
      tools = Config.cli.tools,
      system = vim.system,
      write = vim.uv.fs_write,
      close = vim.uv.fs_close,
      open = vim.uv.fs_open,
      encode = vim.json.encode,
      terminals = Terminal.terminals,
      rename = vim.uv.fs_rename,
      exepath = vim.fn.exepath,
      executable = vim.fn.executable,
      jobstart = vim.fn.jobstart,
      jobwait = vim.fn.jobwait,
      jobpid = vim.fn.jobpid,
      jobstop = vim.fn.jobstop,
      watch = Config.cli.watch,
      exec = Util.exec,
      info = Util.info,
      get_proc = vim.api.nvim_get_proc,
      tmux = vim.env.TMUX,
      select = vim.ui.select,
      attach = Session.attach,
      backends = Session.backends,
      attached = Session._attached,
      setup = Session.did_setup,
      warn = Util.warn,
      error = Util.error,
      ops = Create.operations,
      pending = Create.pending,
      generation = Create.generation,
      last_error = Herdr.last_error,
      warned = Herdr._warned,
      command_error = Herdr._command_error,
      cwd = vim.fn.getcwd(),
    }
    state, calls, notices, attached, held, violations = { kind = "codex" }, {}, {}, {}, {}, {}
    Terminal.terminals = {}
    Create.operations, Create.pending, Create.generation = {}, {}, 0
    Config.cli.primary_backend, Config.cli.discovery = "herdr", { tmux = true, herdr = true }
    Config.cli.mux.herdr =
      { session = "poc", create = { enabled = true, workspace = "new", startup_timeout_ms = 5000 } }
    Config.cli.tools = { codex = { cmd = { "codex" } }, claude = { cmd = { "claude" } } }
    Session.backends, Session.did_setup, Session._attached = { herdr = Herdr }, true, {}
    vim.fn.chdir(root)
    vim.fn.exepath = function(name)
      if name == "codex" or name == "claude" then
        return root .. "/fixture-bin/" .. name
      end
      return original.exepath(name)
    end
    vim.fn.executable = function(name)
      if name == "codex" or name == "claude" then
        return 1
      end
      return original.executable(name)
    end
    Util.warn, Util.error =
      function(s)
        notices[#notices + 1] = s
      end, function(s)
        notices[#notices + 1] = s
      end
    vim.ui.select = function(items, _, cb)
      cb(items[1])
    end
    Session.attach = function(source)
      return checked(function()
        expect.equality(source.started, true)
        expect.equality(source.backend, "herdr")
        expect.equality(source.manual_input, true)
        attached[#attached + 1] = source
        return { show = function() end, focus = function() end }
      end)
    end
    vim.system = function(argv, opts, cb)
      return checked(function()
        local cmd = vim.list_slice(argv, 2)
        expect.equality(argv[1], "herdr")
        calls[#calls + 1] = cmd
        if cb then
          expect.equality(opts.env.HERDR_SOCKET_PATH, "/tmp/mvp.sock")
          expect.equality(opts.env.HERDR_SESSION, nil)
          local reply = respond(cmd)
          if state.hold == cmd[3] .. " " .. (cmd[4] or "") then
            held[#held + 1] = function()
              cb(reply)
            end
          else
            vim.schedule(function()
              cb(reply)
            end)
          end
          return {}
        end
        return {
          wait = function()
            return checked(function()
              return respond(cmd)
            end)
          end,
        }
      end)
    end
  end,
  post_case = function()
    vim.wait(20, function()
      return false
    end)
    vim.system, vim.ui.select, Session.attach = original.system, original.select, original.attach
    vim.uv.fs_rename, vim.uv.fs_write = original.rename, original.write
    vim.uv.fs_close, vim.uv.fs_open, vim.json.encode = original.close, original.open, original.encode
    for _, terminal in pairs(Terminal.terminals) do
      if terminal.group then
        pcall(vim.api.nvim_del_augroup_by_id, terminal.group)
      end
    end
    Terminal.terminals = original.terminals
    vim.fn.exepath, vim.fn.executable = original.exepath, original.executable
    vim.fn.jobstart, vim.fn.jobwait, vim.fn.jobpid, vim.fn.jobstop =
      original.jobstart, original.jobwait, original.jobpid, original.jobstop
    Config.cli.watch = original.watch
    Util.exec, Util.info, vim.api.nvim_get_proc, vim.env.TMUX =
      original.exec, original.info, original.get_proc, original.tmux
    Config.cli.primary_backend, Config.cli.discovery, Config.cli.mux, Config.cli.tools =
      original.primary, original.discovery, original.mux, original.tools
    Session.backends, Session.did_setup, Session._attached = original.backends, original.setup, original.attached
    Util.warn, Util.error = original.warn, original.error
    Create.operations, Create.pending, Create.generation = original.ops, original.pending, original.generation
    Herdr.last_error, Herdr._warned, Herdr._command_error = original.last_error, original.warned, original.command_error
    vim.fn.chdir(original.cwd)
    vim.fn.delete(root, "rf")
    expect.equality(violations, {}) -- Product pcall must not hide a fixture failure.
  end,
}

T["explicit New confirms and preserves cwd argv env and manual policy"] = function()
  Config.cli.tools.codex.cmd = { "codex", "--model", "value ' \" $(literal) `literal`" }
  Config.cli.tools.codex.env = { FIXTURE_SECRET = "private-fixture-value" }
  local done
  local op = wait(require("sidekick.cli").new({
    name = "codex",
    focus = false,
    on_done = function(value)
      done = value
    end,
  }))
  expect.equality(op.phase, "attached")
  expect.equality(done, op)
  expect.equality(op.cwd, root)
  expect.equality(count("workspace", "create"), 1)
  expect.equality(count("agent", "start"), 1)
  expect.equality(#attached, 1)
  local workspace = vim.tbl_filter(function(cmd)
    return cmd[3] == "workspace"
  end, calls)[1]
  expect.equality(workspace[6], root)
  expect.equality(vim.tbl_contains(workspace, "FIXTURE_SECRET=private-fixture-value"), true)
  local start = vim.tbl_filter(function(cmd)
    return cmd[3] == "agent" and cmd[4] == "start"
  end, calls)[1]
  expect.equality(vim.list_slice(start, #start - 2), { "--", "--model", Config.cli.tools.codex.cmd[3] })
  local journal = table.concat(vim.fn.readfile(op.journal), "\n")
  expect.equality(journal:find("private-fixture-value", 1, true), nil)
  expect.equality(vim.uv.fs_stat(op.journal).mode % 512, 384)
end

for _, case in ipairs({
  "workspace-timeout",
  "start-timeout-unresolved",
  "blocked",
  "not-ready",
  "replaced",
  "cwd",
  "draft",
  "tmux",
  "executable",
}) do
  T["no retry or fallback on " .. case] = function()
    if case == "workspace-timeout" then
      state.workspace_error = true
    elseif case == "start-timeout-unresolved" then
      state.start_error, state.agent_missing = true, true
    elseif case == "blocked" then
      state.start_error, state.status = true, "blocked"
    elseif case == "not-ready" then
      state.ready = false
    elseif case == "replaced" then
      state.start_error, state.replaced = true, true
    elseif case == "cwd" then
      state.cwd = "/tmp"
    elseif case == "draft" then
      state.draft = true
    elseif case == "tmux" then
      state.shell_name = "tmux"
    elseif case == "executable" then
      state.executable = "/different/codex"
    end
    local op = wait(Create.new({ name = "codex" }))
    expect.equality(op.phase, case == "blocked" and "blocked" or "unknown")
    expect.equality(count("workspace", "create"), 1)
    local starts = ({ ["start-timeout-unresolved"] = 1, blocked = 1, ["not-ready"] = 1, replaced = 1 })[case] or 0
    expect.equality(count("agent", "start"), starts)
    if case == "cwd" or case == "draft" or case == "tmux" then
      expect.equality(count("pane", "run"), 0)
    end
    expect.equality(#attached, 0)
    local again = Create.new({ name = "codex" })
    expect.equality(again, op)
    expect.equality(count("workspace", "create"), 1)
  end
end

T["timeout reconciles a positively ready same agent without another start"] = function()
  state.start_error = true
  local op = wait(Create.new({ name = "codex" }))
  expect.equality(op.phase, "attached")
  expect.equality(count("agent", "start"), 1)
end

T["blocked refresh is read only and requires explicit selection to attach"] = function()
  state.status, state.start_error = "blocked", true
  local op = wait(Create.new({ name = "codex" }))
  state.status, state.ready = "idle", true
  Create.refresh(op.id)
  wait(op)
  expect.equality(op.phase, "ready")
  expect.equality(count("agent", "start"), 1)
  expect.equality(count("workspace", "create"), 1)
  expect.equality(#attached, 0)
end

T["cancelled confirmation has no commands or resources"] = function()
  vim.ui.select = function(_, _, cb)
    cb(nil)
  end
  local op = Create.new({ name = "codex" })
  expect.equality(op.phase, "cancelled")
  expect.equality(calls, {})
end

T["late workspace response preserves ownership after cancellation without start"] = function()
  state.hold = "workspace create"
  local op = Create.new({ name = "codex" })
  expect.equality(
    vim.wait(2000, function()
      return #held == 1
    end),
    true
  )
  Create.cancel(op.id)
  held[1]()
  vim.wait(100, function()
    return op.workspace ~= nil
  end)
  expect.equality(op.workspace, "w-mvp")
  expect.equality(op.phase, "cancelled")
  expect.equality(count("agent", "start"), 0)
  vim.wait(30, function()
    return false
  end)
  expect.equality(count("pane", "get"), 0)
end

T["double confirmation and duplicate in flight New dispatch only once"] = function()
  state.hold = "workspace create"
  vim.ui.select = function(items, _, cb)
    cb(items[1])
    cb(items[1])
  end
  local op = Create.new({ name = "codex" })
  expect.equality(
    vim.wait(2000, function()
      return #held == 1
    end),
    true
  )
  expect.equality(Create.new({ name = "codex" }), op)
  expect.equality(count("workspace", "create"), 1)
  held[1]()
  wait(op)
  expect.equality(count("agent", "start"), 1)
end

for _, case in ipairs({ "disabled", "prompt", "wrapper", "resume", "unset", "endpoint-env", "bad-timeout" }) do
  T["invalid plan fails before mutations " .. case] = function()
    if case == "disabled" then
      Config.cli.mux.herdr.create.enabled = false
    elseif case == "prompt" then
      Config.cli.tools.codex.cmd = { "codex", "initial prompt" }
    elseif case == "wrapper" then
      Config.cli.tools.codex.cmd = { "bash", "-lc", "codex" }
    elseif case == "resume" then
      Config.cli.tools.codex.cmd = { "codex", "resume" }
    elseif case == "unset" then
      Config.cli.tools.codex.env = { TOKEN = false }
    elseif case == "endpoint-env" then
      Config.cli.tools.codex.env = { HERDR_SOCKET_PATH = "/wrong" }
    elseif case == "bad-timeout" then
      Config.cli.mux.herdr.create.startup_timeout_ms = 1
    end
    expect.error(function()
      Create.new({ name = "codex" })
    end)
    expect.equality(calls, {})
  end
end

T["primary and discovery register independent sources and preserve existing backend"] = function()
  local executable = vim.fn.executable
  vim.fn.executable = function()
    return 1
  end
  local ok, err = pcall(function()
    Config.cli.primary_backend, Config.cli.mux.backend, Config.cli.mux.enabled = "tmux", "tmux", true
    Config.cli.discovery = { herdr = true, tmux = true }
    Session.backends, Session.did_setup = {}, false
    Session.setup()
    expect.equality(Session.primary(), "tmux")
    expect.equality(Session.backends.herdr, Herdr)
    expect.equality(Session.backends.tmux ~= nil, true)
    Config.cli.primary_backend = "herdr"
    expect.equality(
      Session.new({ tool = "codex", backend = "tmux", started = true, id = "tmux-existing", cwd = root }).backend,
      "tmux"
    )
    Config.cli.discovery.herdr = false
    expect.error(Session.primary)
  end)
  vim.fn.executable = executable
  assert(ok, err)
end

T["real tmux start command retains legacy argv cwd and environment unsets"] = function()
  local Tmux = require("sidekick.cli.session.tmux")
  local set_state = Util.set_state
  Util.set_state = function() end
  local ok, err = pcall(function()
    Config.cli.primary_backend, Config.cli.mux.enabled, Config.cli.mux.backend = "tmux", true, "tmux"
    Session.register("tmux", Tmux)
    Config.cli.tools.codex.env = { REMOVE = false, KEEP = "value" }
    local s = Session.new({ tool = "codex", cwd = root, backend = "tmux" })
    s.external = false
    local cmd = s:start().cmd
    expect.equality(vim.list_slice(cmd, 1, 4), { "tmux", "new", "-A", "-s" })
    expect.equality(vim.tbl_contains(cmd, root), true)
    expect.equality(vim.tbl_contains(cmd, "-u"), true)
    expect.equality(vim.tbl_contains(cmd, "REMOVE"), true)
    expect.equality(vim.tbl_contains(cmd, "KEEP=value"), true)
    expect.equality(vim.tbl_contains(cmd, "codex"), true)
    expect.equality(calls, {})
  end)
  Util.set_state = set_state
  assert(ok, err)
end
T["cancel after start preserves created agent without auto attaching"] = function()
  state.hold = "agent start"
  local op = Create.new({ name = "codex" })
  expect.equality(
    vim.wait(2000, function()
      return #held == 1
    end),
    true
  )
  Create.cancel(op.id)
  held[1]()
  expect.equality(
    vim.wait(2000, function()
      return op.phase == "ready"
    end),
    true
  )
  expect.equality(state.started, true)
  expect.equality(#attached, 0)
  expect.equality(count("workspace", "create"), 1)
  expect.equality(count("agent", "start"), 1)
end

T["old generation completion does not steal focus from a newer request"] = function()
  state.hold = "agent start"
  local op = Create.new({ name = "codex" })
  expect.equality(
    vim.wait(2000, function()
      return #held == 1
    end),
    true
  )
  Create.generation = Create.generation + 1
  held[1]()
  expect.equality(
    vim.wait(2000, function()
      return op.phase == "ready"
    end),
    true
  )
  expect.equality(#attached, 0)
end

T["mixed discovery preserves each existing source backend"] = function()
  Session.backends = {}
  for _, backend in ipairs({ "tmux", "herdr" }) do
    local provider = {
      priority = 50,
      is_attached = function()
        return false
      end,
    }
    provider.__index = provider
    function provider.sessions()
      return { { id = backend .. "-source", cwd = root, tool = "codex" } }
    end
    Session.register(backend, provider)
  end
  local sessions = Session.sessions()
  expect.equality(#sessions, 2)
  local sources = {}
  for _, source in ipairs(sessions) do
    sources[source.id] = source.backend
  end
  expect.equality(sources, { ["tmux-source"] = "tmux", ["herdr-source"] = "herdr" })
  local State = require("sidekick.cli.state")
  local rows = State.get({ started = true })
  expect.equality(#rows, 2) -- Same tool and cwd must not collapse distinct providers.
  local routed = {}
  Session.attach = function(source)
    routed[source.id] = source.backend
    return source
  end
  for _, row in ipairs(rows) do
    State.attach(row, { show = false })
  end
  expect.equality(routed, sources)
end

T["real tmux discovery and attach command remain independent of herdr primary"] = function()
  local Tmux = require("sidekick.cli.session.tmux")
  local Procs = require("sidekick.cli.procs")
  local exec, get_state, new_procs = Util.exec, Util.get_state, Procs.new
  local sid = Session.sid({ tool = "codex", cwd = root })
  Util.exec = function(cmd)
    if cmd[2] == "list-panes" then
      return { "$1:%1:12345:" .. sid .. ":" .. root }
    end
    if cmd[2] == "list-clients" then
      return { "$1:54321" }
    end
    error("Unexpected tmux mutation")
  end
  Util.get_state = function()
    return { tool = "codex", cwd = root }
  end
  Procs.new = function()
    return {
      pids = function()
        return { 12345 }
      end,
    }
  end
  local ok, err = pcall(function()
    local states = Tmux.sessions()
    expect.equality(#states, 1)
    expect.equality(states[1].pids, { 12345, 54321 })
    Session.register("tmux", Tmux)
    states[1].backend, states[1].started = "tmux", true
    local existing = Session.new(states[1])
    expect.equality(existing.backend, "tmux")
    expect.equality(existing:attach().cmd, { "tmux", "attach-session", "-t", sid })
    expect.equality(count("workspace", "create"), 0)
  end)
  Util.exec, Util.get_state, Procs.new = exec, get_state, new_procs
  assert(ok, err)
end

T["nonzero JSON success envelope is never accepted as workspace creation"] = function()
  local system = vim.system
  vim.system = function(argv, opts, cb)
    if cb and argv[4] == "workspace" and argv[5] == "create" then
      calls[#calls + 1] = vim.list_slice(argv, 2)
      vim.schedule(function()
        cb(result({ result = { root_pane = pane() } }, 1, "failure despite JSON"))
      end)
      return {}
    end
    return system(argv, opts, cb)
  end
  local op = wait(Create.new({ name = "codex" }))
  expect.equality(op.phase, "unknown")
  expect.equality(op.pane, nil)
  expect.equality(count("agent", "start"), 0)
end

T["new workspace may draw its shell prompt after the first read"] = function()
  state.blank_reads = 2
  local op = wait(Create.new({ name = "codex" }))
  expect.equality(op.phase, "attached")
  expect.equality(count("workspace", "create"), 1)
  expect.equality(count("agent", "start"), 1)
end

T["shell prompt rendering subprocesses settle before any input"] = function()
  state.shell_children = 2
  local op = wait(Create.new({ name = "codex" }))
  expect.equality(op.phase, "attached")
  expect.equality(count("workspace", "create"), 1)
  expect.equality(count("agent", "start"), 1)
end

T["tool selection pins cwd before its asynchronous callback"] = function()
  local select_tool
  vim.ui.select = function(items, _, cb)
    if type(items[1]) == "string" then
      select_tool = cb
    else
      cb(items[1])
    end
  end
  Create.new()
  vim.fn.chdir(vim.fs.dirname(root))
  select_tool("codex")
  local op
  for _, value in pairs(Create.operations) do
    op = value
  end
  wait(op)
  expect.equality(op.cwd, root)
  expect.equality(op.phase, "attached")
end

T["failed initial journal settles without remote commands or a reservation"] = function()
  vim.uv.fs_rename = function()
    return nil, "ENOSPC"
  end
  local completed = 0
  local op = Create.new({
    name = "codex",
    on_done = function(value)
      completed = completed + 1
    end,
  })
  expect.equality(completed, 1)
  expect.equality(op.phase, "failed")
  expect.equality(Create.pending[op.key], nil)
  expect.equality(calls, {})
end

T["journal failure after workspace reply preserves IDs and settles once without start"] = function()
  vim.uv.fs_rename = function(...)
    if state.created then
      return nil, "ENOSPC"
    end
    return original.rename(...)
  end
  local completed = 0
  local op = wait(Create.new({
    name = "codex",
    on_done = function(value)
      completed = completed + 1
    end,
  }))
  expect.equality(completed, 1)
  expect.equality(op.phase, "unknown")
  expect.equality(op.pane, "w-mvp:p1")
  expect.equality(op.workspace, "w-mvp")
  expect.equality(op.terminal, "term-mvp")
  expect.equality(#op.records, 2)
  local notice = table.concat(notices, "\n")
  for _, value in ipairs({ op.workspace, op.pane, "unknown", "journal unavailable", "not retried" }) do
    expect.equality(notice:find(value, 1, true) ~= nil, true)
  end
  expect.equality(Create.pending[op.key], op)
  expect.equality(count("agent", "start"), 0)
  expect.equality(#attached, 0)
end

for _, draft in ipairs({ "shell$ echo unexpected #", "shell$ echo value >", "shell$ echo value\n> " }) do
  T["shell draft is not an empty prompt: " .. draft] = function()
    state.draft = draft
    local op = wait(Create.new({ name = "codex" }))
    expect.equality(op.phase, "unknown")
    expect.equality(count("pane", "run"), 0)
    expect.equality(count("agent", "start"), 0)
  end
end

for _, case in ipairs({ "socket", "protocol", "version", "socket-after-create" }) do
  T["server guard prevents mutation on " .. case .. " mismatch"] = function()
    if case == "socket" then
      state.socket = "/wrong.sock"
    elseif case == "protocol" then
      state.protocol = 23
    elseif case == "version" then
      state.server_version = "0.9.4"
    else
      state.socket_after_create = "/wrong.sock"
    end
    local op = wait(Create.new({ name = "codex" }))
    expect.equality(op.phase, case == "socket-after-create" and "unknown" or "failed")
    expect.equality(count("workspace", "create"), case == "socket-after-create" and 1 or 0)
    expect.equality(count("pane", "run"), 0)
    expect.equality(count("agent", "start"), 0)
  end
end

T["journal redacts secrets that the CLI actually returns including JSON escapes"] = function()
  local arg, env = [[sensitive ' " \ quoted argument]], [[private " \ environment]]
  Config.cli.tools.codex.cmd = { "codex", "--model", arg }
  Config.cli.tools.codex.env = { FIXTURE_SECRET = env }
  state.echo_secrets = { arg, env }
  local op = wait(Create.new({ name = "codex" }))
  expect.equality(op.phase, "attached")
  local journal = table.concat(vim.fn.readfile(op.journal), "\n")
  for _, secret in ipairs({ arg, env }) do
    expect.equality(journal:find(secret, 1, true), nil)
    expect.equality(journal:find(vim.json.encode(secret):sub(2, -2), 1, true), nil)
  end
  local start
  for _, record in ipairs(op.records) do
    if record.command == "agent start" then
      start = record
    end
  end
  expect.equality(start.stdout:find("[redacted]", 1, true) ~= nil, true)
end

T["relative cwd is resolved before the tool picker opens"] = function()
  local select_tool
  vim.ui.select = function(items, _, cb)
    if type(items[1]) == "string" then
      select_tool = cb
    else
      cb(items[1])
    end
  end
  Create.new({ cwd = "." })
  vim.fn.chdir(vim.fs.dirname(root))
  select_tool("codex")
  local op
  for _, value in pairs(Create.operations) do
    op = value
  end
  wait(op)
  expect.equality(op.cwd, root)
  expect.equality(op.phase, "attached")
end

T["missing canonical executable fails before any remote commands"] = function()
  vim.fn.exepath = function()
    return ""
  end
  expect.error(function()
    Create.new({ name = "codex" })
  end)
  expect.equality(calls, {})
end

T["stale ready refresh cannot release a newer reservation"] = function()
  state.status = "blocked"
  local first = wait(Create.new({ name = "codex" }))
  state.status = "idle"
  wait(Create.refresh(first.id))
  expect.equality(first.phase, "ready")
  state.hold = "workspace create"
  local second = Create.new({ name = "codex" })
  expect.equality(
    vim.wait(2000, function()
      return #held == 1
    end),
    true
  )
  wait(Create.refresh(first.id))
  expect.equality(Create.pending[second.key], second)
  expect.equality(Create.new({ name = "codex" }), second)
  expect.equality(count("workspace", "create"), 2)
  Create.cancel(second.id)
  held[1]()
end

T["cancel of an older pre-dispatch operation preserves the current reservation"] = function()
  vim.ui.select = function(_, _, cb)
    cb(nil)
  end
  local first = Create.new({ name = "codex" })
  vim.ui.select = function(items, _, cb)
    cb(items[1])
  end
  state.hold = "workspace create"
  local second = Create.new({ name = "codex" })
  expect.equality(
    vim.wait(2000, function()
      return #held == 1
    end),
    true
  )
  Create.cancel(first.id)
  expect.equality(Create.pending[second.key], second)
  Create.cancel(second.id)
  held[1]()
end

T["non-herdr New refuses a registered terminal before reinitializing it"] = function()
  Config.cli.primary_backend = "terminal"
  Session.register("terminal", Terminal)
  local sid = Session.sid({ tool = "codex", cwd = root })
  local current = Session.new({ tool = "codex", cwd = root, id = sid, backend = "terminal" })
  Session._attached[sid] = current
  local autocmd =
    vim.api.nvim_create_autocmd("User", { pattern = "MvpSentinel", group = current.group, callback = function() end })
  local op = Create.new({ name = "codex" })
  expect.equality(op.phase, "failed")
  expect.equality(Terminal.get(sid), current)
  expect.equality(Session._attached[sid], current)
  expect.equality(#vim.api.nvim_get_autocmds({ id = autocmd }), 1)
  expect.equality(#attached, 0)
end

T["late auto-attach preserves an existing manual wrapper"] = function()
  state.hold = "agent start"
  local op = Create.new({ name = "codex" })
  expect.equality(
    vim.wait(2000, function()
      return #held == 1
    end),
    true
  )
  local id = "herdr:" .. vim.fn.sha256("/tmp/mvp.sock") .. ":term-mvp"
  local wrapper = { source_id = id, manual_input = true }
  Session._attached["terminal: " .. id] = wrapper
  held[1]()
  wait(op)
  expect.equality(op.phase, "ready")
  expect.equality(#attached, 0)
  expect.equality(Session._attached["terminal: " .. id], wrapper)
  expect.equality(count("agent", "start"), 1)
end

for _, phase in ipairs({ "blocked", "attached" }) do
  T["final journal failure preserves known " .. phase .. " outcome"] = function()
    state.status = phase == "blocked" and "blocked" or "idle"
    vim.uv.fs_rename = function(from, to)
      local data = vim.json.decode(table.concat(vim.fn.readfile(from), "\n"))
      if data.phase == phase then
        return nil, "ENOSPC"
      end
      return original.rename(from, to)
    end
    local completed
    local op = wait(Create.new({
      name = "codex",
      on_done = function(value)
        completed = value.phase
      end,
    }))
    expect.equality(op.phase, phase)
    expect.equality(completed, phase)
    expect.equality(type(op.persist_error), "string")
    if phase == "blocked" then
      expect.equality(op.error:find("manual attention", 1, true) ~= nil, true)
      expect.equality(table.concat(notices):find("manual attention", 1, true) ~= nil, true)
    else
      expect.equality(Create.pending[op.key], nil)
    end
  end
end

T["primary selection does not reroute legacy implicit starts"] = function()
  local State = require("sidekick.cli.state")
  Config.cli.primary_backend, Config.cli.mux.enabled, Config.cli.mux.backend = "tmux", false, "tmux"
  local TerminalBackend = { __index = nil }
  TerminalBackend.__index = TerminalBackend
  Session.register("terminal", TerminalBackend)
  local used
  Session.attach = function(source)
    used = source
    return source
  end
  State.attach({ tool = Config.tools().codex }, { show = false })
  expect.equality(used.backend, "terminal")
end

T["workspace pre-dispatch journal failure releases an unsent reservation"] = function()
  local fail = true
  vim.uv.fs_rename = function(from, to)
    local data = vim.json.decode(table.concat(vim.fn.readfile(from), "\n"))
    if fail and data.phase == "creating_workspace" then
      fail = false
      return nil, "ENOSPC"
    end
    return original.rename(from, to)
  end
  local op = wait(Create.new({ name = "codex" }))
  expect.equality(op.workspace_dispatched, false)
  expect.equality(op.phase, "failed")
  expect.equality(count("workspace", "create"), 0)
  expect.equality(Create.pending[op.key], nil)
  local next_op = wait(Create.new({ name = "codex" }))
  expect.equality(next_op ~= op, true)
  expect.equality(next_op.phase, "attached")
end

T["short secret keeps identity fields and findable warning targets"] = function()
  Config.cli.tools.codex.env = { X = "1" }
  state.status = "blocked"
  local op = wait(Create.new({ name = "codex" }))
  expect.equality(op.phase, "blocked")
  expect.equality(table.concat(notices):find("w-mvp:p1", 1, true) ~= nil, true)
  local record = op.records[#op.records]
  expect.equality(vim.json.decode(record.stdout).result.agent.pane_id, "w-mvp:p1")
  expect.equality(vim.json.decode(record.stdout).result.agent.agent_status, "blocked")
end

T["overlapping secrets redact the complete longest value first"] = function()
  Config.cli.tools.codex.env = { SHORT = "abc", LONG = "abcXYZ" }
  state.echo_secrets = { "abcXYZ", "abc" }
  local op = wait(Create.new({ name = "codex" }))
  for _, record in ipairs(op.records) do
    if record.command == "agent start" then
      expect.equality(vim.json.decode(record.stdout).result.diagnostic, { "[redacted]", "[redacted]" })
    end
  end
end

T["cancel preserves a settled diagnostic and refresh explains no-start state"] = function()
  state.draft = true
  local op = wait(Create.new({ name = "codex" }))
  local reason = op.error
  Create.cancel(op.id)
  expect.equality(op.phase, "unknown")
  expect.equality(op.error, reason)
  local saved = vim.json.decode(table.concat(vim.fn.readfile(op.journal), "\n"))
  expect.equality(saved.phase, "unknown")
  expect.equality(saved.error, reason)
  Create.refresh(op.id)
  expect.equality(table.concat(notices):find("no agent startup to refresh", 1, true) ~= nil, true)
end

T["invalid discovery does not poison setup and can be corrected"] = function()
  Session.did_setup, Session.backends = false, {}
  Config.cli.discovery.tmux = "yes"
  expect.error(Session.setup)
  expect.equality(Session.did_setup, false)
  expect.error(Session.setup)
  Config.cli.discovery = { herdr = true, tmux = false, zellij = false }
  Session.setup()
  expect.equality(Session.did_setup, true)
  expect.equality(Session.backends.terminal ~= nil, true)
  expect.equality(Session.backends.herdr ~= nil, true)
end

T["a rejected missing executable does not supersede an in-flight request"] = function()
  state.hold = "agent start"
  local op = Create.new({ name = "codex" })
  expect.equality(
    vim.wait(2000, function()
      return #held == 1
    end),
    true
  )
  local generation = Create.generation
  vim.fn.exepath = function(name)
    return name == "claude" and "" or root .. "/fixture-bin/" .. name
  end
  expect.error(function()
    Create.new({ name = "claude" })
  end)
  expect.equality(Create.generation, generation)
  held[1]()
  wait(op)
  expect.equality(op.phase, "attached")
end

T["cancel during shell-settle observation remains cancelled without input"] = function()
  state.shell_children, state.hold = 2, "pane process-info"
  local op = Create.new({ name = "codex" })
  expect.equality(
    vim.wait(2000, function()
      return #held == 1
    end),
    true
  )
  Create.cancel(op.id)
  held[1]()
  expect.equality(
    vim.wait(2000, function()
      return #op.records >= 4
    end),
    true
  )
  expect.equality(op.phase, "cancelled")
  expect.equality(count("pane", "run"), 0)
  expect.equality(count("agent", "start"), 0)
end

T["a partial journal write stops before remote commands"] = function()
  vim.uv.fs_write = function(fd, data, offset)
    return original.write(fd, data:sub(1, -2), offset)
  end
  local op = Create.new({ name = "codex" })
  expect.equality(op.phase, "failed")
  expect.equality(op.persist_error:find("Short creation journal write", 1, true) ~= nil, true)
  expect.equality(calls, {})
end

T["fixture violations remain observable even if a caller catches the error"] = function()
  pcall(
    vim.system,
    { "herdr", "--session", "poc", "agent", "prompt" },
    { env = { HERDR_SOCKET_PATH = "/tmp/mvp.sock" } },
    function() end
  )
  expect.equality(#violations, 1)
  expect.equality(violations[1]:find("Forbidden or unexpected command", 1, true) ~= nil, true)
  violations = {} -- This one intentionally injected violation was asserted above.
end

T["non-herdr New preserves a registered tmux terminal wrapper"] = function()
  local Tmux = require("sidekick.cli.session.tmux")
  Session.register("tmux", Tmux)
  Session.register("terminal", Terminal)
  Config.cli.primary_backend = "tmux"
  local sid = Session.sid({ tool = "codex", cwd = root })
  local id = "terminal: " .. sid
  local current = Session.new({ tool = "codex", cwd = root, id = id, backend = "terminal", mux_backend = "tmux" })
  Session._attached[id] = current
  local start, terminal_start = Tmux.start, Terminal.start
  local starts = 0
  Tmux.start = function()
    return { cmd = { "fixture-client" } }
  end
  Terminal.start = function()
    starts = starts + 1
  end
  Session.attach = original.attach
  local ok, err = pcall(function()
    local op = Create.new({ name = "codex" })
    expect.equality(op.phase, "failed")
    expect.equality(Terminal.get(id), current)
    expect.equality(Session._attached[id], current)
    expect.equality(starts, 0)
  end)
  Tmux.start, Terminal.start = start, terminal_start
  assert(ok, err)
end

T["start pre-dispatch journal failure never claims a command was sent"] = function()
  vim.uv.fs_rename = function(from, to)
    local data = vim.json.decode(table.concat(vim.fn.readfile(from), "\n"))
    if data.phase == "launching" then
      return nil, "ENOSPC"
    end
    return original.rename(from, to)
  end
  local op = wait(Create.new({ name = "codex" }))
  expect.equality(op.phase, "unknown")
  expect.equality(op.start_dispatched, false)
  expect.equality(count("agent", "start"), 0)
  expect.equality(Create.pending[op.key], op)
end

T["begin does not reuse stale discovery diagnostics"] = function()
  Herdr._command_error = "unrelated old error"
  local system = vim.system
  vim.system = function(argv, opts, cb)
    if argv[2] == "session" then
      calls[#calls + 1] = vim.list_slice(argv, 2)
      return {
        wait = function()
          return result({ sessions = {} })
        end,
      }
    end
    return system(argv, opts, cb)
  end
  local op = Create.new({ name = "codex" })
  expect.equality(op.phase, "failed")
  expect.equality(op.error:find("unrelated old error", 1, true), nil)
  expect.equality(count("workspace", "create"), 0)
end

for _, case in ipairs({
  { "herdr", "tmux", true, "tmux" },
  { "herdr", "tmux", false, "terminal" },
  { "herdr", "zellij", true, "zellij" },
  { "herdr", "herdr", false, nil },
  { "terminal", "herdr", true, nil },
  { "tmux", "tmux", true, "tmux" },
  { false, "tmux", true, "tmux" },
  { false, "tmux", false, "terminal" },
}) do
  T["implicit rows and attach retain legacy mux policy: " .. vim.inspect(case)] = function()
    local State = require("sidekick.cli.state")
    Config.cli.primary_backend = case[1] or nil
    Config.cli.mux.backend, Config.cli.mux.enabled = case[2], case[3]
    Config.cli.discovery = { herdr = true, tmux = true, zellij = true }
    Session.backends = {}
    for _, backend in ipairs({ "terminal", "tmux", "zellij", "herdr" }) do
      local provider = {
        sessions = function()
          return {}
        end,
      }
      provider.__index = provider
      Session.register(backend, provider)
    end
    local rows = State.get({ name = "codex" })
    expect.equality(#rows, case[4] and 1 or 0)
    if case[4] then
      expect.equality(rows[1].session, nil)
      local used
      Session.attach = function(source)
        used = source.backend
        return source
      end
      State.attach(rows[1], { show = false })
      expect.equality(used, case[4])
    end
    expect.equality(Create.operations, {})
    expect.equality(calls, {})
  end
end

T["herdr New retains primary while implicit tools retain enabled tmux"] = function()
  Config.cli.mux.backend, Config.cli.mux.enabled = "tmux", true
  local op = wait(Create.new({ name = "codex" }))
  expect.equality(op.phase, "attached")
  expect.equality(attached[1].backend, "herdr")
  expect.equality(count("workspace", "create"), 1)
  expect.equality(count("agent", "start"), 1)
end

for _, case in ipairs({ "claude-effort", "codex-effort", "dangling", "option-value", "env-key", "other-tool" }) do
  T["canonical launch boundary " .. case] = function()
    local name = "codex"
    if case == "claude-effort" then
      name = "claude"
      Config.cli.tools.claude.cmd = { "claude", "--effort", "high" }
    elseif case == "codex-effort" then
      Config.cli.tools.codex.cmd = { "codex", "--effort", "high" }
    elseif case == "dangling" then
      Config.cli.tools.codex.cmd = { "codex", "--model" }
    elseif case == "option-value" then
      Config.cli.tools.codex.cmd = { "codex", "--model", "--print" }
    elseif case == "env-key" then
      Config.cli.tools.codex.env = { ["not-a-key"] = "value" }
    else
      name = "gemini"
      Config.cli.tools.gemini = { cmd = { "gemini" } }
    end
    if case == "claude-effort" then
      local op = wait(Create.new({ name = name }))
      expect.equality(op.phase, "attached")
    else
      expect.error(function()
        Create.new({ name = name })
      end)
      expect.equality(calls, {})
    end
  end
end

T["legacy herdr selection still hides implicit starts with another explicit primary"] = function()
  Config.cli.primary_backend, Config.cli.mux.backend = "terminal", "herdr"
  expect.equality(require("sidekick.cli.state").get(), {})
  expect.equality(Create.operations, {})
end

T["disabled discovery does not remove the legacy creation provider"] = function()
  Config.cli.primary_backend, Config.cli.mux.enabled, Config.cli.mux.backend = "terminal", true, "tmux"
  Config.cli.discovery = { tmux = false, herdr = false, zellij = false }
  Session.did_setup, Session.backends = false, {}
  local executable, used = vim.fn.executable, nil
  vim.fn.executable = function()
    return 1
  end
  Session.attach = function(source)
    used = source
    return source
  end
  local ok, err = pcall(function()
    Session.setup()
    expect.equality(Session.discovers("tmux"), false)
    expect.equality(Session.backends.tmux ~= nil, true)
    require("sidekick.cli.state").attach({ tool = Config.tools().codex }, { show = false })
    expect.equality(used.backend, "tmux")
  end)
  vim.fn.executable = executable
  assert(ok, err)
end

for _, category in ipairs({ "workspace create", "pane get", "pane process-info", "agent get" }) do
  T["null result settles once rather than crashing: " .. category] = function()
    local system = vim.system
    vim.system = function(argv, opts, cb)
      local command = (argv[4] or "") .. " " .. (argv[5] or "")
      if cb and command == category then
        calls[#calls + 1] = vim.list_slice(argv, 2)
        vim.schedule(function()
          cb(result({ result = vim.NIL }))
        end)
        return {}
      end
      return system(argv, opts, cb)
    end
    local completed = 0
    local op = wait(Create.new({
      name = "codex",
      on_done = function()
        completed = completed + 1
      end,
    }))
    expect.equality(op.phase, "unknown")
    expect.equality(completed, 1)
    expect.equality(#attached, 0)
    expect.equality(count("agent", "start"), category == "agent get" and 1 or 0)
  end
end

for _, field in ipairs({ "null_process_entry", "null_process_child" }) do
  T["null process list member fails closed: " .. field] = function()
    state[field] = true
    local op = wait(Create.new({ name = "codex" }))
    expect.equality(op.phase, "unknown")
    expect.equality(count("pane", "run"), 0)
    expect.equality(count("agent", "start"), 0)
  end
end

T["invalid start result can reconcile the same positively ready agent once"] = function()
  local system = vim.system
  vim.system = function(argv, opts, cb)
    if cb and argv[4] == "agent" and argv[5] == "start" then
      calls[#calls + 1] = vim.list_slice(argv, 2)
      state.started, state.name, state.kind = true, argv[6], argv[8]
      vim.schedule(function()
        cb(result({ result = vim.NIL }))
      end)
      return {}
    end
    return system(argv, opts, cb)
  end
  local op = wait(Create.new({ name = "codex" }))
  expect.equality(op.phase, "attached")
  expect.equality(count("agent", "start"), 1)
end

for _, kind in ipairs({ "query-failed", "shell", "success" }) do
  T["final identity evidence is recorded: " .. kind] = function()
    state.process_error = kind == "query-failed"
    state.return_to_shell = kind == "shell"
    local op = wait(Create.new({ name = "codex" }))
    local record = op.records[#op.records]
    expect.equality(record.command, "pane process-info")
    expect.equality(record.kind, "identity")
    if kind == "success" then
      expect.equality(op.phase, "attached")
      expect.equality(record.process_identity.group, vim.fn.getpid())
    else
      expect.equality(op.phase, "unknown")
      local marker = kind == "shell" and "back at its shell" or "synthetic process query failure"
      expect.equality(op.error:find(marker, 1, true) ~= nil, true)
      expect.equality(record.reason ~= nil, true)
      expect.equality(#attached, 0)
    end
  end
end

T["cancel while checking initial server never creates a workspace"] = function()
  state.hold = "status server"
  local op = Create.new({ name = "codex" })
  expect.equality(
    vim.wait(2000, function()
      return #held == 1
    end),
    true
  )
  Create.cancel(op.id)
  held[1]()
  expect.equality(
    vim.wait(2000, function()
      return #op.records == 1
    end),
    true
  )
  expect.equality(op.phase, "cancelled")
  expect.equality(count("workspace", "create"), 0)
  expect.equality(count("agent", "start"), 0)
end

T["late confirmation after cancel has no remote calls"] = function()
  local confirm
  vim.ui.select = function(_, _, cb)
    confirm = cb
  end
  local op = Create.new({ name = "codex" })
  Create.cancel(op.id)
  confirm(op)
  expect.equality(op.phase, "cancelled")
  expect.equality(calls, {})
end

T["fresh non-herdr New uses explicit primary and releases its reservation"] = function()
  Config.cli.primary_backend = "terminal"
  Session.register("terminal", Terminal)
  local used, shown, completed
  Session.attach = function(source)
    used = source
    return {
      show = function()
        shown = true
      end,
      is_running = function()
        return true
      end,
    }
  end
  local op = Create.new({
    name = "codex",
    focus = false,
    on_done = function(value)
      completed = value.phase
    end,
  })
  expect.equality(op.phase, "attached")
  expect.equality(used.backend, "terminal")
  expect.equality(shown, true)
  expect.equality(completed, "attached")
  expect.equality(Create.pending[op.key], nil)
  expect.equality(calls, {})
end

T["nullable foreground cwd falls back to the reported cwd consistently"] = function()
  state.foreground_null = true
  local op = wait(Create.new({ name = "codex" }))
  expect.equality(op.phase, "attached")
  expect.equality(attached[1].cwd, root)
  expect.equality(count("agent", "start"), 1)
end

for _, case in ipairs({ "timeout", "api-message", "api-code", "signal" }) do
  T["workspace failure keeps cause and no-retry warning: " .. case] = function()
    state.workspace_reply = case == "timeout" and result("", 124, "")
      or case == "api-message" and result({ error = { message = "busy" } })
      or case == "api-code" and result({ error = { code = "busy" } })
      or result("", 1, "")
    if case == "signal" then
      state.workspace_reply.signal = 15
    end
    local op = wait(Create.new({ name = "codex" }))
    local cause = case == "timeout" and "timed out" or case == "signal" and "signal 15" or "busy"
    expect.equality(op.phase, "unknown")
    expect.equality(op.error:find(cause, 1, true) ~= nil, true)
    expect.equality(op.error:find("do not retry creation", 1, true) ~= nil, true)
    expect.equality(count("workspace", "create"), 1)
    expect.equality(count("agent", "start"), 0)
  end
end

for _, case in ipairs({ "missing", "not-ready", "blocked" }) do
  T["start failure keeps its original cause after reconciliation: " .. case] = function()
    state.start_reply = result("", 1, "unsupported flag --effort")
    state.agent_missing = case == "missing"
    state.ready = case ~= "not-ready"
    state.status = case == "blocked" and "blocked" or "idle"
    local op = wait(Create.new({ name = "codex" }))
    expect.equality(op.phase, case == "blocked" and "blocked" or "unknown")
    expect.equality(op.error:find("unsupported flag --effort", 1, true) ~= nil, true)
    local saved = vim.json.decode(table.concat(vim.fn.readfile(op.journal), "\n"))
    expect.equality(saved.start_error, "unsupported flag --effort")
    expect.equality(count("agent", "start"), 1)
  end
end

for _, case in ipairs({ "blank_reads", "shell_children" }) do
  T["slow shell exhausts its passive wait with timeout reason: " .. case] = function()
    state[case] = 25
    local op = wait(Create.new({ name = "codex" }))
    expect.equality(op.phase, "unknown")
    expect.equality(op.error:find("Timed out waiting for shell", 1, true) ~= nil, true)
    expect.equality(count("pane", "run"), 0)
    expect.equality(count("agent", "start"), 0)
  end
end

T["journal failure on start reply exposes preserved resources without verify or attach"] = function()
  vim.uv.fs_rename = function(from, to)
    local data = vim.json.decode(table.concat(vim.fn.readfile(from), "\n"))
    if data.records[#data.records] and data.records[#data.records].command == "agent start" then
      return nil, "ENOSPC"
    end
    return original.rename(from, to)
  end
  local done = 0
  local op = wait(Create.new({
    name = "codex",
    on_done = function()
      done = done + 1
    end,
  }))
  expect.equality(op.phase, "unknown")
  expect.equality(done, 1)
  expect.equality(count("agent", "start"), 1)
  expect.equality(count("agent", "get"), 0)
  expect.equality(#attached, 0)
  expect.equality(Create.pending[op.key], op)
  local notice = table.concat(notices, "\n")
  for _, value in ipairs({ op.workspace, op.pane, "unknown", "journal unavailable", "not retried" }) do
    expect.equality(notice:find(value, 1, true) ~= nil, true)
  end
end

for _, mismatch in ipairs({ false, true }) do
  T["late initial server reply preserves cancellation: mismatch=" .. tostring(mismatch)] = function()
    state.hold = "status server"
    local done = 0
    local op = Create.new({
      name = "codex",
      on_done = function()
        done = done + 1
      end,
    })
    expect.equality(
      vim.wait(2000, function()
        return #held == 1
      end),
      true
    )
    Create.cancel(op.id)
    local reason, notice_count = op.error, #notices
    if mismatch then
      for i = 1, 20 do
        local name, reply = debug.getupvalue(held[1], i)
        if name == "reply" then
          local value = vim.json.decode(reply.stdout)
          value.socket = "/tmp/other.sock"
          reply.stdout = vim.json.encode(value)
          break
        end
      end
    end
    held[1]()
    expect.equality(
      vim.wait(2000, function()
        return #op.records == 1
      end),
      true
    )
    expect.equality(op.phase, "cancelled")
    expect.equality(op.error, reason)
    expect.equality(#notices, notice_count)
    expect.equality(done, 1)
    expect.equality(count("workspace", "create"), 0)
    local saved = vim.json.decode(table.concat(vim.fn.readfile(op.journal), "\n"))
    expect.equality(saved.phase, "cancelled")
    expect.equality(saved.error, reason)
  end
end

T["failed fs_close prevents workspace dispatch and releases reservation"] = function()
  vim.uv.fs_close = function(fd)
    local path = vim.uv.fs_readlink("/proc/self/fd/" .. fd) or ""
    local closed, why = original.close(fd)
    if path:find(".json.tmp", 1, true) then
      -- Fail only the write-ahead save after initial planning.
      local data = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
      if data.phase == "creating_workspace" then
        return nil, "EIO"
      end
    end
    return closed, why
  end
  local done = 0
  local op = wait(Create.new({
    name = "codex",
    on_done = function()
      done = done + 1
    end,
  }))
  expect.equality(op.phase, "failed")
  expect.equality(op.persist_error:find("EIO", 1, true) ~= nil, true)
  expect.equality(count("workspace", "create"), 0)
  expect.equality(Create.pending[op.key], nil)
  expect.equality(done, 1)
end

T["journal encoding failure opens no descriptor and sends nothing"] = function()
  local opened = 0
  vim.uv.fs_open = function(...)
    opened = opened + 1
    return original.open(...)
  end
  vim.json.encode = function(value, ...)
    if value.phase then
      error("synthetic encode failure")
    end
    return original.encode(value, ...)
  end
  local op = Create.new({ name = "codex" })
  expect.equality(op.phase, "failed")
  expect.equality(opened, 0)
  expect.equality(calls, {})
end

T["journal write exception still closes its descriptor"] = function()
  local closed = 0
  vim.uv.fs_write = function()
    error("synthetic write failure")
  end
  vim.uv.fs_close = function(fd)
    closed = closed + 1
    return original.close(fd)
  end
  local op = Create.new({ name = "codex" })
  expect.equality(op.phase, "failed")
  expect.equality(closed, 1)
  expect.equality(calls, {})
end

T["missing pane executable reports PATH failure without starting agent"] = function()
  state.marker_prompt = true
  local op = wait(Create.new({ name = "codex" }))
  expect.equality(op.phase, "unknown")
  expect.equality(op.error:find("not found on PATH", 1, true) ~= nil, true)
  expect.equality(op.error:find("shell$", 1, true) ~= nil, true)
  expect.equality(count("agent", "start"), 0)
end

T["different pane executable reports observed and expected paths"] = function()
  state.executable = "/different/codex"
  local op = wait(Create.new({ name = "codex" }))
  expect.equality(op.phase, "unknown")
  expect.equality(op.error:find(op.executable, 1, true) ~= nil, true)
  expect.equality(op.error:find(state.executable, 1, true) ~= nil, true)
  expect.equality(count("agent", "start"), 0)
end

for _, backend in ipairs({ "tmux", "zellij" }) do
  T["unavailable primary is rejected before journal and confirmation: " .. backend] = function()
    Config.cli.primary_backend = backend
    Session.did_setup, Session.backends = false, {}
    vim.fn.executable = function()
      return 0
    end
    local selected, opened = 0, 0
    vim.ui.select = function()
      selected = selected + 1
    end
    vim.uv.fs_open = function(...)
      opened = opened + 1
      return original.open(...)
    end
    local ok, err = pcall(Create.new, { name = "codex" })
    expect.equality(ok, false)
    expect.equality(tostring(err):find("unavailable", 1, true) ~= nil, true)
    expect.equality(selected, 0)
    expect.equality(opened, 0)
    expect.equality(calls, {})
  end
end

T["non-herdr missing tool is refused before confirmation or journal"] = function()
  Config.cli.primary_backend = "terminal"
  Session.register("terminal", Terminal)
  vim.fn.executable = function()
    return 0
  end
  local selected, opened = 0, 0
  vim.ui.select = function()
    selected = selected + 1
  end
  vim.uv.fs_open = function(...)
    opened = opened + 1
    return original.open(...)
  end
  local ok, err = pcall(Create.new, { name = "codex" })
  expect.equality(ok, false)
  expect.equality(tostring(err):find("not installed", 1, true) ~= nil, true)
  expect.equality(selected, 0)
  expect.equality(opened, 0)
  expect.equality(Session._attached, {})
end

for _, failure in ipairs({ "zero", "negative", "throw" }) do
  T["real terminal lifecycle cleans failed spawn and permits retry: " .. failure] = function()
    Config.cli.primary_backend, Config.cli.watch = "terminal", false
    Session.register("terminal", Terminal)
    Session.attach = original.attach
    local live, succeed, attempts, stopped = false, false, 0, 0
    vim.fn.jobstart = function()
      attempts = attempts + 1
      if succeed then
        live = true
        return 87654321
      end
      if failure == "throw" then
        error("synthetic jobstart failure")
      end
      return failure == "zero" and 0 or -1
    end
    vim.fn.jobwait = function()
      return { live and -1 or -3 }
    end
    vim.fn.jobpid = function()
      return vim.fn.getpid()
    end
    vim.fn.jobstop = function()
      live = false
      stopped = stopped + 1
      return 1
    end
    local buffers, windows = #vim.api.nvim_list_bufs(), #vim.api.nvim_list_wins()
    local done = 0
    local op = Create.new({
      name = "codex",
      focus = false,
      on_done = function()
        done = done + 1
      end,
    })
    expect.equality(op.phase, "failed")
    expect.equality(done, 1)
    expect.equality(attempts, 1) -- No implicit second start through show().
    expect.equality(
      op.error:find(failure == "throw" and "synthetic jobstart failure" or "Failed to start", 1, true) ~= nil,
      true
    )
    expect.equality(#vim.api.nvim_list_bufs(), buffers)
    expect.equality(#vim.api.nvim_list_wins(), windows)
    expect.equality(Terminal.terminals, {})
    expect.equality(Session._attached, {})
    expect.equality(Create.pending[op.key], nil)
    succeed = true
    local next_op = Create.new({ name = "codex", focus = false })
    expect.equality(next_op.phase, "attached")
    expect.equality(attempts, 2)
    expect.equality(next_op.session:is_running(), true)
    next_op.session:close()
    expect.error(function()
      next_op.session:show()
    end)
    expect.equality(attempts, 2) -- A closed handle cannot restart or rebuild its UI.
    expect.equality(stopped, 1)
    expect.equality(Terminal.terminals, {})
    expect.equality(Session._attached, {})
    expect.equality(#vim.api.nvim_list_bufs(), buffers)
    expect.equality(#vim.api.nvim_list_wins(), windows)
  end
end

for _, doubled in ipairs({ false, true }) do
  T["arrow shell prompt boundary: doubled=" .. tostring(doubled)] = function()
    local arrow = "\226\157\175"
    state.draft = (doubled and arrow .. arrow or arrow) .. " "
    local op = wait(Create.new({ name = "codex" }))
    expect.equality(op.phase, doubled and "unknown" or "attached")
    expect.equality(count("agent", "start"), doubled and 0 or 1)
  end
end

for _, mode in ipairs({ "window", "split" }) do
  for _, failure in ipairs({ "command-failed", "no-pane", "malformed-pane", "dead-pane" }) do
    T["external tmux creation verifies liveness and permits retry: " .. mode .. "/" .. failure] = function()
      local Tmux = require("sidekick.cli.session.tmux")
      Session.register("tmux", Tmux)
      Config.cli.primary_backend, Config.cli.mux.create = "tmux", mode
      vim.env.TMUX = "fixture-only"
      local succeed, attempts, completed = false, 0, 0
      local sources = {}
      Session.attach = function(source)
        sources[#sources + 1] = source
        return original.attach(source)
      end
      Util.info = function() end
      Util.exec = function(cmd)
        attempts = attempts + 1
        expect.equality(cmd[1], "tmux")
        expect.equality(cmd[2], mode == "window" and "new-window" or "split-window")
        if not succeed then
          if failure == "command-failed" then
            return nil
          end
          if failure == "no-pane" then
            return {}
          end
          if failure == "malformed-pane" then
            return { "not a pane" }
          end
        end
        return { "$7:%9:1234567:fixture:" .. root }
      end
      vim.api.nvim_get_proc = function(pid)
        if pid == 1234567 then
          return (succeed or failure ~= "dead-pane") and { pid = pid } or nil
        end
        return original.get_proc(pid)
      end
      local buffers, windows = #vim.api.nvim_list_bufs(), #vim.api.nvim_list_wins()
      local function done()
        completed = completed + 1
      end
      local failed = Create.new({ name = "codex", focus = false, on_done = done })
      expect.equality(failed.phase, "failed")
      expect.equality(failed.error:find("Failed to start", 1, true) ~= nil, true)
      expect.equality(sources[1].started == true, failure == "dead-pane")
      expect.equality(Session._attached, {})
      expect.equality(Terminal.terminals, {})
      expect.equality(Create.pending[failed.key], nil)
      expect.equality(attempts, 1)
      expect.equality(completed, 1)
      expect.equality(#vim.api.nvim_list_bufs(), buffers)
      expect.equality(#vim.api.nvim_list_wins(), windows)
      succeed = true
      local ready = Create.new({ name = "codex", focus = false, on_done = done })
      expect.equality(ready.phase, "attached")
      expect.equality(ready.session, sources[2])
      expect.equality(ready.session.started, true)
      expect.equality(ready.session:is_running(), true)
      expect.equality(Session._attached[ready.session.id], ready.session)
      expect.equality(Create.pending[ready.key], nil)
      expect.equality(attempts, 2)
      expect.equality(completed, 2)
      Session.detach(ready.session)
      expect.equality(Session._attached, {})
      expect.equality(#vim.api.nvim_list_bufs(), buffers)
      expect.equality(#vim.api.nvim_list_wins(), windows)
    end
  end
end

local function selector()
  local pickers = {}
  vim.ui.select = function(items, opts, cb)
    pickers[#pickers + 1] = { items = items, opts = opts, cb = cb }
  end
  return pickers
end

T["selector New confirms herdr even with legacy tmux and an existing same-cwd source"] = function()
  Config.cli.mux.backend, Config.cli.mux.enabled = "tmux", true
  local provider = {
    priority = 50,
    is_attached = function()
      return false
    end,
  }
  provider.__index = provider
  provider.sessions = function()
    return { { id = "existing-tmux", tool = "codex", cwd = root } }
  end
  Session.register("tmux", provider)
  local pickers, callbacks = selector(), {}
  require("sidekick.cli").select({
    filter = { name = "codex" },
    cb = function(value)
      callbacks[#callbacks + 1] = value or false
    end,
  })
  local items = pickers[1].items
  expect.equality(items[1].session.backend, "tmux")
  local action = items[#items]
  expect.equality(action.new, true)
  expect.equality(action.cwd, root)
  expect.equality(require("sidekick.cli.ui.select").format(action)[1][1]:find("via herdr", 1, true) ~= nil, true)
  pickers[1].cb(action)
  local op = pickers[2].items[1]
  expect.equality(op.phase, "confirming")
  expect.equality(count("workspace", "create"), 0)
  pickers[1].cb(action) -- Duplicate selection reuses the reserved operation, not another dispatch.
  expect.equality(#pickers, 2)
  pickers[2].cb(op)
  wait(op)
  expect.equality(op.phase, "attached")
  expect.equality(count("workspace", "create"), 1)
  expect.equality(count("agent", "start"), 1)
  expect.equality(callbacks, { false, false }) -- Pending attach/send payload never reaches the new agent.
end

T["selector New pins cwd and cancellation leaves each cwd independently available"] = function()
  local pickers = selector()
  require("sidekick.cli").select({ filter = { name = "codex" } })
  local action = pickers[1].items[#pickers[1].items]
  vim.fn.mkdir(root .. "/other", "p")
  vim.fn.chdir(root .. "/other")
  pickers[1].cb(action)
  local first = pickers[2].items[1]
  expect.equality(first.cwd, root)
  require("sidekick.cli").select({ filter = { name = "codex" } })
  pickers[3].cb(pickers[3].items[#pickers[3].items])
  local second = pickers[4].items[1]
  expect.equality(second.cwd, root .. "/other")
  expect.equality(first.key ~= second.key, true)
  pickers[2].cb(nil)
  pickers[4].cb(nil)
  expect.equality(first.phase, "cancelled")
  expect.equality(second.phase, "cancelled")
  expect.equality(Create.pending[first.key], nil)
  expect.equality(Create.pending[second.key], nil)
  expect.equality(count("workspace", "create"), 0)
end

T["selector dismissal and disabled New never dispatch and report validation"] = function()
  Config.cli.mux.herdr.create.enabled = false
  local pickers = selector()
  require("sidekick.cli").select({ filter = { name = "codex" } })
  pickers[1].cb(nil)
  expect.equality(Create.operations, {})
  pickers[1].cb(pickers[1].items[#pickers[1].items])
  expect.equality(Create.operations, {})
  expect.equality(table.concat(notices):find("Herdr creation is disabled", 1, true) ~= nil, true)
  expect.equality(count("workspace", "create"), 0)
end

T["selector New startup failure is retained without retry or legacy fallback"] = function()
  state.start_error, state.agent_missing = true, true
  local pickers = selector()
  require("sidekick.cli").select({ filter = { name = "codex" } })
  local action = pickers[1].items[#pickers[1].items]
  pickers[1].cb(action)
  local op = pickers[2].items[1]
  pickers[2].cb(op)
  wait(op)
  expect.equality(vim.tbl_contains({ "failed", "unknown", "blocked" }, op.phase), true)
  pickers[1].cb(action)
  expect.equality(#pickers, 2)
  expect.equality(count("workspace", "create"), 1)
  expect.equality(count("agent", "start"), 1)
end

T["New command forwards cwd and reaches the existing confirmation flow"] = function()
  local pickers = selector()
  local requested_cwd = root .. "/other project"
  vim.fn.mkdir(requested_cwd, "p")
  require("sidekick.commands").cmd({
    args = "cli new name=codex cwd=" .. string.format("%q", requested_cwd) .. " focus=false",
  })
  local op = pickers[1].items[1]
  expect.equality(op.backend, "herdr")
  expect.equality(op.cwd, requested_cwd)
  expect.equality(op.focus, false)
  pickers[1].cb(nil)
  expect.equality(op.phase, "cancelled")
  expect.equality(count("workspace", "create"), 0)
end

T["selector existing mixed sources attach their own backend and never create"] = function()
  Session.backends = {}
  for _, backend in ipairs({ "tmux", "herdr" }) do
    local provider = {
      priority = 50,
      is_attached = function()
        return false
      end,
    }
    provider.__index = provider
    provider.sessions = function()
      return { { id = backend .. "-source", tool = "codex", cwd = root } }
    end
    Session.register(backend, provider)
  end
  local used = {}
  Session.attach = function(source)
    used[#used + 1] = source.backend
    return source
  end
  local pickers = selector()
  require("sidekick.cli").select({ filter = { name = "codex" } })
  for _, item in ipairs(pickers[1].items) do
    if not item.new then
      pickers[1].cb(item)
    end
  end
  table.sort(used)
  expect.equality(used, { "herdr", "tmux" })
  expect.equality(Create.operations, {})
  expect.equality(calls, {})
end

T["selector sole New is never automatic and attached-only lists omit New"] = function()
  Config.cli.mux.backend = "herdr" -- No legacy placeholder, no discovered sources.
  local pickers = selector()
  require("sidekick.cli.ui.select").select({ auto = true, cb = function() end })
  expect.equality(#pickers[1].items, 1)
  expect.equality(pickers[1].items[1].new, true)
  expect.equality(Create.operations, {})
  require("sidekick.cli.ui.select").select({ filter = { attached = true }, cb = function() end })
  expect.equality(#pickers, 1)
end

T["unfiltered New reports opt-in errors after canonical tool selection"] = function()
  Config.cli.mux.herdr.create.enabled = false
  Config.cli.tools.codex_new = { cmd = { "codex" } }
  local pickers = selector()
  require("sidekick.cli").select()
  pickers[1].cb(pickers[1].items[#pickers[1].items])
  expect.equality(pickers[2].items, { "claude", "codex" })
  pickers[2].cb("codex")
  expect.equality(table.concat(notices):find("Herdr creation is disabled", 1, true) ~= nil, true)
  expect.equality(Create.operations, {})
  local completions = require("sidekick.commands").complete("Sidekick cli new name=")
  expect.equality(completions, { "name=claude", "name=codex" })
end

T["sole legacy tool still auto-attaches without offering or dispatching New"] = function()
  local provider = {
    sessions = function()
      return {}
    end,
  }
  provider.__index = provider
  Session.backends = {}
  Session.register("tmux", provider)
  Config.cli.mux.backend, Config.cli.mux.enabled = "tmux", true
  local used
  Session.attach = function(source)
    used = source.backend
    return source
  end
  local pickers = selector()
  require("sidekick.cli.ui.select").select({
    auto = true,
    filter = { name = "codex" },
    cb = function(row)
      require("sidekick.cli.state").attach(row, { show = false })
    end,
  })
  expect.equality(used, "tmux")
  expect.equality(#pickers, 0)
  expect.equality(Create.operations, {})
  expect.equality(calls, {})
end

for _, enabled in ipairs({ false, true }) do
  T["send choosing New reports cancelled payload without sending: " .. tostring(enabled)] = function()
    Config.cli.mux.backend = "herdr" -- No legacy placeholders: the only picker item is explicit New.
    Config.cli.mux.herdr.create.enabled = enabled
    local pickers = selector()
    local send_count, submit_count, focus_count = 0, 0, 0
    local attach_source = Session.attach
    Session.attach = function(source)
      local terminal = attach_source(source)
      terminal.send = function()
        send_count = send_count + 1
      end
      terminal.submit = function()
        submit_count = submit_count + 1
      end
      terminal.focus = function()
        focus_count = focus_count + 1
      end
      return terminal
    end
    require("sidekick.cli").send({ name = "codex", focus = false, text = { { "pending fixture message" } } })
    expect.equality(
      vim.wait(1000, function()
        return #pickers == 1
      end),
      true
    )
    expect.equality(pickers[1].items[1].new, true)
    pickers[1].cb(pickers[1].items[1])
    expect.equality(table.concat(notices):find("pending text was not sent", 1, true) ~= nil, true)
    if enabled then
      expect.equality(#pickers, 2)
      local op = pickers[2].items[1]
      expect.equality(op.focus, false)
      pickers[2].cb(op)
      wait(op)
      expect.equality(op.phase, "attached")
    else
      expect.equality(#pickers, 1)
      expect.equality(table.concat(notices):find("Herdr creation is disabled", 1, true) ~= nil, true)
    end
    expect.equality(#attached, enabled and 1 or 0)
    expect.equality(send_count, 0)
    expect.equality(submit_count, 0)
    expect.equality(focus_count, 0)
    expect.equality(count("workspace", "create"), enabled and 1 or 0)
    expect.equality(count("agent", "start"), enabled and 1 or 0)
  end
end

for _, entry in ipairs({ "select", "show", "toggle", "focus", "send" }) do
  for _, intent in ipairs({
    { label = "default" },
    { label = "false", value = false },
    { label = "true", value = true },
  }) do
    for _, filtered in ipairs({ false, true }) do
      T["New focus intent: " .. entry .. " " .. intent.label .. " filtered=" .. tostring(filtered)] = function()
        Config.cli.mux.backend = "herdr" -- No legacy rows; explicit New must still require selection.
        local pickers = selector()
        local focus_count, sends = 0, 0
        local attach_source = Session.attach
        Session.attach = function(source)
          local terminal = attach_source(source)
          terminal.focus = function()
            focus_count = focus_count + 1
          end
          terminal.send = function()
            sends = sends + 1
          end
          terminal.submit = function()
            sends = sends + 1
          end
          return terminal
        end
        local opts = { focus = intent.value }
        if filtered then
          if entry == "select" then
            opts.filter = { name = "codex" }
          else
            opts.name = "codex"
          end
        end
        if entry == "send" then
          opts.text = { { "pending matrix fixture" } }
        end
        require("sidekick.cli")[entry](opts)
        expect.equality(
          vim.wait(1000, function()
            return #pickers == 1
          end),
          true
        )
        expect.equality(pickers[1].items[1].new, true)
        pickers[1].cb(pickers[1].items[1])
        local confirmation = 2
        if not filtered then
          expect.equality(pickers[2].items, { "claude", "codex" })
          pickers[2].cb("codex")
          confirmation = 3
        end
        local op = pickers[confirmation].items[1]
        local expected = entry == "focus" or intent.value ~= false
        expect.equality(op.focus ~= false, expected)
        expect.equality(count("workspace", "create"), 0)
        pickers[confirmation].cb(op)
        wait(op)
        expect.equality(op.phase, "attached")
        expect.equality(focus_count, expected and 1 or 0)
        expect.equality(sends, 0)
        expect.equality(#attached, 1)
        expect.equality(count("workspace", "create"), 1)
        expect.equality(count("agent", "start"), 1)
      end
    end
  end
end

return T

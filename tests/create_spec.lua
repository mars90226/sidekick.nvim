local T = require("mini.test").new_set()
local expect = MiniTest.expect
local Config = require("sidekick.config")
local Create = require("sidekick.cli.create")
local Herdr = require("sidekick.cli.session.herdr")
local Session = require("sidekick.cli.session")
local Util = require("sidekick.util")
local state, original, root, calls, notices, attached, held
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
  }
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
    if state.workspace_error then
      return result("{bad", 124, "synthetic timeout")
    end
    return result({ result = { root_pane = pane() } })
  elseif a[1] == "pane" and a[2] == "get" then
    return result({ result = { pane = pane() } })
  elseif a[1] == "pane" and a[2] == "process-info" then
    local info = {
      pane_id = "w-mvp:p1",
      shell_pid = 1,
      foreground_process_group_id = state.started and vim.fn.getpid() or 1,
      foreground_processes = { { pid = 1, name = state.shell_name or "bash", cwd = root } },
    }
    if state.shell_children and state.shell_children > 0 then
      state.shell_children = state.shell_children - 1
      table.insert(info.foreground_processes, { pid = 2, name = "starship", cwd = root })
    end
    return result({ result = { process_info = info } })
  elseif a[1] == "pane" and a[2] == "read" then
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
    return result("command submitted")
  elseif a[1] == "agent" and a[2] == "start" then
    state.started, state.name, state.kind = true, a[3], a[5]
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
      rename = vim.uv.fs_rename,
      exepath = vim.fn.exepath,
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
    state, calls, notices, attached, held = { kind = "codex" }, {}, {}, {}, {}
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
      expect.equality(source.started, true)
      expect.equality(source.backend, "herdr")
      expect.equality(source.manual_input, true)
      attached[#attached + 1] = source
      return { show = function() end, focus = function() end }
    end
    vim.system = function(argv, opts, cb)
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
          return respond(cmd)
        end,
      }
    end
  end,
  post_case = function()
    vim.wait(20, function()
      return false
    end)
    vim.system, vim.ui.select, Session.attach = original.system, original.select, original.attach
    vim.uv.fs_rename = original.rename
    vim.fn.exepath = original.exepath
    Config.cli.primary_backend, Config.cli.discovery, Config.cli.mux, Config.cli.tools =
      original.primary, original.discovery, original.mux, original.tools
    Session.backends, Session.did_setup, Session._attached = original.backends, original.setup, original.attached
    Util.warn, Util.error = original.warn, original.error
    Create.operations, Create.pending, Create.generation = original.ops, original.pending, original.generation
    Herdr.last_error, Herdr._warned, Herdr._command_error = original.last_error, original.warned, original.command_error
    vim.fn.chdir(original.cwd)
    vim.fn.delete(root, "rf")
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
    expect.equality(count("agent", "start") <= 1, true)
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
    local provider = { __index = nil }
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
      expect.equality(value.phase, "unknown")
    end,
  })
  expect.equality(completed, 1)
  expect.equality(op.phase, "unknown")
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
      expect.equality(value.phase, "unknown")
      expect.equality(value.pane, "w-mvp:p1")
    end,
  }))
  expect.equality(completed, 1)
  expect.equality(op.workspace, "w-mvp")
  expect.equality(op.terminal, "term-mvp")
  expect.equality(#op.records, 2)
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

return T

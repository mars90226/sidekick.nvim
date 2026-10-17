local T = require("mini.test").new_set()
local expect = MiniTest.expect
local Config = require("sidekick.config")
local H = require("sidekick.cli.session.herdr")
local Session = require("sidekick.cli.session")
local Terminal = require("sidekick.cli.terminal")
local root = assert(vim.env.SIDEKICK_HERDR_FIXTURE)
local function save(state)
  vim.fn.writefile({ vim.json.encode(state) }, root .. "/state.json")
end
local state, sessions, original, jobs, warnings, errors
local Util = require("sidekick.util")
local function attach(index)
  local source = H.sessions()[index or 1]
  source.backend, source.started = "herdr", true
  return Session.attach(Session.new(source))
end
local function ready(t)
  expect.equality(
    vim.wait(2000, function()
      return t:buf_valid()
        and table.concat(vim.api.nvim_buf_get_lines(t.buf, 0, -1, false), "\n"):find("MOCK ATTACHED", 1, true) ~= nil
    end),
    true
  )
end
local function owned_job(cmd, opts, reap)
  local job = vim.fn.jobstart(cmd, opts or {})
  assert(job > 0)
  jobs[job] = reap == true
  return job
end
local function calls()
  local ret = {}
  for _, line in ipairs(vim.fn.readfile(root .. "/calls")) do
    ret[#ret + 1] = vim.json.decode(line)
  end
  return ret
end
getmetatable(T).opts.hooks = {
  pre_case = function()
    original = {
      mux = vim.deepcopy(Config.cli.mux),
      watch = Config.cli.watch,
      backends = Session.backends,
      setup = Session.did_setup,
      attached = Session._attached,
      terminals = Terminal.terminals,
      warn = Util.warn,
      error = Util.error,
      ui_select = vim.ui.select,
      executable = vim.fn.executable,
      system = vim.system,
      last_error = H.last_error,
      warned = H._warned,
      command_error = H._command_error,
    }
    jobs, warnings, errors = {}, {}, {}
    Util.warn = function(message)
      warnings[#warnings + 1] = message
    end
    Util.error = function(message)
      errors[#errors + 1] = message
    end
    for _, file in ipairs({ "input", "sizes", "owner.pid", "calls", "violations", "zombie.pid" }) do
      vim.fn.delete(root .. "/" .. file)
    end
    state = {
      socket = root .. "/mock.sock",
      process_group = vim.fn.getpid(),
      sessions = { { name = "poc", running = true, socket_path = root .. "/mock.sock" } },
      snapshot = { version = "0.9.5", agents = {} },
    }
    for i = 1, 2 do
      state.snapshot.agents[i] = {
        terminal_id = "term-" .. i,
        pane_id = "w1:p" .. i,
        agent = "codex",
        name = "test-" .. i,
        agent_status = "idle",
        cwd = root,
        agent_session = { agent = "codex", kind = "id", source = "mock", value = "native-" .. i },
      }
    end
    save(state)
    Config.cli.mux.backend, Config.cli.mux.herdr, Config.cli.watch = "herdr", { session = "poc" }, false
    Session.backends, Session.did_setup, Session._attached, Terminal.terminals = {}, true, {}, {}
    H.last_error, H._warned, H._command_error = nil, nil, nil
    Session.register("herdr", H)
    Session.register("terminal", Terminal)
    sessions = H.sessions()
  end,
  post_case = function()
    for _, terminal in ipairs(vim.tbl_values(Terminal.terminals)) do
      terminal:close()
    end
    for job, reap in pairs(jobs) do
      if reap then
        pcall(vim.api.nvim_chan_send, job, "reap\n")
      end
      if vim.fn.jobwait({ job }, reap and 1000 or 0)[1] == -1 then
        vim.fn.jobstop(job)
        vim.fn.jobwait({ job }, 1000)
      end
    end
    vim.wait(20, function()
      return false
    end)
    Config.cli.mux, Config.cli.watch = original.mux, original.watch
    Session.backends, Session.did_setup, Session._attached = original.backends, original.setup, original.attached
    Terminal.terminals = original.terminals
    Util.warn, Util.error, vim.ui.select, vim.fn.executable =
      original.warn, original.error, original.ui_select, original.executable
    vim.system = original.system
    H.last_error, H._warned, H._command_error = original.last_error, original.warned, original.command_error
    expect.equality(vim.fn.filereadable(root .. "/violations"), 0)
    local history = calls()
    for _, argv in ipairs(history) do
      local global_read = vim.deep_equal(argv, { "--version" }) or vim.deep_equal(argv, { "session", "list", "--json" })
      local pinned_attach = #argv == 3 and argv[1] == "terminal" and argv[2] == "attach"
      expect.equality(global_read or pinned_attach or (argv[1] == "--session" and argv[2] == "poc"), true)
      expect.equality(vim.tbl_contains(argv, "--takeover"), false)
    end
    vim.fn.writefile(vim.tbl_map(vim.json.encode, history), root .. "/all-calls", "a")
  end,
}

T["discovery keeps same tool/cwd agents distinct"] = function()
  expect.equality(#sessions, 2)
  expect.no_equality(sessions[1].id, sessions[2].id)
  expect.equality(sessions[1].cwd, sessions[2].cwd)
end

for _, case in ipairs({ "absent", "not running", "socket", "version", "missing cwd", "unknown kind" }) do
  T["discovery refuses " .. case] = function()
    if case == "absent" then
      state.sessions = {}
    end
    if case == "not running" then
      state.sessions[1].running = false
    end
    if case == "socket" then
      state.socket = "other.sock"
    end
    if case == "version" then
      state.snapshot.version = "0.0.0"
    end
    if case == "missing cwd" then
      for _, a in ipairs(state.snapshot.agents) do
        a.cwd = vim.NIL
      end
    end
    if case == "unknown kind" then
      for _, a in ipairs(state.snapshot.agents) do
        a.agent = "not-configured"
      end
    end
    save(state)
    expect.equality(H.sessions(), {})
  end
end

for _, field in ipairs({ "terminal_id", "pane_id", "agent", "agent_session" }) do
  T["attach refuses changed " .. field] = function()
    local s = Session.new(vim.tbl_extend("force", sessions[1], { backend = "herdr", started = true }))
    state.snapshot.agents[1][field] = "replacement"
    save(state)
    expect.equality(s:validate(), false)
    expect.error(function()
      s:attach()
    end)
  end
end

T["attach command never takes over and no start is supported"] = function()
  local s = Session.new(vim.tbl_extend("force", sessions[1], { backend = "herdr", started = true }))
  local cmd = s:attach()
  expect.equality(cmd.cmd, { vim.fn.exepath("herdr"), "terminal", "attach", "term-1" })
  expect.equality(cmd.env, { HERDR_SOCKET_PATH = state.socket, HERDR_SESSION = false })
  expect.error(function()
    s:start()
  end)
  expect.error(function()
    s:send("should not send")
  end)
end

T["same kind replacement without native session rejects a real changed process"] = function()
  state.snapshot.agents[1].agent_session = nil
  local first = owned_job({ "python3", "-I", "-S", "-c", "import time; time.sleep(30)" }, { pty = true })
  state.processes = { ["w1:p1"] = { group = vim.fn.jobpid(first) } }
  save(state)
  local old = Session.new(vim.tbl_extend("force", H.sessions()[1], { backend = "herdr", started = true }))
  expect.equality(old:validate(), true)
  vim.fn.jobstop(first)
  vim.fn.jobwait({ first }, 1000)
  local second = owned_job({ "python3", "-I", "-S", "-c", "import time; time.sleep(30)" }, { pty = true })
  state.processes["w1:p1"].group = vim.fn.jobpid(second)
  save(state)
  expect.equality(old:validate(), false)
  expect.error(function()
    old:attach()
  end)
  local replacement = Session.new(vim.tbl_extend("force", H.sessions()[1], { backend = "herdr", started = true }))
  expect.equality(replacement:validate(), true)
end

T["missing foreground identity fails closed"] = function()
  state.process_group = nil
  save(state)
  expect.equality(H.sessions(), {})
end

T["show closes a stale attachment rather than following replacement"] = function()
  local t = Session.attach(Session.new(vim.tbl_extend("force", sessions[1], { backend = "herdr", started = true })))
  local job = t.job
  t.parent.process_identity.starttime = "replacement"
  expect.error(function()
    t:show()
  end)
  expect.equality(t.closed, true)
  expect.equality(vim.fn.jobwait({ job }, 1000)[1] ~= -1, true)
end

T["terminal wrappers preserve source and coexist"] = function()
  local first = Session.attach(Session.new(vim.tbl_extend("force", sessions[1], { backend = "herdr", started = true })))
  local second =
    Session.attach(Session.new(vim.tbl_extend("force", sessions[2], { backend = "herdr", started = true })))
  expect.no_equality(first.id, second.id)
  expect.equality(first.source_id, sessions[1].id)
  expect.equality(first.parent.binding.terminal, "term-1")
  expect.equality(first.manual_input, true)
  local found = require("sidekick.cli.state").get({ started = true })
  expect.equality(#found, 2)
end

T["public selector attaches the chosen existing agent"] = function()
  local original = vim.ui.select
  vim.ui.select = function(items, _, cb)
    for _, item in ipairs(items) do
      if item.session and item.session.binding and item.session.binding.terminal == "term-2" then
        cb(item)
        return
      end
    end
    error("mock picker did not find the second agent")
  end
  local ok, err = pcall(require("sidekick.cli").select, { focus = false })
  vim.ui.select = original
  assert(ok, err)
  expect.equality(vim.tbl_count(Terminal.terminals), 1)
  expect.equality(vim.tbl_values(Terminal.terminals)[1].parent.binding.terminal, "term-2")
end

T["mock terminal hide show toggle resize and close"] = function()
  local t = Session.attach(Session.new(vim.tbl_extend("force", sessions[1], { backend = "herdr", started = true })))
  expect.equality(
    vim.wait(2000, function()
      return table.concat(vim.api.nvim_buf_get_lines(t.buf, 0, -1, false), "\n"):find("MOCK ATTACHED") ~= nil
    end),
    true
  )
  -- Dedicated mock PTY: bytes arrive without implicit submit, then one CR.
  vim.api.nvim_chan_send(t.job, "draft")
  expect.equality(
    vim.wait(1000, function()
      return vim.fn.getfsize(root .. "/input") == 5
    end),
    true
  )
  expect.equality(table.concat(vim.fn.readfile(root .. "/input", "b"), "\n"), "draft")
  vim.api.nvim_chan_send(t.job, "\r")
  expect.equality(
    vim.wait(1000, function()
      return vim.fn.getfsize(root .. "/input") == 6
    end),
    true
  )
  expect.equality(table.concat(vim.fn.readfile(root .. "/input", "b"), "\n"), "draft\r")
  local job, buf = t.job, t.buf
  t:hide()
  expect.equality(t:is_running(), true)
  t:show()
  t:toggle()
  t:toggle()
  expect.equality(t.job, job)
  expect.equality(t.buf, buf)
  vim.api.nvim_win_set_width(t.win, 50)
  expect.equality(
    vim.wait(1000, function()
      return #vim.fn.readfile(root .. "/sizes") > 1
    end),
    true
  )
  t:send("must not paste\n")
  t:submit()
  expect.equality(t.send_queue, {})
  vim.fn.writefile({
    vim.json.encode({
      input = table.concat(vim.fn.readfile(root .. "/input", "b"), "\n"),
      sizes = vim.fn.readfile(root .. "/sizes"),
      same_job_after_toggle = t.job == job,
      automatic_queue = t.send_queue,
    }),
  }, root .. "/terminal-evidence.json")
  t:close()
  expect.equality(vim.fn.jobwait({ job }, 1000)[1] ~= -1, true)
  expect.equality(t.send_queue, {})
  expect.equality(t.parent:validate(), true) -- fixture agent is independent of attach client
  expect.error(function()
    t:show()
  end)
end

T["plugin owner conflict closes dead wrapper and permits explicit retry"] = function()
  local owner = owned_job(H.command({ "agent", "attach", "w1:p1" }, "poc"), { pty = true })
  expect.equality(
    vim.wait(1000, function()
      return vim.fn.filereadable(root .. "/owner.pid") == 1
        and vim.fn.readfile(root .. "/owner.pid")[1] == tostring(vim.fn.jobpid(owner))
    end),
    true
  )
  local contender = attach()
  local job = contender.job
  expect.equality(vim.fn.jobwait({ job }, 2000)[1], 23)
  expect.equality(
    vim.wait(1000, function()
      return contender.closed == true
    end),
    true
  )
  expect.equality(Terminal.get(contender.id), nil)
  local attempts = vim.tbl_filter(function(argv)
    return argv[1] == "terminal" and argv[2] == "attach"
  end, calls())
  expect.equality(#attempts, 1)
  expect.equality(#errors, 1)
  expect.equality(errors[1]:find("mock input ownership conflict", 1, true) ~= nil, true)
  local source = vim.tbl_filter(function(item)
    return item.session.id == sessions[1].id
  end, require("sidekick.cli.state").get({ started = true }))
  expect.equality(#source, 1)
  vim.fn.jobstop(owner)
  vim.fn.jobwait({ owner }, 1000)
  local retry = attach()
  ready(retry)
  expect.equality(retry:is_running(), true)
  attempts = vim.tbl_filter(function(argv)
    return argv[1] == "terminal" and argv[2] == "attach"
  end, calls())
  expect.equality(#attempts, 2)
end

T["disconnect retires wrapper without restart and permits explicit reselection"] = function()
  local t = attach()
  ready(t)
  local job = t.job
  vim.fn.jobstop(job)
  vim.fn.jobwait({ job }, 1000)
  expect.equality(
    vim.wait(1000, function()
      return t.closed == true
    end),
    true
  )
  expect.error(function()
    t:show()
  end)
  expect.equality(t.send_queue, {})
  expect.equality(Terminal.get(t.id), nil)
  local selected
  vim.ui.select = function(items, _, cb)
    for _, item in ipairs(items) do
      if item.session and item.session.id == sessions[1].id then
        selected = item
        cb(item)
        return
      end
    end
    error("live source was hidden")
  end
  require("sidekick.cli").select({ focus = false })
  expect.equality(selected.session.id, sessions[1].id)
  local replacement = Terminal.get(t.id)
  ready(replacement)
  expect.no_equality(replacement.job, job)
  expect.equality(replacement.source_id, sessions[1].id)
end

T["discovery diagnostics are deduplicated without local fallback"] = function()
  state.fail_snapshot = true
  save(state)
  for _, enabled in ipairs({ false, true }) do
    Config.cli.mux.enabled = enabled
    expect.equality(require("sidekick.cli.state").get(), {})
    local pending = Session.new({ tool = "codex" })
    expect.equality(pending.backend, "herdr")
    expect.error(function()
      pending:start()
    end)
  end
  expect.equality(#warnings, 1)
  expect.equality(H.last_error:find("synthetic snapshot access denied", 1, true) ~= nil, true)
end

for _, bad in ipairs({ "string", false, { session = "../wrong" }, {} }) do
  T["invalid configuration " .. vim.inspect(bad)] = function()
    Config.cli.mux.herdr = bad
    expect.equality(H.sessions(), {})
    expect.equality(#warnings, 1)
  end
end

T["null error succeeds and malformed JSON fails visibly"] = function()
  state.error_null = true
  save(state)
  expect.equality(#H.sessions(), 2)
  state.malformed_snapshot = true
  save(state)
  expect.equality(H.sessions(), {})
  expect.equality(H.last_error:find("invalid JSON", 1, true) ~= nil, true)
end

for _, kind in ipairs({ "missing", "shell" }) do
  T["process evidence rejects " .. kind] = function()
    state.processes =
      { ["w1:p1"] = { group = kind == "missing" and 2147483647 or vim.fn.getpid(), shell_pid = vim.fn.getpid() } }
    save(state)
    local found = H.sessions()
    expect.equality(#found, 1)
    expect.equality(found[1].binding.terminal, "term-2")
  end
end

T["metadata refresh preserves original ownership"] = function()
  local t = attach()
  ready(t)
  state.snapshot.agents[1].name = "renamed"
  state.snapshot.agents[1].agent_status = "working"
  save(state)
  Session.sessions()
  expect.equality(t.parent.agent_name, "renamed")
  expect.equality(t.parent.agent_status, "working")
  local binding = vim.deepcopy(t.parent.binding)
  state.snapshot.agents[1].agent_session.value = "replacement"
  save(state)
  Session.sessions()
  expect.equality(t.parent.binding, binding)
  expect.equality(t.parent:validate(), false)
  expect.equality(t.closed, true)
  expect.equality(Terminal.get(t.id), nil)
  local found = require("sidekick.cli.state").get({ started = true })
  expect.equality(#vim.tbl_filter(function(item)
    return item.session.id == t.source_id
  end, found), 1)
end

T["public send with submit leaves no bytes or queued input"] = function()
  local t = attach()
  ready(t)
  require("sidekick.cli").send({ msg = "must not send", submit = true, filter = { session = t.id } })
  expect.equality(
    vim.wait(2000, function()
      return #warnings >= 2
    end),
    true
  )
  vim.wait(150, function()
    return false
  end)
  expect.equality(t.send_queue, {})
  expect.equality(vim.fn.filereadable(root .. "/input"), 0)
end

T["foreground cwd and named toggle preserve explicit cross-cwd choice"] = function()
  state.snapshot.agents[1].foreground_cwd = root .. "/foreground"
  state.snapshot.agents[2].cwd = root .. "/elsewhere"
  vim.fn.mkdir(root .. "/foreground", "p")
  vim.fn.mkdir(root .. "/elsewhere", "p")
  save(state)
  expect.equality(H.sessions()[1].cwd, root .. "/foreground")
  local selected = false
  vim.ui.select = function(items, _, cb)
    for _, item in ipairs(items) do
      if item.session and item.session.binding.terminal == "term-2" then
        selected = true
        cb(item)
        return
      end
    end
    error("cross cwd source missing")
  end
  require("sidekick.cli").toggle({ name = "codex", focus = false })
  expect.equality(
    vim.wait(2000, function()
      return selected and vim.tbl_count(Terminal.terminals) == 1
    end),
    true
  )
  local t = vim.tbl_values(Terminal.terminals)[1]
  ready(t)
  expect.equality(t.parent.binding.terminal, "term-2")
end

for _, backend in ipairs({ "tmux", "zellij" }) do
  T[backend .. " wrapper deduplicates live source only"] = function()
    local source = { id = backend .. ":source", tool = "codex", cwd = root }
    local stub = { priority = 50 }
    stub.__index = stub
    function stub.sessions()
      return { vim.deepcopy(source) }
    end
    function stub:is_running()
      return true
    end
    function stub:attach()
      return { cmd = { "python3", "-I", "-S", "-c", "import time; time.sleep(30)" } }
    end
    Session.backends = { terminal = Terminal }
    Session.register(backend, stub)
    Config.cli.mux.backend, Config.cli.mux.enabled = backend, true
    local s = Session.new(vim.tbl_extend("force", vim.deepcopy(source), { backend = backend, started = true }))
    local t = Session.attach(s)
    expect.equality(t.source_id, source.id)
    local found = require("sidekick.cli.state").get({ started = true })
    expect.equality(#found, 1)
    expect.equality(found[1].session.id, t.id)
    t:close()
    found = require("sidekick.cli.state").get({ started = true })
    expect.equality(#found, 1)
    expect.equality(found[1].session.id, source.id)
  end
end

T["herdr registration is opt in"] = function()
  vim.fn.executable = function(name)
    return name == "herdr" and 1 or 0
  end
  for _, backend in ipairs({ "tmux", "herdr" }) do
    Session.backends, Session.did_setup = {}, false
    Config.cli.mux.backend = backend
    Session.setup()
    expect.equality(Session.backends.herdr ~= nil, backend == "herdr")
  end
end

T["zombie foreground process is not a live agent"] = function()
  local code =
    "import os,sys,time; p=os.fork();\nif p==0: os.setsid(); os._exit(0)\nopen(sys.argv[1],'w').write(str(p)); time.sleep(.1); sys.stdin.readline(); os.waitpid(p,0)"
  owned_job({ "python3", "-I", "-S", "-c", code, root .. "/zombie.pid" }, { pty = true }, true)
  expect.equality(
    vim.wait(2000, function()
      return vim.fn.filereadable(root .. "/zombie.pid") == 1
    end),
    true
  )
  local pid = tonumber(vim.fn.readfile(root .. "/zombie.pid")[1])
  expect.equality(
    vim.wait(2000, function()
      local f = io.open("/proc/" .. pid .. "/stat", "r")
      if not f then
        return false
      end
      local stat = f:read("*a")
      f:close()
      return stat:match("%) Z ") ~= nil
    end),
    true
  )
  state.processes = { ["w1:p1"] = { group = pid } }
  save(state)
  expect.equality(#H.sessions(), 1)
end

for _, bad in ipairs({ vim.NIL, 0, -1, 1.5, "unknown" }) do
  T["missing or invalid shell identity " .. vim.inspect(bad)] = function()
    state.shell_pid = bad
    save(state)
    expect.equality(H.sessions(), {})
    expect.equality(#warnings, 1)
  end
end

T["attachment does not need the reported agent cwd to exist"] = function()
  state.snapshot.agents[1].foreground_cwd = root .. "/deleted-agent-cwd"
  save(state)
  expect.equality(vim.fn.isdirectory(state.snapshot.agents[1].foreground_cwd), 0)
  local before = #vim.api.nvim_list_wins()
  local t = attach()
  ready(t)
  expect.equality(t.cwd, state.snapshot.agents[1].foreground_cwd)
  expect.equality(t:is_running(), true)
  t:hide()
  t:show()
  t:close()
  expect.equality(Terminal.get(t.id), nil)
  expect.equality(#vim.api.nvim_list_wins(), before)
end

for _, server in ipairs({ vim.NIL, "", 123, "0.9.5" }) do
  for _, client in ipairs({ "", "unexpected version", "herdr 0.9.5", "herdr 0.9.4" }) do
    T["version gate server=" .. vim.inspect(server) .. " client=" .. client] = function()
      state.snapshot.version = server
      state.client_version_output = client
      save(state)
      local valid = server == "0.9.5" and client == "herdr 0.9.5"
      expect.equality(#H.sessions(), valid and 2 or 0)
      expect.equality(#warnings, valid and 0 or 1)
    end
  end
end

T["empty stderr has stable actionable exit diagnostic"] = function()
  state.fail_snapshot, state.empty_error = true, true
  save(state)
  expect.equality(H.sessions(), {})
  expect.equality(H.sessions(), {})
  expect.equality(#warnings, 1)
  expect.equality(warnings[1]:find("exit 3", 1, true) ~= nil, true)
  expect.equality(warnings[1]:find("table:", 1, true), nil)
end

T["missing executable registers diagnosis instead of local fallback"] = function()
  Config.cli.mux.backend = "herdr"
  Session.backends, Session.did_setup = {}, false
  vim.fn.executable = function()
    return 0
  end
  vim.system = function()
    error("herdr executable not found")
  end
  expect.equality(require("sidekick.cli.state").get(), {})
  expect.equality(Session.backends.herdr ~= nil, true)
  expect.equality(#warnings, 1)
  expect.equality(warnings[1]:find("executable not found", 1, true) ~= nil, true)
end

T["validation preserves binding and process refusal reasons"] = function()
  local source = Session.new(vim.tbl_extend("force", sessions[1], { backend = "herdr", started = true }))
  state.snapshot.agents[1].agent_session.value = "replacement"
  save(state)
  local valid, reason = source:validate()
  expect.equality(valid, false)
  expect.equality(reason, "agent binding changed")
  state.snapshot.agents[1].agent_session.value = "native-1"
  state.processes = { ["w1:p1"] = { group = 2147483647 } }
  save(state)
  valid, reason = source:validate()
  expect.equality(valid, false)
  expect.equality(reason:find("foreground process identity", 1, true) ~= nil, true)
end

T["second validation failure unregisters never-started wrapper"] = function()
  local source = Session.new(vim.tbl_extend("force", sessions[1], { backend = "herdr", started = true }))
  local count = 0
  source.validate = function()
    count = count + 1
    return count == 1, "synthetic second validation failure"
  end
  expect.error(function()
    Session.attach(source)
  end)
  expect.equality(Terminal.terminals, {})
end

for _, case in ipairs({ "non-agent", "empty", "other-process-unknown" }) do
  T["confirmed absence retires wrapper " .. case] = function()
    local t = attach()
    ready(t)
    if case == "empty" then
      state.snapshot.agents = {}
    else
      state.snapshot.agents[1].agent = vim.NIL
      if case == "other-process-unknown" then
        state.processes = { ["w1:p2"] = { group = 2147483647 } }
      end
    end
    save(state)
    Session.sessions()
    expect.equality(t.closed, true)
    expect.equality(Terminal.get(t.id), nil)
    expect.equality(
      vim.tbl_contains(warnings, function(message)
        return message:find("no longer detected", 1, true) ~= nil
      end, { predicate = true }),
      true
    )
  end
end

for _, case in ipairs({ "process", "query", "malformed-list", "malformed-record" }) do
  T["unknown discovery preserves client " .. case] = function()
    local t = attach()
    ready(t)
    if case == "process" then
      state.processes = { ["w1:p1"] = { group = 2147483647 } }
    elseif case == "query" then
      state.fail_snapshot = true
    elseif case == "malformed-list" then
      state.snapshot.agents = { invalid = "object instead of array" }
    else
      state.snapshot.agents[1].agent = vim.NIL
      state.snapshot.agents[3] = { invalid = "missing identity" }
    end
    save(state)
    Session.sessions()
    expect.equality(t.closed, nil)
    expect.equality(t:is_running(), true)
    expect.equality(t.parent.agent_status, "unknown")
  end
end

T["attached non-native process replacement closes old client"] = function()
  for _, agent in ipairs(state.snapshot.agents) do
    agent.name, agent.agent_session = nil, nil
  end
  local first = owned_job({ "python3", "-I", "-S", "-c", "import time; time.sleep(30)" }, { pty = true })
  state.processes = { ["w1:p1"] = { group = vim.fn.jobpid(first) } }
  save(state)
  local t = attach()
  ready(t)
  local old_process = vim.deepcopy(t.parent.process_identity)
  state.snapshot.agents[1].revision, state.snapshot.agents[1].state_change_seq = 2, 3
  save(state)
  Session.sessions()
  expect.equality(t.closed, nil)
  vim.fn.jobstop(first)
  vim.fn.jobwait({ first }, 1000)
  local second = owned_job({ "python3", "-I", "-S", "-c", "import time; time.sleep(30)" }, { pty = true })
  state.processes["w1:p1"].group = vim.fn.jobpid(second)
  save(state)
  Session.sessions()
  expect.equality(t.closed, true)
  expect.equality(Terminal.get(t.id), nil)
  expect.equality(t.parent.process_identity, old_process)
  expect.equality(#warnings, 1)
  expect.equality(warnings[1]:find("owner identity changed", 1, true) ~= nil, true)
  local found = require("sidekick.cli.state").get({ started = true })
  expect.equality(#vim.tbl_filter(function(item)
    return item.session.id == t.source_id
  end, found), 1)
end

T["picker formats named unnamed and plain sessions"] = function()
  local Select = require("sidekick.cli.ui.select")
  local State = require("sidekick.cli.state")
  local function render(source)
    source.backend, source.started = "herdr", true
    return table.concat(vim.tbl_map(function(part)
      return part[1]
    end, Select.format(State.get_state(Session.new(source)))))
  end
  expect.equality(render(H.sessions()[1]):find("test-1", 1, true) ~= nil, true)
  for _, agent in ipairs(state.snapshot.agents) do
    agent.name = nil
  end
  save(state)
  local discovered = H.sessions()
  local first, second = render(discovered[1]), render(discovered[2])
  expect.no_equality(first, second)
  expect.equality(first:find("term-1 (idle)", 1, true) ~= nil, true)
  expect.equality(second:find("term-2 (idle)", 1, true) ~= nil, true)
  local plain = Terminal.new({ tool = "codex", cwd = root, started = true })
  local label = table.concat(vim.tbl_map(function(part)
    return part[1]
  end, Select.format(State.get_state(plain))))
  expect.equality(label:find("[terminal]", 1, true) ~= nil, true)
end

T["invalid manual attachment fails before resource registration"] = function()
  expect.error(function()
    Terminal.new({ tool = "codex", manual_input = true })
  end)
  expect.equality(Terminal.terminals, {})
end

T["configuration diagnostics distinguish shape and invalid name"] = function()
  Config.cli.mux.herdr = false
  expect.equality(H.sessions(), {})
  expect.equality(H.last_error:find("must be a table", 1, true) ~= nil, true)
  Config.cli.mux.herdr = { session = "invalid/name" }
  expect.equality(H.sessions(), {})
  expect.equality(H.last_error:find("letters, digits", 1, true) ~= nil, true)
end

return T

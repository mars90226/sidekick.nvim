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
local state, sessions
getmetatable(T).opts.hooks = {
  pre_case = function()
    vim.fn.delete(root .. "/input")
    vim.fn.delete(root .. "/sizes")
    vim.fn.delete(root .. "/owner.pid")
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
    Config.cli.mux.backend = "herdr"
    Config.cli.mux.herdr.session = "poc"
    Config.cli.watch = false
    Session.backends = {}
    Session.did_setup = true
    Session._attached = {}
    Session.register("herdr", H)
    Session.register("terminal", Terminal)
    sessions = H.sessions()
  end,
  post_case = function()
    for _, terminal in pairs(vim.tbl_values(Terminal.terminals)) do
      terminal:close()
    end
    vim.wait(50, function()
      return false
    end)
  end,
}

T["discovery keeps same tool/cwd agents distinct"] = function()
  expect.equality(#sessions, 2)
  expect.no_equality(sessions[1].id, sessions[2].id)
  expect.equality(sessions[1].cwd, sessions[2].cwd)
end

for _, case in ipairs({ "absent", "denied", "socket", "version", "missing cwd", "unknown kind" }) do
  T["discovery refuses " .. case] = function()
    if case == "absent" then
      state.sessions = {}
    end
    if case == "denied" then
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
  expect.equality(s:attach().cmd, { "herdr", "--session", "poc", "agent", "attach", "w1:p1" })
  expect.error(function()
    s:start()
  end)
  expect.error(function()
    s:send("should not send")
  end)
end

T["same kind replacement without native session rejects old process"] = function()
  state.snapshot.agents[1].agent_session = nil
  save(state)
  local discovered = H.sessions()[1]
  local old = Session.new(vim.tbl_extend("force", discovered, { backend = "herdr", started = true }))
  expect.equality(old:validate(), true)
  old.process_identity.starttime = "different-process-birth"
  expect.equality(old:validate(), false)
  expect.error(function()
    old:attach()
  end)
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
  local old = require("sidekick.util").warn
  require("sidekick.util").warn = function() end
  t:send("must not paste\n")
  t:submit()
  require("sidekick.util").warn = old
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

T["mock owner conflict does not retry or take over"] = function()
  local args = H.command({ "agent", "attach", "w1:p1" }, "poc")
  local owner = vim.fn.jobstart(args, { pty = true })
  expect.equality(
    vim.wait(1000, function()
      return vim.fn.filereadable(root .. "/owner.pid") == 1
        and vim.fn.readfile(root .. "/owner.pid")[1] == tostring(vim.fn.jobpid(owner))
    end),
    true
  )
  local contender = vim.fn.jobstart(args, { pty = true })
  expect.equality(vim.fn.jobwait({ contender }, 2000)[1], 23)
  vim.fn.jobstop(owner)
  vim.fn.jobwait({ owner }, 1000)
end

T["disconnect cannot restart or replay queued input"] = function()
  local t = Session.attach(Session.new(vim.tbl_extend("force", sessions[1], { backend = "herdr", started = true })))
  local job = t.job
  vim.fn.jobstop(job)
  vim.fn.jobwait({ job }, 1000)
  expect.error(function()
    t:show()
  end)
  expect.equality(t.send_queue, {})
  expect.equality(t.job, job)
end

return T

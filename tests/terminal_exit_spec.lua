local expect = MiniTest.expect
local Herdr = require("sidekick.cli.session.herdr")
local Terminal = require("sidekick.cli.terminal")
local Util = require("sidekick.util")
local original, state, calls, notices
local T = require("mini.test").new_set({
  hooks = {
    pre_case = function()
      original = { system = vim.system, error = Util.error, warn = Util.warn, command_error = Herdr._command_error }
      original.session_env = vim.env.HERDR_SESSION
      vim.env.HERDR_SESSION = "unrelated-session-must-not-route"
      state = { panes = {}, version = "0.9.5", protocol = 22 }
      calls, notices = {}, {}
      Util.error = function(message)
        notices[#notices + 1] = { "error", message }
      end
      Util.warn = function(message)
        notices[#notices + 1] = { "warn", message }
      end
      vim.system = function(cmd, opts)
        calls[#calls + 1] = vim.deepcopy(cmd)
        expect.equality(opts.timeout, 1500)
        local value, code, stderr
        if cmd[2] == "--version" then
          value = "herdr 0.9.5"
        else
          -- Every server read uses the original socket, never a mutable config
          -- session or the use-or-create --session argument.
          expect.equality(opts.env.HERDR_SOCKET_PATH, "/tmp/exit-pinned.sock")
          expect.equality(opts.env.HERDR_SESSION, nil)
          expect.equality(opts.clear_env, true)
          expect.equality(vim.tbl_contains(cmd, "--session"), false)
          if cmd[2] == "status" then
            value = {
              running = not state.stopped,
              socket = state.socket or "/tmp/exit-pinned.sock",
              version = state.version,
              protocol = state.protocol,
            }
            if state.status_error then
              code, stderr = 1, "connection lost"
            end
          elseif cmd[2] == "api" then
            value = {
              result = {
                snapshot = {
                  version = "0.9.5",
                  protocol = state.snapshot_protocol or 22,
                  agents = {},
                  panes = state.panes,
                },
              },
            }
            if state.invalid_json then
              value = "{bad"
            end
            if state.query_error then
              code, stderr = 124, "timed out"
            end
            if state.after_socket then
              state.socket = state.after_socket
            end
          else
            error("Unexpected CLI call: " .. table.concat(cmd, " "))
          end
        end
        return {
          wait = function()
            return {
              code = code or 0,
              stderr = stderr or "",
              stdout = type(value) == "table" and vim.json.encode(value) or value,
            }
          end,
        }
      end
    end,
    post_case = function()
      vim.system, Util.error, Util.warn = original.system, original.error, original.warn
      Herdr._command_error = original.command_error
      vim.env.HERDR_SESSION = original.session_env
    end,
  },
})
local function parent()
  return setmetatable({
    endpoint = { name = "original", socket = "/tmp/exit-pinned.sock" },
    binding = { terminal = "term-target", pane = "old:p1" },
  }, Herdr)
end
local function terminal(owner)
  return setmetatable({
    parent = owner or parent(),
    buf_valid = function()
      return false
    end,
  }, Terminal)
end
T["healthy complete inventory confirms absence without claiming exit success"] = function()
  local t = terminal()
  t:report_exit(1)
  t:report_exit(1)
  expect.equality(#notices, 1)
  expect.equality(notices[1][1], "warn")
  expect.equality(notices[1][2]:find("status 1", 1, true) ~= nil, true)
  expect.equality(notices[1][2]:find("agent exit status unknown", 1, true) ~= nil, true)
  expect.equality(notices[1][2]:find("select the existing agent", 1, true), nil)
end
T["moved target terminal and agent absent still retain attach failure"] = function()
  state.panes = { { terminal_id = "term-target", pane_id = "new:p7" } }
  terminal():report_exit(1)
  expect.equality(notices[1][1], "error")
end
for _, case in ipairs({
  { "server shutdown", { stopped = true } },
  { "socket mismatch", { socket = "/tmp/replaced.sock" } },
  { "socket changed during query", { after_socket = "/tmp/replaced.sock" } },
  { "transport failure", { status_error = true } },
  { "snapshot timeout", { query_error = true } },
  { "snapshot malformed", { invalid_json = true } },
  { "version mismatch", { version = "0.9.6" } },
  { "protocol mismatch", { protocol = 23 } },
  { "unsupported consistent protocol", { protocol = 23, snapshot_protocol = 23 } },
  { "missing panes", { panes = vim.NIL } },
  { "invalid pane", { panes = { { pane_id = "w:p1" } } } },
  { "duplicate pane", { panes = { { terminal_id = "x", pane_id = "a" }, { terminal_id = "y", pane_id = "a" } } } },
  { "duplicate terminal", { panes = { { terminal_id = "x", pane_id = "a" }, { terminal_id = "x", pane_id = "b" } } } },
}) do
  T[case[1] .. " retains error"] = function()
    state = vim.tbl_extend("force", state, case[2])
    terminal():report_exit(1)
    expect.equality(#notices, 1)
    expect.equality(notices[1][1], "error")
    expect.equality(notices[1][2]:find("terminal state unavailable", 1, true) ~= nil, true)
  end
end
T["clean client exit does not query or notify"] = function()
  terminal():report_exit(0)
  expect.equality(calls, {})
  expect.equality(notices, {})
end
T["unknown status and failed observer preserve error"] = function()
  terminal({
    terminal_present = function()
      error("handshake failure")
    end,
  }):report_exit(-1)
  expect.equality(notices[1][1], "error")
  expect.equality(notices[1][2]:find("handshake failure", 1, true) ~= nil, true)
end
T["screen contents do not establish terminal absence and diagnostics survive"] = function()
  state.panes = { { terminal_id = "term-target", pane_id = "w:p1" } }
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "herdr: server shut down: terminal term-target exited" })
  local t = terminal()
  t.buf, t.buf_valid = b, function()
    return true
  end
  t:report_exit(1)
  vim.api.nvim_buf_delete(b, { force = true })
  expect.equality(notices[1][1], "error")
  expect.equality(notices[1][2]:find("herdr: server shut down", 1, true) ~= nil, true)
end
T["closed wrapper never queries or reports again"] = function()
  local t = terminal()
  t.closed = true
  t:report_exit(1)
  expect.equality(calls, {})
  expect.equality(notices, {})
end
return T

local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.Select: sidekick.cli.With
---@field cb fun(state?:sidekick.cli.State) Receives nil on dismissal or explicit New.
---@field auto? boolean Automatically select if only one tool matches the filter
---@field new? boolean Include an explicit New action (default true).

---@class sidekick.cli.NewItem
---@field new true
---@field backend string
---@field cwd string
---@field name? string

local M = {}

---@param opts sidekick.cli.Select
function M.select(opts)
  assert(type(opts) == "table", "opts must be a table")
  local Session = require("sidekick.cli.session")
  local cwd = Session.cwd() -- Pin cwd before either asynchronous picker opens.
  ---@type (sidekick.cli.State|sidekick.cli.NewItem)[]
  local tools = require("sidekick.cli.state").get(opts.filter)

  ---@param state? sidekick.cli.State|sidekick.cli.NewItem
  local on_select = function(state)
    if state and state.new then
      if opts.pending_send then
        Util.warn("New cancels this send; the pending text was not sent. Re-enter it after attaching.")
      end
      opts.cb(nil) -- Cancel the original attach/send action; New never submits its payload.
      local ok, err =
        pcall(require("sidekick.cli.create").new, { name = state.name, cwd = state.cwd, focus = opts.focus }, state)
      if not ok then
        Util.error(tostring(err))
      end
      return
    end
    if state and not state.installed then
      M.on_missing(state.tool)
      state = nil
    end
    opts.cb(state)
  end

  -- Preserve automatic attachment to a sole matching source. New is never automatic.
  if #tools == 1 and opts.auto then
    on_select(tools[1])
    return
  end
  local filter = opts.filter or {}
  if
    opts.new ~= false
    and not filter.attached
    and not filter.started
    and not filter.session
    and not filter.terminal
  then
    tools[#tools + 1] = { new = true, backend = Session.primary(), cwd = cwd, name = filter.name }
  end
  if #tools == 0 then
    Util.warn("No tools match the given filter")
    return
  end

  ---@type snacks.picker.ui_select.Opts
  local select_opts = {
    prompt = "Select CLI tool:",
    kind = "sidekick_cli",
    ---@param tool sidekick.cli.State|sidekick.cli.NewItem
    format_item = function(tool)
      local parts = M.format(tool)
      return table.concat(vim.tbl_map(function(p)
        return p[1]
      end, parts))
    end,
    snacks = { format = M.format },
  }

  vim.ui.select(tools, select_opts, on_select)
end

---@param tool sidekick.cli.Tool
function M.on_missing(tool)
  Util.error(("Tool `%s` is not installed"):format(tool.name))
  if tool.url then
    local ok, err = vim.ui.open(tool.url)
    if ok then
      Util.info(("Opening %s in your browser..."):format(tool.url))
    else
      Util.error(("Failed to open %s: %s"):format(tool.url, err))
    end
  end
end

---@param state sidekick.cli.State|sidekick.cli.NewItem|snacks.picker.Item
---@param picker? snacks.Picker
function M.format(state, picker)
  if state.new then
    return { { "New " .. (state.name or "agent") .. " via " .. state.backend .. " in " .. state.cwd, "Special" } }
  end
  local sw = vim.api.nvim_strwidth
  local ret = {} ---@type snacks.picker.Highlight[]

  local status = state.attached and "attached"
    or state.started and "started"
    or state.installed and "installed"
    or "missing"

  local status_hl = "SidekickCli" .. status:gsub("^%l", string.upper)

  if picker then
    local count = picker:count()
    local idx = tostring(state.idx)
    idx = (" "):rep(#tostring(count) - #idx) .. idx
    ret[#ret + 1] = { idx .. ".", "SnacksPickerIdx" }
    ret[#ret + 1] = { " " }
  end
  ret[#ret + 1] = { Config.ui.icons[status], status_hl }
  ret[#ret + 1] = { " " }
  ret[#ret + 1] = { state.tool.name }
  local len = sw(state.tool.name) + 2
  if state.session then
    ret[#ret + 1] = { string.rep(" ", 12 - len) }

    if state.external then
      ret[#ret + 1] = { Config.ui.icons["external_" .. status], status_hl }
    else
      ret[#ret + 1] = { Config.ui.icons["terminal_" .. status], status_hl }
    end
    len = len + 2

    -- Keep this for debugging purposes
    -- ret[#ret + 1] = { table.concat(state.session.pids or {}, ",") }

    local metadata_width = 0
    local parent = state.session.parent or state.session
    if parent.agent_name or parent.binding then
      local label = " " .. (parent.agent_name or parent.binding.terminal)
      ret[#ret + 1] = { label, "Special" }
      metadata_width = metadata_width + sw(label)
      if type(parent.agent_status) == "string" and parent.agent_status ~= "" then
        label = " (" .. parent.agent_status .. ")"
        ret[#ret + 1] = { label }
        metadata_width = metadata_width + sw(label)
      end
    end

    local backends = {} ---@type string[]
    backends[#backends + 1] = state.session.mux_backend or state.session.backend
    if state.external then
      backends[#backends + 1] = state.session.mux_session
    end
    local backend = ("[%s]"):format(table.concat(backends, ":"))

    ret[#ret + 1] = { backend, "Special" }
    len = 12 + sw(backend) + metadata_width
    ret[#ret + 1] = { string.rep(" ", math.max(0, 40 - len)) }
    if picker then
      local item = setmetatable({}, state) --[[@as snacks.picker.Item]]
      item.file = state.session.cwd
      item.dir = true
      vim.list_extend(ret, require("snacks").picker.format.filename(item, picker))
    else
      ret[#ret + 1] = { vim.fn.fnamemodify(state.session.cwd, ":p:~"), "Directory" }
    end
  end
  return ret
end

return M

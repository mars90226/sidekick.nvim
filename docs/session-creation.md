### New sessions, existing sessions, and backends

`primary_backend` selects the backend for explicit **New** requests. It does not
replace `mux.backend`: ordinary tool rows retain the legacy
`mux.enabled`/`mux.backend` launch behavior. Existing session rows always attach
to their own backend, even when it differs from the primary.

Open `:Sidekick cli select` (or the example `<leader>as` mapping) and choose
**New agent via herdr in /current/directory** to create through the primary.
Choose an existing session row to attach instead. Herdr New remains available
even when sessions for that tool and directory already appear. A name-filtered picker
shows a named New action; an unfiltered picker asks which tool to create.
Automatic selection of a sole existing tool retains the old behavior and never
automatically chooses New. Programmatic callers can omit the action with
`require("sidekick.cli").select({ new = false })`; attached-only and
started-only lists do not offer it.

To discover tmux and herdr together, create new agents in an already-running
herdr server, and preserve ordinary tmux tool rows:

```lua
require("sidekick").setup({
  cli = {
    primary_backend = "herdr",
    discovery = { herdr = true, tmux = true },
    mux = {
      enabled = true,
      backend = "tmux",
      herdr = {
        session = "default", -- Must name an existing running server.
        create = { enabled = true, workspace = "new" },
      },
    },
  },
})
```

Herdr creation is disabled by default. Selecting New while it is disabled reports
`Herdr creation is disabled; enable cli.mux.herdr.create.enabled`; discovery and
attachment still work. No action starts a server or silently falls back to tmux.
A legacy `mux.backend = "herdr"` continues to hide ordinary not-started tool rows;
its explicit New action remains available, subject to the same opt-in.

You can also use the command or Lua API:

```vim
:Sidekick cli new
:Sidekick cli new name=codex
:Sidekick cli new name=claude cwd="/path/to/project" focus=false
```

```lua
require("sidekick.cli").new({ name = "codex", cwd = "/path/to/project" })
```

Tab completion offers the `new` subcommand, tool names as `name=...`, and the
`cwd=` and `focus=false` arguments. Herdr tool completion offers only `claude`
and `codex`. Always quote `cwd` as a Lua string literal, even without spaces:
`cwd="/path/to/project"`. The directory must already exist.

New captures Neovim's working directory (check `:pwd`) before the picker opens,
unless the API or command supplies `cwd`. Changing cwd afterward does not retarget
that request. Each confirmed herdr New creates a dedicated workspace in the
selected existing server. The same tool in different directories has independent
requests; switching projects does not force attachment to the other project.
Selecting an existing row attaches that exact source, including one in another
directory. Terminal/tmux/zellij New refuses a session already registered under
the same Sidekick tool/cwd ID; select that session explicitly. Otherwise
tmux/zellij may reuse an existing mux session with the matching tool/cwd name.

Herdr New currently supports canonical interactive `claude` and `codex` tools
whose first command argument is exactly the matching executable name. It accepts `--model`
and Claude `--effort`; aliases such as `codex_new`, resume commands, wrappers,
prompt arguments, and environment unsets are unsupported. Choose the canonical
tool for New; legacy tmux tool rows keep their existing custom command behavior.

New requires a separate confirmation. Dismissing any picker creates no workspace or agent;
repeated selections while a request is pending reuse it. An uncertain startup
is retained for inspection and is not automatically retried. Existing live
sources remain selectable. A New selected during a send action cancels that send
payload instead of sending it to the newly created agent, with a notice to re-enter
it after attaching. Herdr attachments
require manual terminal input; automatic paste/submit remain disabled. Closing
the Sidekick window or attachment does not terminate the herdr agent.

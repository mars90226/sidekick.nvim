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
        -- create = { enabled = false } explicitly disables New, even with herdr primary.
      },
    },
  },
})
```

Herdr creation opt-in is resolved only for explicit New requests:

| `create.enabled` | Creation permission |
| --- | --- |
| omitted / `nil` | Enabled only when `cli.primary_backend` is explicitly `"herdr"`. |
| `true` | Enabled, including inherited legacy herdr routing. |
| `false` | Always disabled, even with explicit herdr primary. |

With the default configuration, no herdr creation is enabled. Discovery, listing,
and attaching never create a herdr agent or server, regardless of this option.
A disabled New request reports `Herdr creation is disabled`; existing discovery
and attachments still work. No action starts a server or silently falls back to tmux.
A legacy `mux.backend = "herdr"` continues to hide ordinary not-started tool rows;
without explicit primary it still needs `create.enabled = true` for New.
The switch has no effect on creation through other primary backends.

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
requests. Use explicit New to create in the requested project. The inherited
`toggle`/`show`/`send` automatic selection may still attach to a sole matching
source in another directory. Use `:Sidekick cli select` for an explicit choice
between that source and New.
Selecting an existing row attaches that exact source, including one in another
directory. Terminal/tmux/zellij New refuses a session already registered under
the same Sidekick tool/cwd ID; select that session explicitly. Otherwise
tmux/zellij may reuse an existing mux session with the matching tool/cwd name.

Herdr New currently supports canonical interactive `claude` and `codex` tools
whose first command argument is exactly the matching executable name. It accepts `--model`
and Claude `--effort`; aliases such as `codex_new`, resume commands, wrappers,
prompt arguments, and environment unsets are unsupported. Choose the canonical
tool for New; legacy tmux tool rows keep their existing custom command behavior.

Selecting a named **New tool via backend in cwd** row authorizes that request
without a second confirmation. A tool-less New action and direct `new()` calls
still require confirmation after tool selection. Dismissing a picker before
authorizing the request creates no workspace or agent;
repeated selections while a request is pending reuse it. An uncertain startup
is retained for inspection and is not automatically retried. Its tool/cwd stays
reserved in that Neovim process while the outcome is unresolved. Inspect
`require("sidekick.cli.create").operations[id]`; `refresh(id)` only observes
startup again, and `cancel(id)` neither retries nor terminates resources. Existing live
sources remain selectable. A New selected during a send action cancels that send
payload instead of sending it to the newly created agent, with a notice to re-enter
it after attaching. Herdr attachments
require manual terminal input; automatic paste/submit remain disabled. Closing
the Sidekick window or attachment does not terminate the herdr agent.

When a herdr attach client exits with a nonzero or unknown status, Sidekick makes
bounded read-only calls (up to 1.5 seconds each, at most four calls) to the pinned
socket, with no server creation or reconnect fallback. A valid full pane inventory
that no longer contains the terminal produces a warning saying that the target
ended or was removed. The client status and diagnostic tail remain visible; this
does not establish an agent exit code or rule out a coincident transport failure.
Missing agents alone do not imply a missing terminal. Unknown/malformed snapshots,
server/socket/protocol/version mismatches and query failures remain errors.

Shell startup children may temporarily omit their cwd in herdr process metadata.
When the root shell's identity and cwd are verified and it owns the foreground
group, Sidekick can passively recheck such children within its existing startup
limit. It still requires a single fully identified shell and an empty supported
prompt before any executable probe or agent start. Persistent children, known
cwd mismatches, drafts and unknown shell owners leave the operation unresolved;
they never trigger input, a replacement workspace or a repeated agent start.

Creation journals include `timings` entries with fixed `stage` labels,
`elapsed_ms` and `duration_ms`; command records also include observed
`duration_ms`. Labels distinguish preflight, workspace creation, shell checks,
executable probe, agent startup, verification and attachment. Timing uses a
monotonic clock and excludes time spent in the confirmation picker. Command
durations include callback scheduling; they are observations rather than exact
child-process CPU/runtime measurements. Cancellation freezes elapsed time while
late replies retain their command durations. A later explicit `refresh()` adds
observation stages; total elapsed time then includes the gap since creation.
Timing fields contain no command arguments, prompts or environment values.

New preflight reads the local CLI version and validates the existing server's
socket/version/protocol immediately before workspace creation, without fetching
a full session snapshot. Later mutation and attachment checks remain fresh.
Presentation calls either `focus()` (which already shows and validates) or
`show()`, avoiding duplicate validation. A no-retry mock path uses 17 core CLI
calls, or 29 when modeling the normal attachment checks, plus the persistent
attach client. Watch/discovery callbacks and retries can add calls. This does
not remove herdr's own readiness waiting or establish live startup latency.

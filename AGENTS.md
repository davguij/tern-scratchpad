# Repository Guidelines

## Project Overview
`tern-scratchpad` is a small [Tern plugin](https://docs.stencil.so/tern/index.html) written in Luau (id `scratchpad`, v0.1.0). It started as the SDK's Getting Started sample (a `seq` command lens and a `hello` palette command) and now adds a Scratchpad notes block with Markdown capture.

## Architecture & Data Flow
A plugin has up to two halves, each in its own Luau VM ([Architecture](https://docs.stencil.so/tern/concepts/architecture.md)). They share no Lua state or messages and are wired only by `plugin.toml`.

| Half | File | Runs in | Owns | Budget per call |
| --- | --- | --- | --- | --- |
| Host | `host.luau` (`tern.context == "host"`) | Session daemon, one worker thread per plugin | Blocks, lenses, pane hooks, spawn filter, `tern.pane` | 2 s |
| Window | `window.luau` (`"window"`) | Every Tern window's UI thread | Commands, binds, overrides, routes, chrome, `tern.css`, `cx.layout` | 4 ms for chrome formatters and `available`; 50 ms otherwise |

- **`host.luau`** (`--!strict`): `tern.lens.define("seq", seq)` with a `LensDef<State>`:
  - `open` returns a fresh `{ values = {} }` per captured command.
  - `line` is called per output line; numeric lines are appended via `tonumber`, others are skipped.
  - `finish` is a no-op.
  - `view` returns `nil` when nothing is numeric, which keeps the raw output; otherwise it builds `ui.col` with `ui.text` (count and sum) and `ui.spark`.
- **`window.luau`**: `tern.command({ id = "hello", ... })`; `run(cx)` calls `cx:toast(...)` using `tern.runtime.jit` and `tern.plugin.name`.
- Nothing persists across runs: no `tern.kv`, `db` or async calls are used.
- `cx` is only valid inside the handler that received it; never store it.
- Both halves of a remote or iOS setup behave differently (iOS skips host entries; the web tab runs no Lua). See the [Support Matrix](https://docs.stencil.so/tern/concepts/support-matrix.md).

### Lens rules (the main pitfall)
Lenses are declared in the manifest and defined in Lua, and the two must agree ([Command Lenses](https://docs.stencil.so/tern/guides/lenses.md), [Packages and Manifests](https://docs.stencil.so/tern/concepts/packages.md)):
- Every `tern.lens.define("id", ...)` needs a matching `[[lenses]]` block (`id`, `match`) in `plugin.toml`. Defining an undeclared id raises; declaring one that is never defined fails the plugin load.
- `match` globs run against the program and its arguments joined by single spaces. `seq *` matches `seq 12` but not bare `seq`; list both (`["du", "du *"]`) to claim both.
- Claims are declarative and decided before any Lua runs, so `open` cannot decline. Return `nil` from `view` to show raw output instead.
- Only simple commands are lensed. Pipelines, `&&`/`;` lists, stdout redirection and subshells are not (`seq 12 | tail -3` stays plain). The shell must have Tern's integration active, and Settings › Terminal › Native command output must be on.
- Captures that go interactive (alternate screen) or exceed 16 MiB are aborted: no `finish`, state dropped.
- Order `[[lenses]]` from narrow to broad; the first plugin (by id) and the first lens (by manifest order) with a matching pattern wins.

## Key Directories
Flat repo, plus `scripts/` and `docs/plans/` (the Scratchpad plan). Gitignored local files: `.omp/` (agent config), `.env`, `database.db`. Don't read or commit them.

### Scratchpad block (`scratchpad.notes`)
- Notes live in one `tern.kv` key (`notes`, `{ next, items }`) in `<state>/plugin-data/scratchpad/kv.json`, outside any project, shared by every pane. Block state holds only view state (mode, selected id, caret); note text is read from the store each render.
- The block sets `features = { "edit" }`: Tern gives click-to-caret, selection and `edit` events (replace `from..to` with `text`, UTF-16 offsets), but typed text, Backspace, Delete and arrows still arrive as `key` calls and are applied by `editbuf.luau`. `undo` is not enabled. Note the published docs say plugin blocks advertise no features; the installed `tern.d.luau` and a headless probe show `edit` works.
- Controls share one handler (`act`) for keys and for pointer `actions = { click = "<act>=<value>" }`; `ev.act`/`ev.value` carry the split action.
- The `open` window command (palette, `cmd+alt+j`) calls `cx:new_block("scratchpad.notes")`.

## Development Commands
`package.json` has metadata only; there are no build, test, or lint scripts. Use the Tern CLI ([Getting Started](https://docs.stencil.so/tern/guides/getting-started.md), [CLI reference](https://docs.stencil.so/tern/reference/cli.md)):
- `tern plugin link .`: register this folder in place (writes `scratchpad.path` into `tern plugin dir`).
- `tern plugin list`: show load status (`ready`, or failures).
- `tern plugin reload`: reload manually; exits 1 if a plugin failed. Saving a file auto-reloads within about 300 ms.
- `tern plugin types .`: regenerate `tern.d.luau` (after Tern upgrades).
- Type-check from a shell:
  `luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau host.luau window.luau`
- Editor setup (`.vscode/settings.json`): `"luau-lsp.platform.type": "standard"`, `"luau-lsp.sourcemap.enabled": false`, `"luau-lsp.types.definitionFiles": { "@tern": "tern.d.luau" }`.
- Smoke test in a Tern pane: `seq 12` should render "12 numbers, sum 78" with a sparkline and a Raw toggle; `seq 3 x` should fall back to raw output.

## Code Conventions & Common Patterns
- Start Luau files with `--!strict` and a one-line comment naming the half (`-- The host half…`).
- Tabs for indentation. Types are PascalCase (`State`); locals are short and lowercase.
- Keep the lens local name, `tern.lens.define` id and manifest `id` identical. Plugin ids are `^[a-z][a-z0-9-]*$`, at most 32 characters.
- Annotate definitions with `LensDef<State>` / `BlockDef<State>` to type shared state; mutate the `open` state in place.
- Use the global `tern`; `require("tern")` works at runtime but luau-lsp flags it. `require` is confined to the package directory.
- Unused handler parameters are `_`-prefixed.
- Handlers are synchronous; keep them inside the budgets above and move long work into `tern.process.run` or timers.
- Use `tern.ui` builders in views and `cx:toast(level, title, body)` for feedback.
- Each API belongs to one half. When a guide and the [API Reference](https://docs.stencil.so/tern/reference/api.md) disagree, the reference (and `tern.d.luau`) wins. `tern.d.luau` is generated: don't hand-edit it.
- Manifest keys are strict: unknown keys fail the package. See the [Manifest Reference](https://docs.stencil.so/tern/reference/manifest.md).
- Known quirks: non-numeric lines are silently skipped; `tostring(sum)` of a float prints `3.0`; `tonumber` accepts `"0x1F"` and `"1e3"`.

## Important Files
- `plugin.toml`: manifest (schema 1, entries, `[[blocks]]`, `[[lenses]]`).
- `host.luau`, `window.luau`: the entry points. `notes.luau` (kv storage), `markdown.luau` (Markdown scanner to `decor` spans) and `editbuf.luau` (edit helpers and UTF-8/UTF-16 conversion) are host-side modules loaded with `require("./name")`.
- `scripts/smoke.sh`: headless smoke run.
- `tern.d.luau`: generated API types, the offline API reference.
- `package.json`: metadata only (MIT).

## Runtime/Tooling Preferences
Tern's embedded sandboxed Luau VM (native codegen is optional; see `tern.runtime.jit` and [Runtime, Budgets, and JIT](https://docs.stencil.so/tern/concepts/runtime.md)). No Node, Bun or Python runtime and no dependencies. The CLI is `tern`; type-checking uses [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp).

Security ([Trust and Security](https://docs.stencil.so/tern/concepts/security.md)): a plugin runs as the user with full file, process and network access (`tern.fs`, `tern.process`, `tern.fetch`). Plugins start running as soon as they are linked or installed. Keep new code minimal in what it reads and sends, and never write secrets to `tern.plugin.data` (`<state>/plugin-data/<id>/`, a plain-file store shared with `tern.kv`).

## Testing & QA
There are no automated tests, linters or CI. QA is: `luau-lsp analyze` (above), `tern plugin list` to confirm it loads, and manual runs of `seq` and the `hello` palette command. For lens changes, also test a short run and a non-numeric run.

`scripts/smoke.sh` is the repeatable check for the Scratchpad block. It starts a headless `tern serve`, loads this repo as the plugin through a throwaway `STENCIL_FIXTURE_ROOT` (headless runs load plugins only via `plugins fixtures`, which reads `<root>/../plugins/fixtures/<plugin dir>`), drives keys with `tern ctl`, checks the visible tree, and backs up and restores the plugin's `kv.json`. `tern ctl type` takes one argument, so the script quotes the text itself. Not covered: clipboard paste (no `ctl` paste command), so test paste by hand in a real window.

## Documentation Links
Pages are also published as Markdown at the same path with `.md` instead of `.html`, which is the best form for agents.
- [Tern Plugin SDK index](https://docs.stencil.so/tern/index.md)
- [Getting Started](https://docs.stencil.so/tern/guides/getting-started.md)
- [Command Lenses](https://docs.stencil.so/tern/guides/lenses.md)
- [Blocks](https://docs.stencil.so/tern/guides/blocks.md) and [Views (`tern.ui`)](https://docs.stencil.so/tern/guides/views.md)
- [Commands, Keys, and Overrides](https://docs.stencil.so/tern/guides/commands.md)
- [Host Hooks](https://docs.stencil.so/tern/guides/hooks.md)
- [Architecture](https://docs.stencil.so/tern/concepts/architecture.md)
- [Packages and Manifests](https://docs.stencil.so/tern/concepts/packages.md)
- [Trust and Security](https://docs.stencil.so/tern/concepts/security.md)
- [API Reference](https://docs.stencil.so/tern/reference/api.md)
- [Manifest Reference](https://docs.stencil.so/tern/reference/manifest.md)
- [Elements](https://docs.stencil.so/tern/elements/index.md) and [Styling Views](https://docs.stencil.so/tern/styles/index.md)
- [Example plugins](https://docs.stencil.so/tern/examples/index.md) and the [tern-sdk repo](https://github.com/stencil-hq/tern-sdk)

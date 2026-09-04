# Process Monitor

An Omarchy Quattro bar widget that shows **real** per-process-tree RAM usage — including all children — with an expandable tree explorer and one-click process killing.

`ps` and `htop` show you the parent's 2 MB while its 20 children eat 800 MB. This widget sums whole trees, so `zen-bin` with 16 tabs shows its real ~800 MB, not just the parent.

## Features

- Bar pill with live RAM usage % (green → yellow → orange → red)
- Top memory consumers ranked by **true tree-aggregated RSS**
- Wrapper chains collapse (`foot → zsh → opencode` becomes one `opencode` row)
- Click any row to expand its children, recursively (grandchildren load on demand)
- Per-process kill buttons with SIGTERM / SIGKILL confirmation
- Tree-kill: killing a row signals the whole subtree, not just the parent
- Processes owned by other users (e.g. root) kill via `pkexec` + polkit
- `init` (PID 1) can never be killed from here
- Live text filter, keyboard navigation (`j/k`, `Enter`, `Space`, `Esc`)
- Refreshes every 2 seconds (configurable)

## Requirements

- Omarchy Quattro (Quickshell shell)
- `python3` (standard library only, no dependencies)
- `pkexec` + a polkit agent (optional — only needed to kill other users' processes)

## Install

```bash
omarchy plugin add https://github.com/markbus-ai/omarchy-process-monitor --enable
omarchy bar add markbusking.process-monitor --section right
```

## Settings

- `refreshInterval` — refresh period in ms (default `2000`)
- `topCount` — top processes shown (default `15`)

## Usage

- Click a row to expand/collapse its process tree
- Click `✕ Kill` (or right-click / double-click a row) for the kill dialog:
  - **SIGTERM** — graceful, lets the process clean up
  - **SIGKILL** — force, immediate
  - Killing a row signals its whole subtree and reports the process count
- Type to filter by name, PID, user, or command line

## How the numbers work

Each row shows its subtree's total RSS (parent + all descendants), with the process's own RSS underneath. Sibling wrapper chains collapse to the heaviest node so shared RAM isn't triple-counted. Values match what you'd get summing `VmRSS` across the tree in `/proc`.

## Removal

```bash
omarchy bar remove markbusking.process-monitor
omarchy plugin remove markbusking.process-monitor --yes
```

## Security notes

- The widget only **reads** `/proc` (RSS, command lines, usernames) to build the tree. Reads are byte-capped and control characters are stripped before display.
- Killing is always user-initiated behind a confirmation dialog showing PID, owner and tree size.
- Own processes: signaled directly after revalidating each PID's identity (`comm` + starttime), so recycled PIDs are skipped, never killed by mistake.
- Other users' processes: `pkexec` runs only the system interpreter with an inline, non-writable program that revalidates identity after authorization and immediately before each signal. Repository code is never executed as root.
- PID 0/1/2 (including `init`) can never be targeted, from UI or script.
- All subprocesses use absolute binary paths (`/usr/bin/python3`, `/usr/bin/kill`, `/usr/bin/pkexec`), carry a 12 s watchdog with teardown cleanup, and produce size-bounded output (clamped top-N, capped children, schema-validated before display).

## License

MIT. See [LICENSE](LICENSE).

<p align="center">
  <img src="./Branding/logo-1024.png" width="22%" alt="ServerIsland Logo">
</p>
<p align="center">
  <strong>English</strong>
  &nbsp;·&nbsp;
  <a href="./README.zh-CN.md">简体中文</a>
  &nbsp;·&nbsp;
  <a href="https://zhyan0603.github.io/ServerIsland/">Website</a>
  &nbsp;·&nbsp;
  <a href="https://zhyan0603.github.io/ServerIsland/manual.html">Guide</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/zhyan0603/ServerIsland/releases/latest">Download</a>
  &nbsp;·&nbsp;
  <a href="./CONTRIBUTING.md">Contributing</a>
</p>
<p align="center">
  <a href="https://github.com/zhyan0603/ServerIsland/releases"><img src="https://img.shields.io/github/v/release/zhyan0603/ServerIsland?label=Version&style=flat-square&color=brightgreen" alt="Version"></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-blue?style=flat-square" alt="License"></a>
  <a href="https://github.com/zhyan0603/ServerIsland/releases/latest"><img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple" alt="macOS 14+"></a>
  <a href="https://github.com/zhyan0603/ServerIsland/releases/latest"><img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?style=flat-square" alt="Windows 10 / 11"></a>
  <a href="https://github.com/zhyan0603/ServerIsland/releases/latest"><img src="https://img.shields.io/badge/Linux-x64-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Linux x64"></a>
  <a href="https://github.com/zhyan0603/ServerIsland/releases"><img src="https://img.shields.io/github/downloads/zhyan0603/ServerIsland/total?style=flat-square&color=red&label=Downloads" alt="Downloads"></a>
  <a href="https://github.com/zhyan0603/ServerIsland/stargazers"><img src="https://img.shields.io/github/stars/zhyan0603/ServerIsland?style=flat-square&color=yellow&label=Stars" alt="Stars"></a>
  <a href="https://github.com/zhyan0603/ServerIsland/graphs/contributors"><img src="https://img.shields.io/github/contributors/zhyan0603/ServerIsland?style=flat-square&color=brightgreen&label=Contributors" alt="Contributors"></a>
</p>

<p style="text-align: justify;"><strong>ServerIsland</strong> puts your remote computations in the MacBook notch — and, on Windows and Linux, at the top of your screen or on your desktop. It watches Slurm and PBS clusters and plain Linux servers over SSH and shows your jobs, GPUs and the <em>live progress</em> of VASP, LAMMPS, GPUMD and NEP runs in a Dynamic-Island-style panel — with nothing installed on the server. It is built for people who spend their days in computational materials science, chemistry and physics, and are tired of typing <code>squeue</code> and <code>tail -f</code> every twenty minutes.</p>

<p align="center">
  <a href="https://zhyan0603.github.io/ServerIsland/"><img src="./docs/hero-en.png" width="100%" alt="ServerIsland: the collapsed notch, a 'NEP training finished' alert, and the expanded panel with one card per server"></a>
</p>
<p align="center">▶ <a href="https://zhyan0603.github.io/ServerIsland/manual.html#video-guide">Watch the 3-minute video tour</a></p>

> **Customized build rebased on upstream v0.3.0.** Local Actions, deployment progress/rules, Docker monitoring/control/logs, favorites and UI changes are preserved. Upstream version checks remain available; installing the official binary over this build is blocked. Future upgrades require merging source and rebuilding.

## Features

- **Every Server at a Glance**: Hover the notch to see one card per server — running / pending counts, CPU, memory and GPUs. Idle servers fold into a single line.
- **Real Progress, Not Just "RUNNING"**: Detects NEP, GPUMD, VASP and LAMMPS from the job's working directory and shows progress, speed and ETA, plus loss curves and, for VASP relaxations, energy and max-force curves.
- **Slurm and PBS Done Right**: Job arrays as one segmented bar, pending reasons in plain words, free CPUs / GPUs / DCUs per Slurm partition, and 7 days of history with each job's folder. PBS Pro, OpenPBS and Torque work too.
- **Only What You Care About**: Limit a server to jobs and processes under certain folders, e.g. `~/projects/LLZO`.
- **Alerts You Can Hear**: A notch pop-up with distinct sounds for success and failure — it can tell a clean finish from an early exit even without Slurm accounting.
- **Your Own Programs, Too**: Write a custom rule (a file name + a keyword or regex) and test it against a real directory right from Settings.
- **Zero Footprint**: No agent, no daemon, no root. One SSH channel per server per poll, reusing a single connection; your `~/.ssh/config` just works — or type the address, user, port and key into Settings if you never wrote one.
- **Any Login**: Key, password, key + password, or one-time codes, optionally through one or more jump hosts — each hop asks and reports errors on its own.
- **Safe by Default**: Cancelling is off unless enabled per server, and then needs a long press, a confirmation and a server-side re-check. Passwords and one-time codes are typed into a native dialog and not stored by default; tick “Remember” to keep a password in the system keychain (one-time codes are never stored).
- **Tako**: A pixel octopus lives in the notch — busy while jobs run, happy when they finish, red when something breaks.

## Supported Software

| Software | Detected from | What you see |
|---|---|---|
| **NEP / GNEP** | `loss.out` + `nep.in` / `gnep.in` | generation, losses, speed, ETA, loss curve |
| **GPUMD** | `run.in` + `neighbor.out` / `thermo.out` | steps, speed, ETA |
| **VASP** | `INCAR` + `OSZICAR` | MD as a percentage · relaxation as ionic steps with an energy curve · SCF as electronic steps |
| **LAMMPS** | `log.lammps` | steps of the last `run`; `Total wall time` marks a clean finish |
| **Anything else** | a custom rule | any *current / total* your program writes, e.g. `epoch 37/100` |

Detection only reads file tails. If anything doesn't look as expected, ServerIsland shows **nothing rather than a wrong number**. Missing your package? [Adding a detector](./CONTRIBUTING.md) is a great first contribution.

## Installation

Download the package for your platform from **[Releases](https://github.com/zhyan0603/ServerIsland/releases/latest)**. No account, no extra runtime, and nothing to install on your servers.

| Platform | Download | Requirements |
|---|---|---|
| **macOS** | `ServerIsland-x.y.z.dmg` | macOS 14+, Apple silicon or Intel |
| **Windows** | `ServerIsland-x.y.z-win-x64.zip` | Windows 10 / 11, 64-bit |
| **Linux** | `ServerIsland-x.y.z-linux-x64.tar.gz` | x64, X11 or XWayland, a system tray |

- **macOS**: open the DMG and drag **ServerIsland** into Applications. It isn't notarized by Apple, so the first launch is blocked once: on macOS 15+, open it, then click **Open Anyway** in *System Settings → Privacy & Security*; on macOS 14, Control-click the app and choose **Open**.
- **Windows**: unzip anywhere and double-click `ServerIsland.exe`. If you see "Windows protected your PC", click **More info → Run anyway**.
- **Linux**: `tar xzf ServerIsland-*.tar.gz && ./ServerIsland`. On GNOME, install the AppIndicator extension so the tray icon shows up.

On Windows and Linux there's no notch: ServerIsland hangs from the top center of the screen, or lives on your desktop as Tako the pet (*Settings → General → Display Style*), with a tray icon either way.

## Usage

1. On first launch, the settings window opens. Click **Add Server** and pick hosts from your `~/.ssh/config`.
2. Choose **Slurm**, **PBS** or **Direct** for each server (or let ServerIsland detect it).
3. That's it — hover the notch (or the island / Tako on Windows and Linux).

The home host memory indicator normally shows used/total capacity; clicking toggles capacity and percentage without hover changes. Resource colors are green below 60%, cyan from 60% to below 70%, amber from 70% to below 85%, and red from 85%. When no GPU is displayed, the Disk toggle enables GPU-style vertical disk columns even at low usage. Each mount gets a visible light-grey full-height track with bottom-up fill proportional to actual usage. Clicking the disk indicator toggles percentage and used/total capacity in GB or TB; the summary refers to the highest-usage disk when multiple disks are present. GPU displays keep their existing area.

All scrollable controls inside the Mac island use approximately 4pt, higher-contrast grey scrollbars, including vertical lists and horizontal logs. They remain visible while content overflows instead of fading as overlay scrollers do, and hide when scrolling is unnecessary. Native scrolling and dragging are preserved; Settings windows retain their system scrollbars.

Want to look around first? Start the demo with fake servers: `open /Applications/ServerIsland.app --args --demo` on macOS, `ServerIsland.exe --demo` on Windows, `./ServerIsland --demo` on Linux.

The **[User Guide](https://zhyan0603.github.io/ServerIsland/manual.html)** covers logins with passwords / one-time codes, alerts, custom progress rules and troubleshooting; the **[Feature Tour](https://zhyan0603.github.io/ServerIsland/features.html)** explains everything ServerIsland does.

<details>
<summary><b>Docker container metrics (Mac)</b></summary>

Docker display is enabled by default for newly added servers on Mac; turn it off under **Settings → server → Display → Docker** if needed. Existing servers keep their saved settings. The server card shows container state, CPU and memory using the existing task row style; click a container for health, image, Compose service, ports, PIDs, network and block I/O totals and rates, or choose **Show All**. Collection follows the server's polling and pause settings.

The card and Show All offer independently saved per-server List/Grid layouts; sorting remains shared and uses a small grey menu icon. Show All displays its running/total count after the server name on the second line, matching the Watch a Process subtitle layout. The home card hides stopped/inactive containers; Show All sorts them after active containers in every sort mode. Grid uses a separate grid for stopped containers, starting a new row without filling the active group’s last row. Existing configurations retain their previous layout at both entry points. Default order uses the latest lifecycle change or creation time; resource, CPU and memory-ratio sorting are available. Docker's original STATUS is shown in grey. Details show CPU and memory in two columns on the first row, with bars filling the remaining width before percentage labels. Network RX, network TX, block read and block write occupy four columns on the second row. Each cell has two lines: title and secondary information above the value, with inline bars before percentages. CPU, memory, network and block I/O charts are displayed together in a fixed-height 2×2 grid with shared 1m/3m/5m/10m buttons (default 3m) and independent point selection. The detail page and live chart axes redraw every second. The range selector is isolated and updates only when its selected range or labels change, with refresh animations disabled. While a container detail is open, a separate loop requests new metrics only for that container at a one-second target cadence, independent of background polling settings. Requests are serialized; slower SSH/Docker responses reduce the actual rate. Leaving the detail cancels future requests and discards late results. A late background sample cannot overwrite a newer detail sample. History contains actual samples from this app session, capped at 600 points and six hours per container. Recent changes use the daemon's finite event history and fall back to creation time.

Both List and Grid container entries on the home page and Show All use the same subtle white hover highlight as running tasks.

Visible home cards refresh the Docker list immediately and then every three seconds, stopping when the home view is hidden. Automatic updates show no loading indicator; only a manual Refresh does, waiting for an in-flight list read before issuing its own request. Show All has a header search field matching the All Jobs style. Search container names, IDs, images and Compose project/services; space-separated terms may match across fields. Filtering is local, applies to List/Grid, retains favorites and state grouping, and preserves the query when returning from detail. A fixed placeholder avoids focus-dependent baseline changes. Typing in the open list focuses search and forwards the original key event to the native editor, preserving the first character and IME composition. Shortcuts, menus and existing text focus are excluded; the local event monitor is removed when leaving the list.

While Show All is open, a separate roughly one-second loop reads only the current host’s Docker container list and state. Its Refresh button uses the same lightweight request, without host resource/job polling or per-container stats/inspect/events. Existing resource samples are preserved; opening a container switches to its detail sampler. Closing the page cancels the list loop, and late global responses cannot roll back newer list membership or state.

Container detail adds restart, stop and terminal icons before Refresh, with Start shown for stopped containers. Start/stop/restart use a translucent frosted-glass, arrowed confirmation bubble (with a shared backdrop-blur material for the card and arrow, keeping text and buttons sharp) anchored below the clicked icon, matching the island typography, rounded corners and action colors. It shows the target container and service impact; Cancel, an outside click or a target state change dismisses it. Only Confirm executes the action, rechecking the full container ID before sending the request. Timed-out operations are not replayed automatically. PIDs and sample time sit beside the Metrics/Runtime Logs tabs, and Config.Cmd is displayed below Ports, falling back to ENTRYPOINT when CMD is unset or empty. The terminal entry uses the system default `.command` file association, reuses SSH/jump-host settings and requires a remote docker CLI plus sh in the container (bash is preferred when available).

A terminal icon beside Refresh Logs captures the currently selected 200/500-line limit when clicked, opens the system default terminal association and runs Docker logs with that initial tail plus continuous following.

The Runtime Logs tab reads the last 200/500 stdout and stderr lines, including multiplexed and TTY output. Optional auto-refresh uses a one-second target cadence only while the tab is visible, serializes requests and retries transient failures with bounded backoff. Authentication errors, unsupported logging drivers and removed containers stop retries with an explanatory error. Logs remain in page memory, are capped at 128 KiB with truncation indicated, and common credential patterns are masked.

The bundled collector runs temporarily over the existing SSH stdin channel, using GET requests to the Docker Engine Unix socket. No monitoring script is installed on the server. Requires remote `python3` and socket access for the SSH user. Supports `/var/run/docker.sock`, `DOCKER_HOST=unix:///path/to/docker.sock` and rootless sockets; errors are shown without changing permissions or elevating privileges. CPU percentages, bars, sorting and charts use the container's effective hard limit (NanoCpus, CFS quota/period, cpuset); raw 107.3% with a two-core limit displays 53.65%. Without a hard limit, 100% means one core and the bar fills at 100%, without dividing by host core count. Tooltips explain the basis and retain the raw Docker reading. CPU shares are weights, not hard limits; inspect exports only resource fields. Memory uses the smaller valid container/daemon limit, with unlimited or unknown limits explained in tooltips. Linux memory excludes cache following [Docker stats](https://docs.docker.com/reference/cli/docker/container/stats/), and I/O rates require two consecutive samples. Unavailable values show `—`. Each poll lists up to 200 containers and samples the first 16 running containers with at most four concurrent requests; the details page indicates limits. Containers do not count as compute jobs or produce job completion alerts.

`python3 remote/test_docker_monitor.py` tests a temporary mock Unix socket only. Swift and the cross-platform core share `remote/docker-monitor.py`; the cross-platform container UI is not implemented yet.
</details>

<details>
<summary><b>Report progress from your own scripts</b></summary>

Besides custom rules, any script can write a one-line JSON file to `~/.serverisland/progress/<name>.json` on the server:

```json
{"name": "train", "progress": 0.62, "message": "epoch 62/100", "jobid": "8812044"}
```

Entries with a `jobid` are merged into that Slurm job. [`remote/si-progress`](./remote/si-progress) is a ready-made helper:

```bash
si-progress train 0.42 "epoch 3/10"
si-progress train done
```

**Mac local Actions (recommended):** Settings → server → Actions lets you save a name, Bash script and Local/Server target. Saving does not execute anything. Click the named button on the right of the server card to run; busy Actions are disabled. Buttons use the width remaining beside the host metrics; only entries that do not fit move into an ellipsis menu, which shows Action names only. Settings Test run also accepts disabled Actions without enabling their shortcuts; empty scripts and duplicate runs remain blocked. Local runs the full script on your Mac, including any ssh command. Server uses the host's configured SSH connection, jump hosts and preamble; paste only the remote script.

Both modes use the wrapper bundled in the Mac app and keep progress on your Mac. No monitoring script or progress file is installed on the server. Python 3.8+ is required locally. Scripts use Bash with `set -e` and `pipefail`. Script text is stored in local settings; provide credentials through existing environment/key management.

The CLI also supports `si-deploy run --local --host demo-host --name demo-frontend -- ssh demo-host 'cd /opt/my-app && bash deploy.sh frontend'`. The host matches a configured alias or UUID; unmatched tasks appear in a Local tasks card. State lives under `~/.serverisland/local/progress/` with an independent run ID per execution; completed archives live in `local/deployments/`. Local collection runs every second even if remote polling is paused. SSH 255 and known SSH transport interruption report an unknown remote result, never an inferred remote deployment failure. Existing Actions are not replayed on app launch. The cross-platform core preserves the Action schema and reads local state; its Action configuration/buttons are not yet implemented.

**Legacy remote reporting:** [`remote/si-deploy`](./remote/si-deploy) can still wrap a command on the monitored server using the existing progress-file interface (Python 3.8+, standard library only). Copy it to `~/bin/si-deploy` on that server, make it executable, and run as the same user that ServerIsland monitors:

```bash
~/bin/si-deploy run --name demo-api -- bash deploy.sh
```

Enable progress-file reading in the host's settings. It reports phase, phase duration, quiet time, heartbeat and final result; recognizes common pull/build/start/health/post-deploy/cleanup headings and pip/npm activity; and preserves stdout, stderr and exit code. The bar measures **phase completion, not time**. Unrecognized phases and dependency installation do not get a fabricated percentage or ETA. Custom `--rules` JSON contains `{"stages":[{"name":"Build","pattern":"^Building image"}]}`. Rules are best-effort: use explicit hooks inside the wrapped script for accurate branching:

```bash
si-deploy stage 2 6 "Build image"
si-deploy detail "Installing npm dependencies"
```

The first hook overrides automatic phase detection; `run --manual` disables it from the start. `stage --fraction 0.5` reports measurable progress within a phase. Only a zero exit from the **whole script**, including post-processing, marks success. Health failures swallowed by the original script cannot be detected independently. Monitoring write failures warn without changing the child's result. Same-name runs are locked; different names run independently.

Compact state stays below the app's 4 KB read limit in `~/.serverisland/progress/deploy-<name>.json`; completed phase records are stored separately in `~/.serverisland/deployments/<run_id>.json` without automatic cleanup. Raw logs, commands and environment variables are not persisted; hook labels must not contain credentials. No daemon, open port or disconnection protection is added: keep using tmux/systemd when needed. SIGKILL/power loss cannot publish a final result. Existing alerts require the app to observe both running and terminal states. Run local integration checks with `python3 remote/test_si_deploy.py`. See the [Chinese usage notes](./README.zh-CN.md) for setup and limitations.
</details>

## How It Works

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./docs/architecture-dark.png">
    <img src="./docs/architecture-light.png" width="860" alt="How ServerIsland works: the Mac polls each server over one SSH channel; the server runs a short read-only bash script and answers with plain-text sections">
  </picture>
</p>

On macOS and Linux, ServerIsland uses the system `ssh` with a shared connection and `BatchMode=yes`; on Windows it keeps one connection per server with a built-in SSH client that reads your `~/.ssh/config` and `known_hosts`. Either way it never hangs on a password prompt in the background, and it backs off exponentially on errors so it never trips fail2ban. Slurm sees one `squeue -u $USER` per poll and a single `sacct` when a job leaves the queue. Everything stays on your computer — no account, no cloud, no telemetry.

## Screenshots

<table>
  <tr>
    <td width="50%" align="center"><img src="./docs/screenshots/en/expanded.png" alt="The expanded panel with one card per server"><br><sub><b>Every server at a glance</b> — one card per server; idle ones fold into a line</sub></td>
    <td width="50%" align="center"><img src="./docs/screenshots/en/alerts.png" alt="A finished alert and a failed alert"><br><sub><b>Alerts</b> — one sound when a job finishes, another when it fails</sub></td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="./docs/screenshots/en/detail-nep.png" alt="NEP training detail with a live loss curve"><br><sub><b>NEP training</b> — progress, ETA, a live loss curve and the log tail</sub></td>
    <td width="50%" align="center"><img src="./docs/screenshots/en/detail-vasp-relax.png" alt="VASP relaxation with energy and max-force curves"><br><sub><b>VASP relaxation</b> — energy and max force against your EDIFFG target</sub></td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="./docs/screenshots/en/detail-neb.png" alt="VASP NEB energy profile and barrier"><br><sub><b>VASP NEB</b> — the energy profile and how the barrier converges</sub></td>
    <td width="50%" align="center"><img src="./docs/screenshots/en/partitions.png" alt="Free CPUs and GPUs per Slurm partition"><br><sub><b>Free resources</b> — where can my job start right now?</sub></td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="./docs/screenshots/en/history.png" alt="History of finished jobs with their folders"><br><sub><b>7-day history</b> — finished jobs, exit codes and their folders</sub></td>
    <td width="50%" align="center"><img src="./docs/screenshots/en/settings-rule-editor.png" alt="Custom progress rule editor with a Test button"><br><sub><b>Custom rules</b> — a file and a keyword, then hit Test</sub></td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="./docs/screenshots/en/settings-host.png" alt="Server settings: type, connection, jump host and login"><br><sub><b>Any login</b> — key, password, one-time code, jump hosts</sub></td>
    <td width="50%" align="center"><img src="./docs/screenshots/en/windows-pet.png" alt="Tako on a Windows desktop with the floating panel"><br><sub><b>Windows &amp; Linux</b> — a virtual island, or Tako on your desktop</sub></td>
  </tr>
</table>

## Roadmap

- [x] Slurm, direct servers, GPUs, job arrays, pending reasons, partitions
- [x] NEP / GNEP, GPUMD, VASP and LAMMPS detection, custom rules
- [x] Loss / energy / max-force curves in job details
- [x] PBS (PBS Pro / OpenPBS / Torque), folder filters, log retention
- [x] Windows and Linux versions
- [x] Display selection on multi-monitor setups
- [x] One-click updates, server reordering, a terminal button on each card
- [ ] More packages: CP2K, Quantum ESPRESSO, ABACUS, Gaussian, ORCA
- [ ] LSF

## Contributing

Bug reports, ideas and pull requests are welcome, in English or Chinese — see [CONTRIBUTING.md](./CONTRIBUTING.md), which also explains how to build from source. The developer docs ([`AGENTS.md`](./AGENTS.md), [`references/`](./references/)) cover the architecture, the remote script protocol and how to add a new simulation package. If ServerIsland saves you a few `ssh` round-trips a day, a ⭐ helps others find it.

## Contact

Questions, feedback or ideas? Please [open an issue](https://github.com/zhyan0603/ServerIsland/issues) so others can find the answer too, or email **Zihan Yan** at [yanzihan@westlake.edu.cn](mailto:yanzihan@westlake.edu.cn).

## Acknowledgements

Notch interaction inspired by [Pulse](https://github.com/jsattler/Pulse), [claude-island](https://github.com/farouqaldori/claude-island), [open-vibe-island](https://github.com/Octane0411/open-vibe-island) and [boring.notch](https://github.com/TheBoredTeam/boring.notch). Agent-free SSH monitoring ideas from [VRAMRadar](https://github.com/XinbaoQiao/VRAMRadar), [NVBeacon](https://github.com/jaein4722/NVBeacon) and [RemoteGPU-Bar](https://github.com/ZeyuuuChen/RemoteGPU-Bar). NEP / GPUMD progress logic follows [GPUMDkit](https://github.com/zhyan0603/GPUMDkit).

## License

Copyright © 2026 Zihan Yan and ServerIsland contributors. ServerIsland is free software released under the [GNU General Public License v3.0](./LICENSE): you may use, modify and redistribute it, and any modified version you distribute must also be open source under the GPL.

# Changelog

## v0.3.0 — 2026-10-19

- **One-click updates**: "Update to v…" downloads the new version, checks its SHA-256 against GitHub, replaces the app and reopens it (macOS, Windows and Linux). Updating from v0.2.0 or earlier still has to be done by hand once.
- **Reorder servers**: drag them in the Settings sidebar or right-click → Move to Top / Up / Down / Bottom; the island uses the same order
- **Terminal button** on every server card in the island: one click opens an ssh session (reusing the kept-alive connection)
- **Lighter on your servers**: one `squeue` / `qstat` call per refresh instead of three, one pass over your processes, one fewer `nvidia-smi`; disk usage is checked every 5 minutes; VASP / LAMMPS / GPUMD / custom-rule folders whose files haven't changed aren't re-read
- **History** kept for 7 days (was 24 hours) with each job's folder, copy and "Open in Terminal"; jobs that ended while ServerIsland was closed are recorded on the next launch; Clear History in Settings
- **Choose the screen** the island shows on (Settings → General)
- **DCU / NPU / MLU** in the partition view; a clear `chmod 600` hint when ssh rejects a private key because of its permissions
- **VASP**: VTST-aware max force; NEB energy profile and barrier
- Faster tooltips; a Quit button in Settings

## v0.2.0 — 2026-10-18

- **Windows and Linux** versions (virtual island at the top of the screen, or a desktop pet; tray icon)
- **PBS clusters** (PBS Pro / OpenPBS / Torque): jobs, arrays, pending reasons, final states, hold-to-cancel with `qdel`
- **More ways to log in**: key, password, key + password, or one-time code; enter the address, user, port and key file without `~/.ssh/config`; jump hosts (multi-hop, each hop asks and reports errors on its own)
- **Remember password** (off by default): stored only in the macOS Keychain / Windows Credential Manager / Linux keyring, used to reconnect automatically
- **Only these folders**: limit a server to jobs and processes under given directories
- **VASP relaxations**: max-force curve next to the energy curve, with the EDIFFG target as a dashed line
- **Diagnostic log retention** (7 days by default) and a Clear Log button
- **Check for Updates** in Settings → General, plus an optional daily check that tells you when a new release is on GitHub

## v0.1.0 — 2026-10-17

First public release.

- One card per server in the notch: running / pending counts, CPU, memory and GPUs; idle servers fold into one line
- Slurm: jobs, job arrays as segmented bars, plain-language pending reasons, free resources per partition, 24-hour history (`sacct` with a local fallback)
- Direct servers: filtered processes, GPU processes, watch any PID
- Progress, speed and ETA for NEP / GNEP, GPUMD, VASP and LAMMPS; loss and energy curves in job details
- Custom progress rules with a read-only Test button
- Alerts with distinct sounds for finished and failed jobs; per-server mute and pause
- Job details with live log tail; opt-in, long-press-and-confirm cancelling with a server-side re-check
- Password / OTP clusters via a native dialog, with connection keep-alive
- English and Chinese UI

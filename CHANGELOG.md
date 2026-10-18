# Changelog

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

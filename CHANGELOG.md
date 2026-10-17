# Changelog

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

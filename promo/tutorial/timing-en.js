// 由 audio.py 生成，不要手改：每句旁白的起止时间（秒）、各章节的范围、音效时刻。
window.TIMING_EN = {
 "chapters": [
  {
   "id": "hook",
   "title": "",
   "from": 0.0,
   "to": 19.65
  },
  {
   "id": "add",
   "title": "Add a Server",
   "from": 19.65,
   "to": 51.989
  },
  {
   "id": "notch",
   "title": "The Notch & Cards",
   "from": 51.989,
   "to": 76.692
  },
  {
   "id": "slurm",
   "title": "Slurm Clusters",
   "from": 76.692,
   "to": 98.518
  },
  {
   "id": "direct",
   "title": "PBS & Direct Servers",
   "from": 98.518,
   "to": 113.718
  },
  {
   "id": "apps",
   "title": "Simulation Progress",
   "from": 113.718,
   "to": 139.903
  },
  {
   "id": "alerts",
   "title": "Alerts & Safety",
   "from": 139.903,
   "to": 159.703
  },
  {
   "id": "new",
   "title": "New in v0.3.0",
   "from": 159.703,
   "to": 179.485
  },
  {
   "id": "cross",
   "title": "Windows / Linux",
   "from": 179.485,
   "to": 190.599
  },
  {
   "id": "outro",
   "title": "",
   "from": 190.599,
   "to": 200.678
  }
 ],
 "lines": {
  "h1": {
   "start": 1.4,
   "dur": 4.239,
   "end": 5.8,
   "text": "Meet ServerIsland — a tiny octopus that lives in your Mac's notch.",
   "chapter": "hook"
  },
  "h2": {
   "start": 6.75,
   "dur": 2.668,
   "end": 10.35,
   "text": "When a job finishes, it lets you know with a chime;",
   "chapter": "hook"
  },
  "h3": {
   "start": 10.7,
   "dur": 3.574,
   "end": 14.9,
   "text": "hover over it, and every job on every server is right there.",
   "chapter": "hook"
  },
  "h4": {
   "start": 15.85,
   "dur": 2.044,
   "end": 19.25,
   "text": "Let's walk through it in about three minutes.",
   "chapter": "hook"
  },
  "a1": {
   "start": 20.45,
   "dur": 2.023,
   "end": 23.45,
   "text": "Open Settings and click Add Server.",
   "chapter": "add"
  },
  "a2": {
   "start": 23.8,
   "dur": 2.966,
   "end": 27.4,
   "text": "Hosts in ~/.ssh/config can be picked right away;",
   "chapter": "add"
  },
  "a3": {
   "start": 27.75,
   "dur": 4.266,
   "end": 32.35,
   "text": "otherwise, enter the address, user, port and key file.",
   "chapter": "add"
  },
  "a4": {
   "start": 32.7,
   "dur": 7.121,
   "end": 39.821,
   "text": "There are four ways to log in: key, password, key plus password, or a one-time code — and you can go through a jump host.",
   "chapter": "add"
  },
  "a5": {
   "start": 40.171,
   "dur": 4.222,
   "end": 45.171,
   "text": "After adding it, click Detect Type: it works out whether it's a cluster.",
   "chapter": "add"
  },
  "a6": {
   "start": 45.521,
   "dur": 5.967,
   "end": 51.489,
   "text": "For servers that need a password, click Log In once; the connection is kept alive in the background.",
   "chapter": "add"
  },
  "n1": {
   "start": 52.789,
   "dur": 6.953,
   "end": 59.742,
   "text": "Normally, two small wings peek out of the notch: Tako and the running count on the left, progress on the right.",
   "chapter": "notch"
  },
  "n2": {
   "start": 60.092,
   "dur": 6.101,
   "end": 66.492,
   "text": "Tako's mood follows your servers: busy, napping in the queue, happy when done, dizzy on errors.",
   "chapter": "notch"
  },
  "n3": {
   "start": 66.842,
   "dur": 5.218,
   "end": 72.442,
   "text": "Hover to expand: one card per server, with jobs and resources at a glance.",
   "chapter": "notch"
  },
  "n4": {
   "start": 72.792,
   "dur": 3.054,
   "end": 76.192,
   "text": "Servers with nothing running fold into a single line.",
   "chapter": "notch"
  },
  "s1": {
   "start": 77.492,
   "dur": 5.277,
   "end": 82.768,
   "text": "Job arrays become one row: green is done, red is failed, blue is running.",
   "chapter": "slurm"
  },
  "s2": {
   "start": 83.118,
   "dur": 2.514,
   "end": 86.718,
   "text": "Pending jobs tell you why, in plain words.",
   "chapter": "slurm"
  },
  "s3": {
   "start": 87.068,
   "dur": 3.492,
   "end": 92.068,
   "text": "The grid icon shows the free resources in every partition;",
   "chapter": "slurm"
  },
  "s4": {
   "start": 92.418,
   "dur": 5.519,
   "end": 98.018,
   "text": "the clock icon opens history: the last seven days of jobs, with their status and folders.",
   "chapter": "slurm"
  },
  "p1": {
   "start": 99.318,
   "dur": 2.514,
   "end": 102.918,
   "text": "PBS clusters work exactly the same way.",
   "chapter": "direct"
  },
  "p2": {
   "start": 103.268,
   "dur": 4.13,
   "end": 107.468,
   "text": "Direct servers show your processes and GPUs, one cell per card.",
   "chapter": "direct"
  },
  "p3": {
   "start": 107.818,
   "dur": 5.33,
   "end": 113.218,
   "text": "To keep an eye on a process, click the eye icon and pick it — you'll always hear when it ends.",
   "chapter": "direct"
  },
  "c1": {
   "start": 114.518,
   "dur": 5.546,
   "end": 120.518,
   "text": "Common simulation codes are detected automatically, with progress, speed and time left.",
   "chapter": "apps"
  },
  "c2": {
   "start": 120.868,
   "dur": 5.922,
   "end": 126.79,
   "text": "Open a job for details: NEP training shows its loss curves, with the live log tail below.",
   "chapter": "apps"
  },
  "c3": {
   "start": 127.14,
   "dur": 5.713,
   "end": 132.853,
   "text": "VASP relaxations plot energy and max force, and NEB runs show the energy barrier.",
   "chapter": "apps"
  },
  "c4": {
   "start": 133.203,
   "dur": 5.759,
   "end": 139.403,
   "text": "For anything else, write a rule: pick a file and a keyword, then hit Test to see the result.",
   "chapter": "apps"
  },
  "r1": {
   "start": 140.703,
   "dur": 6.045,
   "end": 147.303,
   "text": "A chime when a job finishes, a different sound when it fails or stops early — no more watching the terminal.",
   "chapter": "alerts"
  },
  "r2": {
   "start": 147.653,
   "dur": 3.933,
   "end": 152.653,
   "text": "To silence a server, click its bell, or pause its auto refresh.",
   "chapter": "alerts"
  },
  "r3": {
   "start": 153.003,
   "dur": 5.878,
   "end": 159.203,
   "text": "Cancelling is off by default; even when it's on, you hold for a second and a half, then confirm.",
   "chapter": "alerts"
  },
  "v1": {
   "start": 160.503,
   "dur": 6.186,
   "end": 166.689,
   "text": "New in this version: a terminal button on every card opens an ssh session in one click.",
   "chapter": "new"
  },
  "v2": {
   "start": 167.039,
   "dur": 5.262,
   "end": 172.439,
   "text": "Drag servers in the Settings sidebar, or right-click, to reorder them — the notch follows.",
   "chapter": "new"
  },
  "v3": {
   "start": 172.789,
   "dur": 6.196,
   "end": 178.985,
   "text": "When an update is out, one click downloads it, verifies it, replaces the app and reopens it.",
   "chapter": "new"
  },
  "w1": {
   "start": 180.285,
   "dur": 4.242,
   "end": 184.685,
   "text": "On Windows and Linux, a virtual island sits at the top of the screen;",
   "chapter": "cross"
  },
  "w2": {
   "start": 185.035,
   "dur": 5.064,
   "end": 190.099,
   "text": "or switch to a desktop octopus, with a tray icon to open the panel anytime.",
   "chapter": "cross"
  },
  "o1": {
   "start": 191.199,
   "dur": 6.079,
   "end": 197.278,
   "text": "ServerIsland is free and open source, with nothing to install on your servers. Grab it on GitHub!",
   "chapter": "outro"
  }
 },
 "cues": [
  {
   "t": 0.2,
   "type": "whoosh",
   "dur": 0
  },
  {
   "t": 6.9,
   "type": "ding",
   "dur": 0
  },
  {
   "t": 11.25,
   "type": "whoosh",
   "dur": 0
  },
  {
   "t": 16.05,
   "type": "shimmer",
   "dur": 0
  },
  {
   "t": 21.75,
   "type": "click",
   "dur": 0
  },
  {
   "t": 25.4,
   "type": "click",
   "dur": 0
  },
  {
   "t": 27.75,
   "type": "click",
   "dur": 0
  },
  {
   "t": 28.15,
   "type": "type",
   "dur": 3.4
  },
  {
   "t": 33.1,
   "type": "click",
   "dur": 0
  },
  {
   "t": 34.9,
   "type": "click",
   "dur": 0
  },
  {
   "t": 36.7,
   "type": "click",
   "dur": 0
  },
  {
   "t": 38.1,
   "type": "click",
   "dur": 0
  },
  {
   "t": 40.471,
   "type": "click",
   "dur": 0
  },
  {
   "t": 41.171,
   "type": "click",
   "dur": 0
  },
  {
   "t": 42.771,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 46.121,
   "type": "click",
   "dur": 0
  },
  {
   "t": 47.121,
   "type": "type",
   "dur": 1.2
  },
  {
   "t": 48.721,
   "type": "click",
   "dur": 0
  },
  {
   "t": 49.121,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 60.492,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 61.992,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 63.492,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 64.992,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 67.142,
   "type": "whoosh",
   "dur": 0
  },
  {
   "t": 83.518,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 87.368,
   "type": "click",
   "dur": 0
  },
  {
   "t": 92.518,
   "type": "click",
   "dur": 0
  },
  {
   "t": 93.118,
   "type": "click",
   "dur": 0
  },
  {
   "t": 108.218,
   "type": "click",
   "dur": 0
  },
  {
   "t": 110.418,
   "type": "click",
   "dur": 0
  },
  {
   "t": 121.168,
   "type": "click",
   "dur": 0
  },
  {
   "t": 127.24,
   "type": "whoosh",
   "dur": 0
  },
  {
   "t": 136.603,
   "type": "click",
   "dur": 0
  },
  {
   "t": 137.303,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 141.203,
   "type": "ding",
   "dur": 0
  },
  {
   "t": 144.003,
   "type": "dong",
   "dur": 0
  },
  {
   "t": 149.053,
   "type": "click",
   "dur": 0
  },
  {
   "t": 151.053,
   "type": "click",
   "dur": 0
  },
  {
   "t": 154.403,
   "type": "hold",
   "dur": 1.5
  },
  {
   "t": 156.003,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 158.003,
   "type": "click",
   "dur": 0
  },
  {
   "t": 161.403,
   "type": "click",
   "dur": 0
  },
  {
   "t": 167.439,
   "type": "click",
   "dur": 0
  },
  {
   "t": 169.639,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 173.189,
   "type": "click",
   "dur": 0
  },
  {
   "t": 177.589,
   "type": "shimmer",
   "dur": 0
  },
  {
   "t": 180.285,
   "type": "whoosh",
   "dur": 0
  },
  {
   "t": 185.435,
   "type": "boing",
   "dur": 0
  },
  {
   "t": 191.199,
   "type": "shimmer",
   "dur": 0
  }
 ],
 "total": 200.678
};

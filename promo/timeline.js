// ServerIsland v0.1 发布视频 · 共享时间轴
// 画面（index.html）和音乐（music.py）都读这一份：同一个节拍网格，卡点天然对齐。
// music.py 会解析 TIMELINE_JSON_BEGIN / END 之间的 JSON。
// TIMELINE_JSON_BEGIN
window.TIMELINE = {
  "bpm": 120,
  "fps": 60,
  "width": 1920,
  "height": 1080,
  "durationBeats": 100,
  "scenes": [
    { "id": "intro",    "from": 0,  "to": 8 },
    { "id": "notch",    "from": 8,  "to": 20 },
    { "id": "expand",   "from": 20, "to": 32 },
    { "id": "slurm",    "from": 32, "to": 44 },
    { "id": "nep",      "from": 44, "to": 56 },
    { "id": "alerts",   "from": 56, "to": 68 },
    { "id": "montage",  "from": 68, "to": 80 },
    { "id": "outro",    "from": 80, "to": 100 }
  ],
  "cues": [
    { "beat": 2.0,  "type": "whoosh" },
    { "beat": 3.0,  "type": "boing" },
    { "beat": 4.0,  "type": "shimmer" },
    { "beat": 7.5,  "type": "whoosh" },
    { "beat": 8.0,  "type": "impact" },
    { "beat": 9.0,  "type": "boing" },
    { "beat": 10.5, "type": "bloop" },
    { "beat": 11.0, "type": "pop", "pitch": 0 },
    { "beat": 20.75,"type": "click" },
    { "beat": 21.0, "type": "whoosh" },
    { "beat": 32.0, "type": "impact" },
    { "beat": 36.0, "type": "pop", "pitch": 3 },
    { "beat": 38.0, "type": "whoosh" },
    { "beat": 40.0, "type": "boing" },
    { "beat": 42.0, "type": "boing" },
    { "beat": 44.0, "type": "pop", "pitch": 0 },
    { "beat": 45.0, "type": "pop", "pitch": 2 },
    { "beat": 46.0, "type": "pop", "pitch": 4 },
    { "beat": 47.0, "type": "pop", "pitch": 5 },
    { "beat": 48.0, "type": "shimmer" },
    { "beat": 58.0, "type": "ding" },
    { "beat": 62.0, "type": "dong" },
    { "beat": 65.0, "type": "click" },
    { "beat": 68.0, "type": "impact" },
    { "beat": 69.0, "type": "pop", "pitch": 0 },
    { "beat": 70.0, "type": "pop", "pitch": 2 },
    { "beat": 71.0, "type": "pop", "pitch": 4 },
    { "beat": 72.0, "type": "pop", "pitch": 5 },
    { "beat": 73.0, "type": "pop", "pitch": 7 },
    { "beat": 74.0, "type": "pop", "pitch": 9 },
    { "beat": 75.0, "type": "pop", "pitch": 11 },
    { "beat": 76.0, "type": "pop", "pitch": 12 },
    { "beat": 77.0, "type": "pop", "pitch": 14 },
    { "beat": 80.0, "type": "impact" },
    { "beat": 81.0, "type": "boing" },
    { "beat": 83.0, "type": "boing" },
    { "beat": 85.0, "type": "boing" },
    { "beat": 87.5, "type": "whoosh" },
    { "beat": 88.0, "type": "bloop" },
    { "beat": 90.0, "type": "shimmer" },
    { "beat": 96.0, "type": "impact" }
  ]
}
// TIMELINE_JSON_END
;

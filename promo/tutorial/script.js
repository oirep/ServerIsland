// ServerIsland 功能介绍 / 使用教程 · 旁白与字幕脚本
// 画面（index.html）和声音（audio.py）都读这一份。audio.py 用 macOS 的 say 逐句合成配音，
// 按实际时长排出每一句的起止时间，写进 timing.js；画面里的动画都以"某一句开始的时刻"为锚点，
// 所以改了文案、语速以后重新跑 audio.py，画面会跟着对齐。
//
// 每一句：id、text（字幕）、tts（可选，给配音用的读法，比如 Tako 读作"塔可"）、gap（这一句前额外停顿，秒）、
//        min（这一句至少占多少秒，给动画留时间）。
// cues：音效，{at: 句子 id, off: 相对这一句开始的秒数, type}。
// audio.py 会解析 SCRIPT_JSON_BEGIN / END 之间的 JSON。
// SCRIPT_JSON_BEGIN
window.SCRIPT = {
  "engine": "edge",
  "voice": "zh-CN-XiaoxiaoNeural",
  "rate": "+8%",
  "sayVoice": "Tingting",
  "sayRate": 228,
  "lineGap": 0.35,
  "chapterGap": 0.9,
  "chapters": [
    { "id": "hook", "title": "", "lead": 1.4, "tail": 0.4, "lines": [
      { "id": "h1", "text": "这是 ServerIsland，一只住在 Mac 刘海里的小章鱼。", "tts": "这是 Server Island，一只住在 Mac 刘海里的小章鱼。", "min": 4.4 },
      { "id": "h2", "text": "任务跑完，它会“叮咚”一声告诉你；", "tts": "任务跑完，它会叮咚一声告诉你；", "gap": 0.6, "min": 3.6 },
      { "id": "h3", "text": "鼠标移上去，所有服务器的任务一眼看完。", "min": 4.2 },
      { "id": "h4", "text": "下面用三分钟，带你从头用一遍。", "gap": 0.6, "min": 3.4 }
    ]},
    { "id": "add", "title": "添加服务器", "lead": 0.8, "tail": 0.5, "lines": [
      { "id": "a1", "text": "打开设置，点“添加服务器”。", "tts": "打开设置，点添加服务器。", "min": 3.0 },
      { "id": "a2", "text": "写在 ~/.ssh/config 里的别名，直接选就行；", "tts": "写在 ssh config 里的别名，直接选就行；", "min": 3.6 },
      { "id": "a3", "text": "没有的话，手动填地址、用户名、端口和私钥。", "min": 4.6 },
      { "id": "a4", "text": "认证方式有四种：密钥、密码、密钥加密码和动态口令；还可以经跳板机连接。", "min": 6.4 },
      { "id": "a5", "text": "添加后点“自动检测类型”，是不是集群它自己判断。", "tts": "添加后点自动检测类型，是不是集群它自己判断。", "min": 5.0 },
      { "id": "a6", "text": "要密码的机器点“登录…”，输一次就好，连接会在后台保持。", "tts": "要密码的机器点登录，输一次就好，连接会在后台保持。", "min": 5.4 }
    ]},
    { "id": "notch", "title": "刘海与卡片", "lead": 0.8, "tail": 0.5, "lines": [
      { "id": "n1", "text": "平时刘海两边各露出一小块：左边是 Tako 和运行数，右边是任务进度。", "tts": "平时刘海两边各露出一小块：左边是塔可和运行数，右边是任务进度。", "min": 5.6 },
      { "id": "n2", "text": "Tako 的心情跟着服务器走：干活、排队打瞌睡、完成开心、出错就晕了。", "tts": "塔可的心情跟着服务器走：干活、排队打瞌睡、完成开心、出错就晕了。", "min": 6.4 },
      { "id": "n3", "text": "鼠标移上去就会展开：每台服务器一张卡片，任务和资源一目了然。", "min": 5.6 },
      { "id": "n4", "text": "没有任务的机器合并成一行，不占地方。", "min": 3.4 }
    ]},
    { "id": "slurm", "title": "Slurm 集群", "lead": 0.8, "tail": 0.5, "lines": [
      { "id": "s1", "text": "数组作业合成一行：绿色是完成，红色是失败，蓝色是正在跑。", "min": 5.0 },
      { "id": "s2", "text": "排队的作业，会把原因翻译成人话。", "min": 3.6 },
      { "id": "s3", "text": "点网格图标，看各分区还剩多少空闲资源；", "min": 5.0 },
      { "id": "s4", "text": "点时钟图标是历史记录：最近七天结束的作业、状态和目录都在这里。", "min": 5.6 }
    ]},
    { "id": "direct", "title": "PBS 与直连服务器", "lead": 0.8, "tail": 0.5, "lines": [
      { "id": "p1", "text": "PBS 集群的用法完全一样。", "min": 3.6 },
      { "id": "p2", "text": "直连的服务器显示你的进程和 GPU，每张卡一格。", "min": 4.2 },
      { "id": "p3", "text": "想盯住某个进程，点眼睛图标选中它，它结束时一定会提醒你。", "min": 5.4 }
    ]},
    { "id": "apps", "title": "计算软件进度", "lead": 0.8, "tail": 0.5, "lines": [
      { "id": "c1", "text": "常用的计算软件会被自动识别，直接显示进度、速度和剩余时间。", "min": 6.0 },
      { "id": "c2", "text": "点开任务看详情：NEP 训练有 loss 曲线，下面是实时的日志末尾。", "min": 5.4 },
      { "id": "c3", "text": "VASP 结构优化画能量和最大力，NEB 还会画出能垒。", "min": 5.0 },
      { "id": "c4", "text": "别的程序可以自己写规则：指定文件和关键字，点“测试”马上看到结果。", "tts": "别的程序可以自己写规则：指定文件和关键字，点测试马上看到结果。", "min": 6.2 }
    ]},
    { "id": "alerts", "title": "提醒与安全", "lead": 0.8, "tail": 0.5, "lines": [
      { "id": "r1", "text": "完成是“叮咚”，失败或提前结束是“咚咚”，不用一直盯着终端。", "tts": "完成是叮咚，失败或提前结束是咚咚，不用一直盯着终端。", "min": 6.6 },
      { "id": "r2", "text": "不想被某台机器打扰，就点铃铛静音，或者暂停它的自动刷新。", "min": 5.0 },
      { "id": "r3", "text": "取消作业默认关闭；打开后也要按住一秒半、再确认一次才会执行。", "min": 6.2 }
    ]},
    { "id": "new", "title": "v0.3.0 新功能", "lead": 0.8, "tail": 0.5, "lines": [
      { "id": "v1", "text": "新版本的卡片上多了终端按钮，一键 ssh 登录这台服务器。", "min": 5.2 },
      { "id": "v2", "text": "在设置侧栏里拖动或右键，就能给服务器排序，刘海里同步变化。", "min": 5.4 },
      { "id": "v3", "text": "有新版本时点一下“更新”，自动下载、核对校验值、替换并重新打开。", "tts": "有新版本时点一下更新，自动下载、核对校验值、替换并重新打开。", "min": 6.0 }
    ]},
    { "id": "cross", "title": "Windows / Linux", "lead": 0.8, "tail": 0.5, "lines": [
      { "id": "w1", "text": "Windows 和 Linux 上，屏幕顶部有一个虚拟的灵动岛；", "min": 4.4 },
      { "id": "w2", "text": "也可以换成桌面小章鱼，托盘图标随时打开面板。", "min": 4.6 }
    ]},
    { "id": "outro", "title": "", "lead": 0.6, "tail": 3.4, "lines": [
      { "id": "o1", "text": "ServerIsland 免费开源，服务器上什么都不用装。去 GitHub 下载试试吧！", "tts": "Server Island 免费开源，服务器上什么都不用装。去 GitHub 下载试试吧！", "min": 6.0 }
    ]}
  ],
  "cues": [
    { "at": "h1", "off": -1.2, "type": "whoosh" },
    { "at": "h2", "off": 0.15, "type": "ding" },
    { "at": "h3", "off": 0.55, "type": "whoosh" },
    { "at": "h4", "off": 0.2, "type": "shimmer" },
    { "at": "a1", "off": 1.3, "type": "click" },
    { "at": "a2", "off": 1.6, "type": "click" },
    { "at": "a3", "off": 0.0, "type": "click" },
    { "at": "a3", "off": 0.4, "type": "type", "dur": 3.4 },
    { "at": "a4", "off": 0.4, "type": "click" },
    { "at": "a4", "off": 2.2, "type": "click" },
    { "at": "a4", "off": 4.0, "type": "click" },
    { "at": "a4", "off": 5.4, "type": "click" },
    { "at": "a5", "off": 0.3, "type": "click" },
    { "at": "a5", "off": 1.0, "type": "click" },
    { "at": "a5", "off": 2.6, "type": "pop" },
    { "at": "a6", "off": 0.6, "type": "click" },
    { "at": "a6", "off": 1.6, "type": "type", "dur": 1.2 },
    { "at": "a6", "off": 3.2, "type": "click" },
    { "at": "a6", "off": 3.6, "type": "pop" },
    { "at": "n2", "off": 0.4, "type": "pop" },
    { "at": "n2", "off": 1.9, "type": "pop" },
    { "at": "n2", "off": 3.4, "type": "pop" },
    { "at": "n2", "off": 4.9, "type": "pop" },
    { "at": "n3", "off": 0.3, "type": "whoosh" },
    { "at": "s2", "off": 0.4, "type": "pop" },
    { "at": "s3", "off": 0.3, "type": "click" },
    { "at": "s4", "off": 0.1, "type": "click" },
    { "at": "s4", "off": 0.7, "type": "click" },
    { "at": "p3", "off": 0.4, "type": "click" },
    { "at": "p3", "off": 2.6, "type": "click" },
    { "at": "c2", "off": 0.3, "type": "click" },
    { "at": "c3", "off": 0.1, "type": "whoosh" },
    { "at": "c4", "off": 3.4, "type": "click" },
    { "at": "c4", "off": 4.1, "type": "pop" },
    { "at": "r1", "off": 0.5, "type": "ding" },
    { "at": "r1", "off": 3.3, "type": "dong" },
    { "at": "r2", "off": 1.4, "type": "click" },
    { "at": "r2", "off": 3.4, "type": "click" },
    { "at": "r3", "off": 1.4, "type": "hold", "dur": 1.5 },
    { "at": "r3", "off": 3.0, "type": "pop" },
    { "at": "r3", "off": 5.0, "type": "click" },
    { "at": "v1", "off": 0.9, "type": "click" },
    { "at": "v2", "off": 0.4, "type": "click" },
    { "at": "v2", "off": 2.6, "type": "pop" },
    { "at": "v3", "off": 0.4, "type": "click" },
    { "at": "v3", "off": 4.8, "type": "shimmer" },
    { "at": "w1", "off": 0.0, "type": "whoosh" },
    { "at": "w2", "off": 0.4, "type": "boing" },
    { "at": "o1", "off": 0.0, "type": "shimmer" }
  ]
}
// SCRIPT_JSON_END
;

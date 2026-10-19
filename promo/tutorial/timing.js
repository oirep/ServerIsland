// 由 audio.py 生成，不要手改：每句旁白的起止时间（秒）、各章节的范围、音效时刻。
window.TIMING = {
 "chapters": [
  {
   "id": "hook",
   "title": "",
   "from": 0.0,
   "to": 19.65
  },
  {
   "id": "add",
   "title": "添加服务器",
   "from": 19.65,
   "to": 50.872
  },
  {
   "id": "notch",
   "title": "刘海与卡片",
   "from": 50.872,
   "to": 74.353
  },
  {
   "id": "slurm",
   "title": "Slurm 集群",
   "from": 74.353,
   "to": 96.438
  },
  {
   "id": "direct",
   "title": "PBS 与直连服务器",
   "from": 96.438,
   "to": 111.638
  },
  {
   "id": "apps",
   "title": "计算软件进度",
   "from": 111.638,
   "to": 136.588
  },
  {
   "id": "alerts",
   "title": "提醒与安全",
   "from": 136.588,
   "to": 156.388
  },
  {
   "id": "new",
   "title": "v0.3.0 新功能",
   "from": 156.388,
   "to": 174.988
  },
  {
   "id": "cross",
   "title": "Windows / Linux",
   "from": 174.988,
   "to": 185.638
  },
  {
   "id": "outro",
   "title": "",
   "from": 185.638,
   "to": 195.638
  }
 ],
 "lines": {
  "h1": {
   "start": 1.4,
   "dur": 3.664,
   "end": 5.8,
   "text": "这是 ServerIsland，一只住在 Mac 刘海里的小章鱼。",
   "chapter": "hook"
  },
  "h2": {
   "start": 6.75,
   "dur": 2.32,
   "end": 10.35,
   "text": "任务跑完，它会“叮咚”一声告诉你；",
   "chapter": "hook"
  },
  "h3": {
   "start": 10.7,
   "dur": 3.333,
   "end": 14.9,
   "text": "鼠标移上去，所有服务器的任务一眼看完。",
   "chapter": "hook"
  },
  "h4": {
   "start": 15.85,
   "dur": 2.483,
   "end": 19.25,
   "text": "下面用三分钟，带你从头用一遍。",
   "chapter": "hook"
  },
  "a1": {
   "start": 20.45,
   "dur": 2.045,
   "end": 23.45,
   "text": "打开设置，点“添加服务器”。",
   "chapter": "add"
  },
  "a2": {
   "start": 23.8,
   "dur": 3.363,
   "end": 27.4,
   "text": "写在 ~/.ssh/config 里的别名，直接选就行；",
   "chapter": "add"
  },
  "a3": {
   "start": 27.75,
   "dur": 3.789,
   "end": 32.35,
   "text": "没有的话，手动填地址、用户名、端口和私钥。",
   "chapter": "add"
  },
  "a4": {
   "start": 32.7,
   "dur": 6.572,
   "end": 39.272,
   "text": "认证方式有四种：密钥、密码、密钥加密码和动态口令；还可以经跳板机连接。",
   "chapter": "add"
  },
  "a5": {
   "start": 39.622,
   "dur": 3.82,
   "end": 44.622,
   "text": "添加后点“自动检测类型”，是不是集群它自己判断。",
   "chapter": "add"
  },
  "a6": {
   "start": 44.972,
   "dur": 4.386,
   "end": 50.372,
   "text": "要密码的机器点“登录…”，输一次就好，连接会在后台保持。",
   "chapter": "add"
  },
  "n1": {
   "start": 51.672,
   "dur": 5.731,
   "end": 57.403,
   "text": "平时刘海两边各露出一小块：左边是 Tako 和运行数，右边是任务进度。",
   "chapter": "notch"
  },
  "n2": {
   "start": 57.753,
   "dur": 6.145,
   "end": 64.153,
   "text": "Tako 的心情跟着服务器走：干活、排队打瞌睡、完成开心、出错就晕了。",
   "chapter": "notch"
  },
  "n3": {
   "start": 64.503,
   "dur": 5.402,
   "end": 70.103,
   "text": "鼠标移上去就会展开：每台服务器一张卡片，任务和资源一目了然。",
   "chapter": "notch"
  },
  "n4": {
   "start": 70.453,
   "dur": 3.106,
   "end": 73.853,
   "text": "没有任务的机器合并成一行，不占地方。",
   "chapter": "notch"
  },
  "s1": {
   "start": 75.153,
   "dur": 5.397,
   "end": 80.549,
   "text": "数组作业合成一行：绿色是完成，红色是失败，蓝色是正在跑。",
   "chapter": "slurm"
  },
  "s2": {
   "start": 80.899,
   "dur": 2.738,
   "end": 84.499,
   "text": "排队的作业，会把原因翻译成人话。",
   "chapter": "slurm"
  },
  "s3": {
   "start": 84.849,
   "dur": 3.528,
   "end": 89.849,
   "text": "点网格图标，看各分区还剩多少空闲资源；",
   "chapter": "slurm"
  },
  "s4": {
   "start": 90.199,
   "dur": 5.738,
   "end": 95.938,
   "text": "点时钟图标是历史记录：最近七天结束的作业、状态和目录都在这里。",
   "chapter": "slurm"
  },
  "p1": {
   "start": 97.238,
   "dur": 2.105,
   "end": 100.838,
   "text": "PBS 集群的用法完全一样。",
   "chapter": "direct"
  },
  "p2": {
   "start": 101.188,
   "dur": 4.102,
   "end": 105.388,
   "text": "直连的服务器显示你的进程和 GPU，每张卡一格。",
   "chapter": "direct"
  },
  "p3": {
   "start": 105.738,
   "dur": 5.142,
   "end": 111.138,
   "text": "想盯住某个进程，点眼睛图标选中它，它结束时一定会提醒你。",
   "chapter": "direct"
  },
  "c1": {
   "start": 112.438,
   "dur": 5.521,
   "end": 118.438,
   "text": "常用的计算软件会被自动识别，直接显示进度、速度和剩余时间。",
   "chapter": "apps"
  },
  "c2": {
   "start": 118.788,
   "dur": 5.084,
   "end": 124.188,
   "text": "点开任务看详情：NEP 训练有 loss 曲线，下面是实时的日志末尾。",
   "chapter": "apps"
  },
  "c3": {
   "start": 124.538,
   "dur": 4.509,
   "end": 129.538,
   "text": "VASP 结构优化画能量和最大力，NEB 还会画出能垒。",
   "chapter": "apps"
  },
  "c4": {
   "start": 129.888,
   "dur": 5.926,
   "end": 136.088,
   "text": "别的程序可以自己写规则：指定文件和关键字，点“测试”马上看到结果。",
   "chapter": "apps"
  },
  "r1": {
   "start": 137.388,
   "dur": 4.648,
   "end": 143.988,
   "text": "完成是“叮咚”，失败或提前结束是“咚咚”，不用一直盯着终端。",
   "chapter": "alerts"
  },
  "r2": {
   "start": 144.338,
   "dur": 4.82,
   "end": 149.338,
   "text": "不想被某台机器打扰，就点铃铛静音，或者暂停它的自动刷新。",
   "chapter": "alerts"
  },
  "r3": {
   "start": 149.688,
   "dur": 5.532,
   "end": 155.888,
   "text": "取消作业默认关闭；打开后也要按住一秒半、再确认一次才会执行。",
   "chapter": "alerts"
  },
  "v1": {
   "start": 157.188,
   "dur": 5.071,
   "end": 162.388,
   "text": "新版本的卡片上多了终端按钮，一键 ssh 登录这台服务器。",
   "chapter": "new"
  },
  "v2": {
   "start": 162.738,
   "dur": 5.345,
   "end": 168.138,
   "text": "在设置侧栏里拖动或右键，就能给服务器排序，刘海里同步变化。",
   "chapter": "new"
  },
  "v3": {
   "start": 168.488,
   "dur": 5.999,
   "end": 174.488,
   "text": "有新版本时点一下“更新”，自动下载、核对校验值、替换并重新打开。",
   "chapter": "new"
  },
  "w1": {
   "start": 175.788,
   "dur": 3.926,
   "end": 180.188,
   "text": "Windows 和 Linux 上，屏幕顶部有一个虚拟的灵动岛；",
   "chapter": "cross"
  },
  "w2": {
   "start": 180.538,
   "dur": 4.108,
   "end": 185.138,
   "text": "也可以换成桌面小章鱼，托盘图标随时打开面板。",
   "chapter": "cross"
  },
  "o1": {
   "start": 186.238,
   "dur": 5.616,
   "end": 192.238,
   "text": "ServerIsland 免费开源，服务器上什么都不用装。去 GitHub 下载试试吧！",
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
   "t": 39.922,
   "type": "click",
   "dur": 0
  },
  {
   "t": 40.622,
   "type": "click",
   "dur": 0
  },
  {
   "t": 42.222,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 45.572,
   "type": "click",
   "dur": 0
  },
  {
   "t": 46.572,
   "type": "type",
   "dur": 1.2
  },
  {
   "t": 48.172,
   "type": "click",
   "dur": 0
  },
  {
   "t": 48.572,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 58.153,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 59.653,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 61.153,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 62.653,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 64.803,
   "type": "whoosh",
   "dur": 0
  },
  {
   "t": 81.299,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 85.149,
   "type": "click",
   "dur": 0
  },
  {
   "t": 90.299,
   "type": "click",
   "dur": 0
  },
  {
   "t": 90.899,
   "type": "click",
   "dur": 0
  },
  {
   "t": 106.138,
   "type": "click",
   "dur": 0
  },
  {
   "t": 108.338,
   "type": "click",
   "dur": 0
  },
  {
   "t": 119.088,
   "type": "click",
   "dur": 0
  },
  {
   "t": 124.638,
   "type": "whoosh",
   "dur": 0
  },
  {
   "t": 133.288,
   "type": "click",
   "dur": 0
  },
  {
   "t": 133.988,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 137.888,
   "type": "ding",
   "dur": 0
  },
  {
   "t": 140.688,
   "type": "dong",
   "dur": 0
  },
  {
   "t": 145.738,
   "type": "click",
   "dur": 0
  },
  {
   "t": 147.738,
   "type": "click",
   "dur": 0
  },
  {
   "t": 151.088,
   "type": "hold",
   "dur": 1.5
  },
  {
   "t": 152.688,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 154.688,
   "type": "click",
   "dur": 0
  },
  {
   "t": 158.088,
   "type": "click",
   "dur": 0
  },
  {
   "t": 163.138,
   "type": "click",
   "dur": 0
  },
  {
   "t": 165.338,
   "type": "pop",
   "dur": 0
  },
  {
   "t": 168.888,
   "type": "click",
   "dur": 0
  },
  {
   "t": 173.288,
   "type": "shimmer",
   "dur": 0
  },
  {
   "t": 175.788,
   "type": "whoosh",
   "dur": 0
  },
  {
   "t": 180.938,
   "type": "boing",
   "dur": 0
  },
  {
   "t": 186.238,
   "type": "shimmer",
   "dur": 0
  }
 ],
 "total": 195.638
};

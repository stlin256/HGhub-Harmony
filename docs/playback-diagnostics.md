# 播放诊断日志

设置 → 播放诊断 → **播放诊断日志**。默认关闭，开关在本机持久化，发布版也可使用。

## 复现与取日志

1. 开启日志。如需排查启动时的后台播放，开启后退出并重新启动应用。
2. 依次复现：播放首页视频、切到其他页面播放、点击进度条、拖动进度条。点击/松手后等待画面恢复；若一直卡住，至少等待 10 秒。
3. 回到设置关闭日志，点击 **复制播放诊断日志**。关闭后已有日志保留。

macOS 文件位于 `~/Library/Application Support/com.hghub.huangguo/`：

- `playback.log`：当前诊断日志，JSON Lines 格式。
- `playback.previous.log`：轮转前的日志，若存在，手动取文件时请一并提供。
- `playback-diagnostics.json`：开关配置，与 `security.json` 独立。

复制按钮包含当前与上一份日志。每份上限 2 MiB，总计约 4 MiB，自动轮转。日志只存本机；媒体地址用跨前后端一致的资源编号替代，不记录播放直链、查询参数、密钥内容、账号凭据或响应正文。原有 `debug.log` 仍用于应用异常与旧自检，不受此开关控制。

## 如何读记录

每行包含 UTC `ts`、进程 `pid`、递增 `seq`、当时生效的安全模式 `strict`、`event` 与 `data`。前端记录还包含采集时刻 `data.at`、单调时钟 `mono_ms`、页面会话 `session`、播放器 `player`、页面来源、视频/集数及激活状态。前端约每 250ms 批量写入，分析事件先后顺序使用 `data.at/mono_ms`，不只看落盘时间。

点击、拖动和键盘定位会记录：

| 事件 | 含义 |
| --- | --- |
| `web.seek.input.down/change/up/cancel` | 输入操作，包括 click/drag/keyboard、目标时间；点击同一位置即使没有 change，也保留按下/松开 |
| `web.seek.request` | 真正发起定位，包含播放器内递增的 `seek` 编号、目标时间和来源 |
| `web.seek.assigned` / `web.seek.rejected` | 写入 currentTime 后的状态，或写入失败 |
| `web.media.seeking` / `web.media.seeked` | 媒体元素确认正在定位/定位结束及耗时 |
| `web.seek.resumed` | 播放中定位后的首帧回调；不支持首帧 API 时标记为 playing 事件回退 |
| `web.seek.ready` | 暂停定位完成、数据已就绪；保持暂停，不把它记作恢复播放 |
| `web.seek.superseded` | 之前的定位被下一次拖动/点击替代 |
| `web.seek.noop` | 目标与当前时间相同，无需等待 seeking 事件 |
| `web.seek.timeout` | 8 秒后仍未完成，包含目标、实际时间、缓冲/可定位范围、readyState、paused、seeking 和 HLS 加载/缓冲开关 |

使用 `(pid, session, player, seek)` 关联一次操作。连续拖动会如实记录每次 currentTime 写入；诊断代码不合并或改变实际跳转行为。播放器每 5 秒记录状态快照，非激活页面仍播放时可看到 `active: false` 与 `paused: false`。

`web.hls.attached`/状态快照记录 MediaSource 类型与偏好；`web.mms.startstreaming/endstreaming`、分片加载/缓冲、非致命和致命 HLS 错误也会记录。`protocol.request` 包含原请求的 Range 和 Origin 分类；`proxy.begin/end` 与 `network.begin/end` 通过 `resource` 和请求编号关联代理耗时、HTTP 状态、字节数与每次重试。`network.target_failed`、`security.origin_denied`、`web.security.csp_violation` 用于识别安全拒绝，不需要关闭安全保护。

## 本地验证

使用 [进度条回归的媒体样本与服务器](playback-seek.md)，打开 `http://127.0.0.1:1420/tests/player-seek.html?diagnostics=1`。该模式使用真实 Feed、PlayerControls、VideoSurface 和 hls.js，日志传输替换为内存；“诊断设置”按钮提供真实设置界面。控制台的 `window.playerSeekFixture.logs` 可查看记录，`flushLogs()` 可立即刷新批次。

验证默认关闭时点击不记录；通过设置开启后，实际鼠标点击和拖动应分别产生 `desktop_click`、`desktop_drag`，并串联 request、seeking、seeked、首帧恢复。暂停定位应产生 ready 且保持暂停；关闭后不再增加记录；保存失败保持原状态。前后端类型检查、Rust 日志脱敏/轮转/保存失败测试也随构建检查。

追加 `&legacy=1` 可以检查吃瓜详情页使用的独立播放器。

本地 Chromium 验证不替代 macOS WKWebView 实机复现。

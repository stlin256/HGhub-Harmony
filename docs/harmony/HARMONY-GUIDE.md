# HarmonyOS API 26 ArkTS/ArkUI 能力调研指南

> 适用目标：`harmony` 分支上的 **完全鸿蒙原生**（ArkTS/ArkUI，禁止 WebView/H5）HGhub 客户端。
> 基线：DevEco Studio **26.0.0** + HarmonyOS SDK **API 26（platformVersion 26.0.0，ets 26.0.0.105）**，`compatibleSdkVersion 6.1.0(23)` / `targetSdkVersion 26.0.0` / `runtimeOS HarmonyOS`。
> 写作日期：2026-11-09。作者：harmony-docs（task-3）。

## 0. 怎样使用本文

### 0.1 证据等级（重要）

本文每一条结论都标注来源等级，**不要跨级采信**：

| 等级 | 含义 | 可信度 |
| --- | --- | --- |
| **A（SDK 声明）** | 直接引用本机 `<DevEco>\sdk\default\openharmony\ets\api|component\*.d.ts` 中 API 26 的真实签名，路径形如 `api/@ohos.multimedia.media.d.ts:L2469` | 最高：就是编译器的依据 |
| **B（官方文档）** | OpenHarmony 官方文档（Gitee/GitHub 官方镜像 markdown）或华为开发者文档中心 | 高，但可能落后/超前于 API 26 |
| **C（待真机验证）** | SDK/文档均未明确，或行为与设备/系统版本强相关 | 必须在真机上验证后再定稿 |

**本机 SDK 路径前缀（下称 `$SDK`）**：`%LOCALAPPDATA%\Programs\Huawei\DevEcoStudio-26.0.0\sdk\default\openharmony\ets`。
**官方文档镜像**：`https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/<路径>`（Gitee 与 GitHub 内容一致，GitHub raw 可直读）。

### 0.2 与原 Tauri 实现的能力映射（先看这张表，能省大量返工）

原项目（Tauri 2 + React）里，播放链路的"脏活"全在 Rust 侧，鸿蒙端必须等价重写。**这些结论来自只读分析 `src-tauri/src/media.rs`、`net.rs`、`lib.rs`**：

| 原实现（Rust / WebView） | 鸿蒙原生替代方案 | 依据 |
| --- | --- | --- |
| 自定义协议 `hg://localhost` / `http://hg.localhost` 提供 `/hls`、`/seg`、`/img` | **方案 A**：本地 TCP 服务器 `127.0.0.1:<port>` + AVPlayer 播 `http://127.0.0.1:<port>/hls?u=...`；**方案 B**：`MediaSource.setMediaResourceLoaderDelegate()`（API 18+）在进程内接管资源请求。两方案见 §4.4 | A：`@ohos.net.socket`（TCPSocketServer，§5.3）；B：`$SDK/api/@ohos.multimedia.media.d.ts:L4585` |
| reqwest 统一加 `Referer: {站点}/ ` + `UA: Chrome 131 Windows` | `@ohos.net.http` 的 `header` 字段；AVPlayer 侧用 `createMediaSourceWithUrl(url, headers)` | A：`$SDK/api/@ohos.net.http.d.ts:L171`；`@ohos.multimedia.media.d.ts:L185` |
| m3u8 里 key/分片 URI 重写为本地协议 | 用 ArkTS 手写 m3u8 改写器（逻辑与 `media.rs:rewrite_playlist` 一一对应）或 MediaSourceLoader 直接回源 | B：`media.rs:L202-L252` 即规格 |
| 封面 AES-128-CBC 解密（Rust aes crate） | `@ohos.security.cryptoFramework`（`AES128|CBC|NoPadding`）+ 手动去 PKCS7，再 `image.createImageSource(ArrayBuffer)` | A：`$SDK/api/@ohos.security.cryptoFramework.d.ts`；`@ohos.multimedia.image.d.ts:L4258` |
| hls.js 解析/解密 HLS（浏览器 API） | 不可用。AVPlayer 原生支持 HLS；AES-128 是否原生支持 → §4.9 / Q4 **待真机验证** | B：`playback-url-setting-method.md` 情况二 |

> ⚠️ 结论先行：**鸿蒙端"零代理"能不能成，取决于两件待验证的行为**——(1) `createMediaSourceWithUrl` 的 headers 是否作用于 HLS 子请求；(2) AVPlayer 是否原生解 HLS AES-128。这两点决定了要不要落地 §4.4 的本地代理。**先按"需要代理"设计，验证后再裁剪**，不要反过来。

### 0.3 目录

- §1 ArkTS 语言约束（含可直接抄的代码结构）
- §2 状态管理 V2 / V1
- §3 ArkUI 组件与能力（导航、列表、瀑布流、轮播、刷新、搜索、图片、Symbol、弹层、手势、动画、模糊、沉浸式、深色、字体、断点）
- §4 媒体：AVPlayer / HLS / MediaSourceLoader / 本地代理 / AVSession / 音频焦点
- §5 网络：http / socket / 明文策略 / TLS / 网络监听
- §6 加密与编码：AES-CBC、Base64、封面 → PixelMap
- §7 持久化：preferences / 文件缓存 / Asset Store / HUKS / RDB
- §8 并发与线程：taskpool / worker
- §9 权限与安全：module.json5、network_config.json、证书固定
- §10 打包与资源：$r/$rawfile、图标、启动页、targetSdk 26 影响
- §11 关键结论 FAQ（Q1–Q10，逐条回答）
- §12 待真机验证清单
- §13 官方文档索引

### 0.4 对 Lead 三个问题的直接回答（摘要，详见对应章节）

1. **`createMediaSourceWithUrl` 的 headers 是否作用于 HLS 播放列表/分片/密钥的全部子请求？**
   **官方文档与 API 26 d.ts 均未写明**（d.ts 只写 "HTTP header customized for streaming media pre-download"，官方指南示例把 Referer/UA/Cookie 用在 m3u8 URL 上）。因此：
   - "能设置 headers" 是 **B 级确定**；
   - "headers 是否透传到 HLS 子请求（含 `EXT-X-KEY` 密钥请求）" 是 **C 级待真机验证**，判定方法见 §4.4.3（自建 127.0.0.1 日志服务器，观察 /hls、/seg、/key 三处请求头）。
   **MediaSourceLoader（API 18+）** 官方定义为"帮助播放器请求媒体数据"，open 回调收到 `{url, header}` 且可 respondHeader/respondData，**理论上**可接管所有资源请求（含 key），但官方未明确 HLS 全链路（尤其 key）覆盖，同样 **C 级待验证**；实现成本高（自维护 uuid 状态机 + 异步推流），建议作为备选。
2. **明文 http + 127.0.0.1 是否可用；AVPlayer 播本地代理 http 流的限制？**
   `@ohos.net.http` 明文默认允许（可配 network_config.json 收紧）；**AVPlayer（Media Kit）自 API 23 起默认禁止明文（5411012）**，必须在 `resources/base/profile/network_config.json` 的 `component-config` 里设 `"Media Kit": true`（必要时再对 127.0.0.1 做 domain-config 放行）。127.0.0.1 有无系统豁免官方未写明，**按无豁免处理**。播放限制：需支持 Range/206、m3u8 Content-Type、失败不要静默 200、端口在同一播放会话内固定、多一次内存拷贝（720p/1080p 短剧可接受）。详见 §5.2、§4.4.5、§5.3。
3. **`@ohos.net.socket` 的 TCPSocketServer/SocketServer API 26 准确签名与权限？**
   用 `socket.constructTCPSocketServerInstance(): TCPSocketServer`（API 10+）→ `listen(address: NetAddress): Promise<void>`（一次完成 bind/listen/accept，port 0 由系统分配）→ `getLocalAddress(): Promise<NetAddress>`（API 12+）取端口 → `on('connect', (conn: TCPSocketConnection) => ...)`；连接对象有 `on('message'|'close'|'error')`、`send(TCPSendOptions)`、`getRemoteAddress()`、`close()`；`setExtraOptions(TCPExtraOptions)` 可设 keepAlive/TCPNoDelay 等。**权限：`ohos.permission.INTERNET`（listen/close/getState 等均标注 @permission）**，未授权抛 201；并发由系统多线程处理。详见 §5.3（含完整骨架代码）。

---

## 1. ArkTS 语言约束

ArkTS 不是"TS 跑在方舟上"，它**删掉了大量动态特性**。原项目 `src/` 下大量 TS 代码**不能直接复制**，必须按本节改写。规则出处：官方《从TypeScript到ArkTS的适配规则》（路径见 §13），逐条在本机 SDK 上验证过签名。

### 1.1 必须遵守的硬约束（违反=编译失败）

| # | 约束 | 原项目常见踩坑 | 改写方式 |
| --- | --- | --- | --- |
| 1 | **禁止 `any` / `unknown`**（`arkts-no-any-unknown`） | `catch (e: any)`、`JSON.parse` 直接点属性 | 定义 interface/class；catch 不写类型（见 1.4） |
| 2 | **禁止 `@ts-ignore` / `@ts-nocheck`**，严格类型检查不可关闭 | 老代码习惯 | 老老实实补类型 |
| 3 | **对象字面量必须显式类型**（`arkts-no-untyped-obj-literals`） | `const opt = { method: 'GET' }` | `const opt: http.HttpRequestOptions = { method: http.RequestMethod.GET }` |
| 4 | **对象字面量不能初始化"带方法/带自定义构造/带 readonly"的类** | `class A { foo(){} }` 然后 `const a: A = {}` | 纯数据类可用字面量；有行为/构造的类用 `new` |
| 5 | **禁止运行时改变对象布局**：不能增删属性、不能给属性赋非声明类型 | 给 DTO 动态挂字段 | 字段全在类里声明并初始化 |
| 6 | **类字段必须初始化 / 禁止确定赋值断言 `!`** | `private x!: number` | `private x: number = 0` 或 `x?: number` |
| 7 | **不支持解构**（赋值/变量声明/函数参数） | `const { a, b } = obj`、`function f({x})` | 逐字段取值 `const a = obj.a` |
| 8 | **禁止 index signature**（`[k: string]: T`）与**索引访问字段** | `obj[key]` 取强类型字段 | 用 `Record<string, T>`（仅限真·字典）或 `Map` |
| 9 | **禁止 `delete` / `in` 运算符 / `for..in`** | 配置清理、属性探测 | `Map.delete`；`hasOwnProperty` 用 JSON 扩展库 `json.has()`；`for (const k of Object.keys(o))` |
| 10 | **类型转换只允许 `as T`**，禁止 `<T>x`；错误转换运行期抛 `ClassCastException` | `(x as any)` | 只允许"相关类型"间 `as`，如 `Object` → 接口/DTO |
| 11 | **禁止 `as const`**，枚举只能用同类型编译期常量初始化 | `const enum` 风格 | 用 `enum` 或 `class + static readonly` |
| 12 | **禁止 `Function.apply/call/bind`、生成器、`new.target`、`globalThis`、`Symbol()`、JSX** | 工具函数、事件转发 | 箭头函数包装；显式回调 |
| 13 | **禁止函数内声明函数**；推荐箭头函数而非函数表达式 | 闭包辅助函数 | 提到模块级或改用箭头函数 |
| 14 | **`implements` 只能接接口**（类不能 `implements` 类） | `class A implements BaseClass` | 用接口抽象 |
| 15 | **`#` 私有字段不支持**；`constructor` 内不能声明字段（参数属性） | `constructor(private x)` | `private x: number; constructor(x: number) { this.x = x; }` |
| 16 | **`.ets` 可 import `.ets/.ts/.js` 源码；`.ts/.js` 不能 import `.ets`** | 把 UI 混进 `.ts` 工具文件 | 页面/组件一律 `.ets`，纯逻辑可 `.ts` |
| 17 | **`ESObject` 只用于跨语言（.ts/.js）交互**，不能承载 `.ets` 静态类型值 | 从 npm 库取 `any` 结果 | 类型边界处收敛成 DTO（见 1.5） |
| 18 | **不支持 `for..in` 枚举数组下标** | 遍历对象 | `for (let i = 0; i < arr.length; i++)` / `for (const v of arr)` |

> 参考错误码：`10605038`（无类型字面量）、`10605134`（确定赋值断言）、`10605999`（严格类型检查）、`10605053`（as 转换）、`10605151`（ESObject）。

### 1.2 类模型：DTO 与业务模型分离

ArkTS 没有结构化类型（structural typing），不同类即使字段一致也**不互相兼容**；接口与类之间赋值要显式 `implements`。所以后端 JSON → 页面模型必须手写映射层（这反而是好事：把容错集中在一处）。

```ts
// entry/src/main/ets/model/FeedVo.ets —— 只描述后端字段，全部可选字段显式标注
export interface FeedItemVo {
  id?: string;
  title?: string;
  cover?: string;
  duration?: number;
  tags?: string[];
}

export interface FeedRespVo {
  code?: number;
  msg?: string;
  data?: FeedItemVo[];
}

// entry/src/main/ets/model/VideoModel.ets —— 页面用的强类型模型，字段全部有默认值
export class VideoModel {
  id: string = '';
  title: string = '';
  coverUrl: string = '';
  durationMs: number = 0;
  tags: string[] = [];

  static fromVo(vo: FeedItemVo): VideoModel {
    const m = new VideoModel();
    m.id = vo.id ?? '';
    m.title = vo.title ?? '';
    m.coverUrl = vo.cover ?? '';
    m.durationMs = vo.duration ?? 0;
    m.tags = vo.tags ?? [];
    return m;
  }
}
```

### 1.3 JSON 解析的标准姿势

`JSON.parse` 的返回类型是 `Object`（不是 `any`），必须 `as` 成显式类型；**`as` 不会做字段校验**，字段可能 `undefined`，所以 DTO 字段要声明成可选，再经 1.2 的映射兜底。

```ts
import { http } from '@kit.NetworkKit';

async function fetchFeed(page: number): Promise<VideoModel[]> {
  const req = http.createHttp();
  try {
    const resp: http.HttpResponse = await req.request('https://example.com/api/feed?page=' + page, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.STRING, // 关键：明确要 string，否则 result 是 Object|ArrayBuffer
      header: { 'Accept': 'application/json', 'User-Agent': 'Chrome/131' },
      connectTimeout: 10000,
      readTimeout: 20000,
      usingCache: true
    });
    if (resp.responseCode !== http.ResponseCode.OK || typeof resp.result !== 'string') {
      return [];
    }
    const vo: FeedRespVo = JSON.parse(resp.result as string) as FeedRespVo;
    const list: FeedItemVo[] = vo.data ?? [];
    return list.map((it: FeedItemVo) => VideoModel.fromVo(it));
  } finally {
    req.destroy(); // 必须销毁，否则连接池泄漏
  }
}
```

**注意**：
- `resp.result` 的静态类型是 `string | Object | ArrayBuffer`，必须先 `typeof` 收窄再 `as string`（`as` 不能凭空把 Object 变 string）。
- 需要更强 JSON 能力（BigInt、循环引用检测、`has/remove` 安全操作）用 `import { JSON } from '@kit.ArkTS'`（`@arkts.json` 扩展库），它的 `parse` 同样返回 `Object | null`。
- **禁止** `JSON.parse(s) as SomeClass` 后直接调用类方法——`as` 只换类型标签，不会执行构造函数；需要方法时先 `as` 成 interface 再 `new SomeClass()` 映射。

### 1.4 可空、错误与异常

```ts
import { BusinessError } from '@kit.BasicServicesKit';

async function safeLoad(): Promise<string> {
  try {
    return await doWork();
  } catch (e) {                      // 不能写 e: any / e: Error（catch 不允许类型标注）
    const err = e as BusinessError;  // 需要错误码时 as 成 BusinessError
    console.error(`load failed, code=${err.code}, msg=${err.message}`);
    return '';
  }
}

// 可空用 | undefined / | null，禁止 ! 断言
class PlayerHolder {
  private player?: media.AVPlayer;   // 而不是 private player!: media.AVPlayer
  getOrNull(): media.AVPlayer | undefined { return this.player; }
}
```

### 1.5 与 npm/.ts/.js 的边界（Q3 相关）

- `.ets` 可以 import 同工程的 `.ts/.js` 源码，但**这些源码只能用 ArkTS 允许的语法**；npm 包（`node_modules`）**不能直接装进 ArkTS 工程**（没有 Node 运行时、没有 DOM，`fs/path/process/Buffer` 均不可用）。
- ohpm 生态（`ohpm.openharmony.cn`）的 HAR/HSP 包才是原生可用依赖，写法：`ohpm install @xxx/yyy`，然后 `oh-package.json5` 的 `dependencies` 出现 `"@xxx/yyy": "^1.0.0"`。
- 想复用纯算法 TS 库（如 m3u8 解析）：**复制源码 + 按 §1 改写**比"引包"快。hls.js 依赖 `MediaSource/SourceBuffer/XMLHttpRequest`，**在 ArkTS 中不可移植**，不要尝试。
- 需要原生能力（如 FFmpeg）只能走 NAPI（C++ 动态库）+ `.d.ts` 声明，成本高；本项目 AVPlayer 已覆盖 HLS，**不建议**走 NAPI。

### 1.6 @Builder / @BuilderParam / @Styles / @Extend

```ts
// 全局 @Builder：无 this，适合纯展示片段（图标+文案+角标）
@Builder
function TagChip(text: string, active: boolean) {
  Text(text)
    .fontSize(12)
    .fontColor(active ? '#FFFFFF' : '#B0FFFFFF')
    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
    .backgroundColor(active ? '#FF5A5F' : '#22FFFFFF')
    .borderRadius(999)
}

// 组件内 @Builder：可访问 this 的 @Local/@Param 状态
@ComponentV2
struct PosterCard {
  @Param title: string = '';
  @Event onTap: (id: string) => void = (id: string) => {};
  @Builder headBar() {
    Row() { SymbolGlyph($r('sys.symbol.play_fill')).fontSize(16); Text(this.title) }
  }
  build() { Column() { this.headBar() } }
}

// @BuilderParam：把"插槽"交给父组件（等价 React children）
@ComponentV2
struct Section {
  @BuilderParam header: () => void = () => {};
  @BuilderParam content: () => void = () => {};
  build() { Column() { this.header(); this.content() } }
}

// @Styles 只能写"公共属性"（不能带参数、不能写组件私有属性）
@Styles function cardStyle() {
  .backgroundColor('#1AFFFFFF')
  .borderRadius(16)
  .padding(12)
}

// @Extend 针对具体组件，可带参数 —— 推荐
@Extend(Text) function titleText(size: number) {
  .fontSize(size).fontWeight(FontWeight.Bold).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
}
```

**约束**：
- `@Styles` 只能包含通用属性（`width/fontSize/backgroundColor` 等），**不能含组件私有属性**（`Text` 的 `maxLines` 不行），且**不支持参数**；带参数/私有属性用 `@Extend`。
- `@BuilderParam` 的默认值必须是箭头函数；父组件传 `this.xxx` 时注意 `this` 绑定（传 `() => { this.xxx() }`）。
- V2 下 `@Builder` 里的状态读取规则与 V1 相同；**`@Builder` 内部不要用 `animateTo` 包裹状态修改**（见 §3.10）。

### 1.7 组件复用 @Reusable / @ReusableV2

长列表/瀑布流必备。V1 用 `@Reusable` + `aboutToReuse/async aboutToReuse`；V2 用 `@ReusableV2` + `aboutToReuse`（**V2 项目一律用 @ReusableV2**）。

```ts
@ReusableV2
@ComponentV2
struct FeedCard {
  @Local item: VideoModel = new VideoModel();
  @Param onOpen: (id: string) => void = (id: string) => {};

  aboutToReuse(params: Record<string, Object>): void {
    // 从复用池取回复用时执行：只做轻量赋值，不要在这里发网络请求
    this.item = params['item'] as VideoModel;
  }
  aboutToRecycle(): void {
    // 回收：可释放 PixelMap / 停掉动效
  }
  build() { /* ... */ }
}
```

> 依据：`$SDK/component/common.d.ts:L1376`（@Reusable）、`:L1378`（@ReusableV2）、`:L24497`（ComponentV2.aboutToReuse）。

### 1.8 本节来源

- OpenHarmony 官方文档：`zh-cn/application-dev/quick-start/typescript-to-arkts-migration-guide.md`（全部 18 条约束及其错误码）、`arkts-more-cases.md`
- SDK 声明：`$SDK/component/common.d.ts`（装饰器声明）、`$SDK/arkts/*.d.ets`（`@arkts.lang`、`@arkts.collections`、`@arkts.utils`）

## 2. 状态管理：V2 与 V1

### 2.1 结论先行

| 问题 | 结论 |
| --- | --- |
| 新项目用哪套？ | **全套 V2**（`@ComponentV2` + `@ObservedV2/@Trace` + `@Local/@Param/@Event` + `@Computed/@Monitor`），不要两套混着用 |
| 旧的 `@State/@Prop/@Link` 教程还能用吗？ | 能编译，但新代码不要写；同一组件内 V1/V2 装饰器**不能混用** |
| 全局状态（登录 token、线路、设置） | V1 的 `AppStorage`/`PersistentStorage` → V2 用 `AppStorageV2.connect()` / `PersistenceV2.connect()` |
| 深层嵌套对象改一个字段不刷新？ | V1 需要 `@Observed/@ObjectLink`；V2 需要**每一层类都 `@ObservedV2`、要观察的字段都 `@Trace`** |
| 派生数据（进度百分比、格式化时长） | 用 `@Computed`，不要在每个 build 里重复算 |
| 页面间共享播放器实例 | 用 `AppStorageV2` 存 `@ObservedV2` 的 `PlaybackStore`，或由 Navigation 路由参数传引用 |

### 2.2 V1 / V2 装饰器对照

| 能力 | V1 | V2 | 备注 |
| --- | --- | --- | --- |
| 组件装饰器 | `@Component` | `@ComponentV2` | 二选一，不能同组件并用 |
| 组件内部状态 | `@State` | `@Local` | `@Local` 必须初始化，不能接收父组件传值 |
| 父→子单向 | `@Prop` | `@Param` | `@Param` 在子组件内**只读** |
| 双向 | `@Link` | `@Param` + `@Event`（父侧自行回写） | V2 用"回调+父写"替代双向绑定 |
| 跨层级 | `@Provide/@Consume` | `@Provider/@Consumer` | V2 支持 `@Provider('别名')` 与可选注入 |
| 类观测 | `@Observed` + `@ObjectLink` | `@ObservedV2` + `@Trace` | V2 观测粒度是"属性" |
| 监听 | `@Watch` | `@Monitor`（异步批）/ `@SyncMonitor`（同步，API 23+） | `@Monitor` 可一次监听多个路径、支持通配 |
| 计算属性 | 无（get + 手算） | `@Computed` | 依赖 `@Trace/@Local/@Param` 自动缓存 |
| 组件复用 | `@Reusable` | `@ReusableV2` | V2 项目用后者 |
| 全局存储 | `AppStorage` | `AppStorageV2` | `AppStorageV2.connect(cls, key, factory)` |
| 持久化 | `PersistentStorage` | `PersistenceV2` | `PersistenceV2.connect(cls, key, factory)` |
| 冻结 | `@Component(freezeWhenInactive)` | 同（V2 有 freezeV2 专文） | 详情见官方《自定义组件冻结（V2）》 |

### 2.3 V2 关键语义（必须理解的 6 条）

1. **`@Local` 不能从父组件初始化**。父组件要传的值必须用 `@Param`；`@Local` 只做组件私有状态。
2. **`@Param` 是只读的**。子组件内 `this.param = x` 编译报错；需要本地可改副本时用 `@Once`（只同步父组件初值一次）或父组件通过 `@Event` 回调让父改。
3. **`@Param` 必须父传**。否则编译期报错；用 `@Require` 显式声明强制传入（`@Require @Param title: string`）。
4. **观察的粒度是 `@Trace` 属性**。`@ObservedV2` 类里没加 `@Trace` 的字段改了不刷新；嵌套对象要各自 `@ObservedV2`。
5. **`@Event` 是"子调父"的唯一推荐方式**。类型必须是函数，父组件传箭头函数；不要在子组件里 `@Param onXxx: () => void` 当回调用（语义上可行但没有 V2 的事件语义，且 V1/V2 混用限制多）。
6. **`@Computed` 必须是无副作用的 getter**，不能在里面发请求/改状态；依赖变化才重算，缓存自动失效。

### 2.4 可抄代码：播放器状态 Store（`@ObservedV2` + `@Trace` + `@Computed` + `@Monitor`）

```ts
// entry/src/main/ets/model/PlaybackStore.ets
@ObservedV2
export class PlaybackStore {
  @Trace currentTimeMs: number = 0;
  @Trace durationMs: number = 0;
  @Trace playing: boolean = false;
  @Trace speed: number = 1.0;
  @Trace buffering: boolean = false;
  @Trace errorText: string = '';

  @Computed
  get progress(): number {                       // 自动缓存，依赖变化才重算
    return this.durationMs <= 0 ? 0 : this.currentTimeMs / this.durationMs;
  }

  @Computed
  get timeLabel(): string {
    return PlaybackStore.format(this.currentTimeMs) + ' / ' + PlaybackStore.format(this.durationMs);
  }

  @Monitor('speed', 'errorText')                 // 支持多路径；异步批处理
  onKeyChanged(mon: IMonitor): void {
    const speed: IMonitorValue<number> | undefined = mon.value<number>('speed');
    if (speed !== undefined) {
      console.info(`speed ${speed.before} -> ${speed.now}, dirty=${mon.dirty.join(',')}`);
    }
  }

  static format(ms: number): string {
    const total = Math.max(0, Math.floor(ms / 1000));
    const m = Math.floor(total / 60);
    const s = total % 60;
    return (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s;
  }
}
```

### 2.5 可抄代码：`@ComponentV2` 播放条

```ts
import { PlaybackStore } from '../model/PlaybackStore';

@ComponentV2
export struct PlayerBar {
  @Require @Param store: PlaybackStore = new PlaybackStore(); // 父组件必传，子组件只读
  @Param compact: boolean = false;
  @Event onTogglePlay: () => void = () => {};                  // 子调父
  @Event onSeek: (ratio: number) => void = (ratio: number) => {};

  build() {
    Row({ space: 12 }) {
      Button() {
        // SymbolGlyph 只支持系统符号；播放/暂停这类业务图标用自绘 SVG（§3.10）
        Image(this.store.playing ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
          .width(22).height(22).fillColor('#FFFFFF')
      }
      .width(44).height(44).borderRadius(22)
      .backgroundColor('#33FFFFFF')
      .onClick(() => this.onTogglePlay())

      Column({ space: 4 }) {
        Text(this.store.timeLabel).fontSize(11).fontColor('#B0FFFFFF')
        Progress({ value: this.store.progress * 100, total: 100, type: ProgressType.Linear })
          .color('#FF5A5F').backgroundColor('#33FFFFFF').width('100%')
        if (this.store.buffering) {
          Row({ space: 6 }) {
            LoadingProgress().width(14).height(14).color('#FFFFFF')
            Text('缓冲中').fontSize(10).fontColor('#99FFFFFF')
          }
        }
      }
      .layoutWeight(1)
    }
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor('#99000000')
    .borderRadius(28)
  }
}
```

> 父组件写法：`PlayerBar({ store: this.store, onTogglePlay: () => { this.store.playing = !this.store.playing; } })`

### 2.6 AppStorageV2 / PersistenceV2（替代 AppStorage / PersistentStorage）

```ts
import { AppStorageV2, PersistenceV2 } from '@kit.ArkUI';

@ObservedV2
export class SettingsStore {
  @Trace lineIndex: number = 0;         // "线路"选择：需要持久化
  @Trace preferredQuality: string = 'auto';
  @Trace danmakuOn: boolean = true;
}

// 应用级（进程内共享，不落盘）：第二个参数是 key
const settings: SettingsStore =
  AppStorageV2.connect(SettingsStore, 'settings', () => new SettingsStore()) as SettingsStore;

// 持久化（落盘，重装前有效；字段必须可序列化：基本类型 / Array / Map / Set / @ObservedV2 嵌套类）
const saved: SettingsStore =
  PersistenceV2.connect(SettingsStore, () => new SettingsStore()) as SettingsStore;
```

**注意**：
- `connect()` 返回 `T | undefined`；ArkTS 禁止 `!` 断言，用 `as T` 收敛（默认工厂保证非空）。
- `PersistenceV2` 有容量上限（约几百 KB 级，具体随版本变化），**不要往 PersistenceV2 塞历史记录/大数组**；历史用 §7 的 preferences 或 RDB。
- `AppStorageV2` 只支持 `@ObservedV2` 类对象与 `Array/Map/Set` 等集合（见 `$SDK/api/@ohos.arkui.StateManagement.d.ts:L125-L160`）；V1 的 `AppStorage` 与 V2 的 `AppStorageV2` **是两套独立存储**，不能互通。
- 拿到"原始对象"（去掉代理）用 `UIUtils.getTarget(obj)`；把普通对象变成可观察用 `UIUtils.makeObserved(obj)`。

### 2.7 V1 / V2 混用：规则与建议

官方有专门文档《V1-V2混用》（`ui/state-management/arkts-v1-v2-mixusage.md`、`arkts-v1-v2-mixusage-before-api-version.md`），允许部分组合（如父 `@State` 传给子 `@Param`），但：

- **同一个组件内不能同时用 V1 与 V2 装饰器**；
- V1 的 `@Link/@Provide/@Consume` 与 V2 的 `@Param/@Provider/@Consumer` **不互通**，跨边界只有"值拷贝"，没有双向同步；
- 用第三方 HAR（可能是 V1 写的）时，只能在边界处传值，**不要期望深层刷新**。

**本项目建议**：页面、组件、模型全部 V2；仅在使用第三方 V1 组件时按"值传入 + 事件传出"的哑组件方式使用。

### 2.8 动画与 V2：`animateTo` 失效坑

V2 状态修改后，`animateTo` 内的修改**不会自动产生隐式动画**（官方专文《V1-V2迁移-animateTo》）：V2 中请用 `this.getUIContext().animateTo(param, () => { ... })`，并且**在修改状态的外层包 animateTo**，而不是被修改的属性上加 `.animation()`（`.animation()` 在 V2 下对 `@Local` 修改同样不保证生效，官方建议用 `animateTo`）。见 §3.10。

### 2.9 本节来源

- SDK 声明：`$SDK/component/common.d.ts:L297`（ComponentV2）、`:L387`（ObservedV2）、`:L431`（Local）、`:L442`（Param）、`:L464`（Event）、`:L577`（Provider）、`:L931`（Consumer）、`:L942`（Computed）、`:L1040`（Monitor）、`:L1181`（SyncMonitor）、`:L1091`（IMonitor）、`:L1378`（ReusableV2）
- SDK 声明：`$SDK/api/@ohos.arkui.StateManagement.d.ts:L125`（AppStorageV2）、`:L247`（PersistenceV2）、`:L363`（UIUtils）
- 官方文档：`ui/state-management/arkts-new-local.md`、`arkts-new-param.md`、`arkts-new-event.md`、`arkts-new-provider-and-consumer.md`、`arkts-new-observedV2-and-trace.md`、`arkts-new-computed.md`、`arkts-new-monitor.md`、`arkts-new-appstoragev2.md`、`arkts-new-persistencev2.md`、`arkts-v1-v2-migrate*.md`、`arkts-v1-v2-mixusage.md`

---

## 3. ArkUI 组件与能力

> 本章所有 API 均在 API 26 的 `component/*.d.ts` 中核对过。代码按"可直接落进 `entry/src/main/ets/`"的标准写。

### 3.1 应用骨架：UIAbility + 窗口

```ts
// entryability/EntryAbility.ets
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, 'hg', 'onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) { hilog.error(0x0000, 'hg', 'loadContent failed: %{public}s', JSON.stringify(err)); }
    });
    // 沉浸式（详见 §3.16）：页面内容延伸到状态栏/导航条
    const win = windowStage.getMainWindowSync();
    win.setWindowLayoutFullScreen(true);
  }

  onForeground(): void {}
  onBackground(): void {}
  onWindowStageDestroy(): void {}
  onDestroy(): void {}
}
```

- `$SDK/api/@ohos.app.ability.UIAbility.d.ts:L303-L384`（`context`、`onWindowStageCreate`）
- `$SDK/api/@ohos.window.d.ts`：`getMainWindowSync`、`loadContent`（在 token/`WindowStage` 上）

### 3.2 路由：Navigation + NavPathStack + NavDestination（**替代 React Router**）

原则：**单页面应用 + Navigation 组件式路由**，不要用旧的 `router.pushUrl`（`@ohos.router` 已不推荐用于新工程；Navigation 支持转场动画、返回拦截、路由栈管理、弹窗式页面）。

```ts
// pages/Index.ets
@Entry
@ComponentV2
struct Index {
  @Local pathStack: NavPathStack = new NavPathStack();

  @Builder
  routeMap(name: string) {          // navDestination builder 至少接收 name 参数
    if (name === 'detail') {
      DetailPage({ pathStack: this.pathStack })   // 页面内用 ctx.pathInfo.param 取路由参数
    } else if (name === 'player') {
      PlayerPage()
    }
  }

  build() {
    Navigation(this.pathStack) {
      HomePage({ pathStack: this.pathStack })   // 根内容
    }
    .navDestination(this.routeMap)             // 路由表（builder）
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .backgroundColor('#0B0B0F')
  }
}

export class DetailParam {
  id: string = '';
}
```

```ts
// 任意子页面：入栈 / 出栈
this.pathStack.pushPathByName('detail', param as Object);   // void，可加 animated 参数
this.pathStack.pop();                                      // 返回上一页
this.pathStack.pop(result as Object);                      // 带结果返回（配合 onPop 回调）
const params: Array<unknown> = this.pathStack.getParamByName('detail'); // 取同名路由的全部参数
```

```ts
// pages/DetailPage.ets —— NavDestination 是"页面"容器，自带转场与返回键处理
@ComponentV2
export struct DetailPage {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Local videoId: string = '';
  @Local detail: VideoDetail = new VideoDetail();

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 16 }) { /* 详情内容 */ }
      }
    }
    .title('详情')
    .hideTitleBar(true)                 // 自绘标题栏（沉浸式页面更常用）
    .backgroundColor('#0B0B0F')
    .onBackPressed(() => {              // 返回 true 表示已消费返回事件（用于"再按一次退出"等）
      return false;
    })
    .onReady((ctx: NavDestinationContext) => {
      const param: DetailParam = ctx.pathInfo.param as DetailParam;   // 入栈时带过来的参数
      const stack: NavPathStack = ctx.pathStack;                      // 当前页面可用路由栈
      this.videoId = param.id;
    })
  }
}
```

**Signed 依据**：`$SDK/component/navigation.d.ts:L615`（`NavPathStack`）、`:L638`（`pushPath`）、`:L723`（`pushPathByName`）、`:L947`（`pop`）、`:L1127`（`getParamByName`）、`:L1088`（`clear`）、`:L2594`（`navDestination(builder)`）。

**转场**：Navigation 自带默认转场；自定义用 `NavDestination().mode(NavDestinationMode.STANDARD | DIALOG)` 与 `Navigation().customNavContentTransition(...)`（后者签名较长，见 `navigation.d.ts`，建议二期再做）。**共享元素转场**（海报道播放器）用 `geometryTransition`，见 §3.14。

### 3.3 底部导航：Tabs + TabContent（**替代 React 的底部 TabBar**）

```ts
import { HomePage } from '../pages/HomePage';
// ...
@ComponentV2
export struct MainTabs {
  @Local tabIndex: number = 0;
  private controller: TabsController = new TabsController();

  @Builder
  tabBar(title: string, icon: Resource, index: number) {
    Column({ space: 3 }) {
      // 业务图标用自绘 SVG（放 resources/base/media/），单色可用 fillColor 上色
      Image(icon)
        .width(22).height(22)
        .fillColor(this.tabIndex === index ? '#FF5A5F' : '#88FFFFFF')
      Text(title)
        .fontSize(10)
        .fontColor(this.tabIndex === index ? '#FF5A5F' : '#88FFFFFF')
    }
    .width('100%').height(52).justifyContent(FlexAlign.Center)
  }

  build() {
    Tabs({ barPosition: BarPosition.End, index: this.tabIndex, controller: this.controller }) {
      TabContent() { HomePage() }.tabBar(this.tabBar('首页', $r('app.media.ic_tab_home'), 0))
      TabContent() { DiscoverPage() }.tabBar(this.tabBar('发现', $r('app.media.ic_tab_search'), 1))
      TabContent() { MinePage() }.tabBar(this.tabBar('我的', $r('app.media.ic_tab_mine'), 2))
    }
    .barMode(BarMode.Fixed)
    .scrollable(false)                 // 禁止左右滑切换（避免与视频手势冲突）
    .onChange((index: number) => { this.tabIndex = index; })
    .backgroundColor('#0B0B0F')
  }
}
```

- `$SDK/component/tabs.d.ts:L297`（TabsController）、`:L413`（barPosition）、`:L1066`（scrollable）、`:L1313`（onChange）
- **注意**：底部 TabBar 高度、颜色、选中态都要自绘（`.tabBar(builder)`），系统 `BottomTabBarStyle` 更适合系统风格；本项目要用定制视觉，用 `@Builder` 版本。
- 每个 TabContent 内的页面切走后默认**不销毁**（保留状态），长列表页面请配合 `@ComponentV2` 的 `aboutToDisappear` 暂停轮播/视频。

### 3.4 长列表：List + LazyForEach + IDataSource（**替代 FlatList/虚拟滚动**）

**必须用 LazyForEach**（ForEach 会全量创建，几百条就卡）。数据源要实现 `IDataSource`（4 个方法），并自行管理 `DataChangeListener`。

```ts
// model/FeedDataSource.ets
import { VideoModel } from './VideoModel';

export class FeedDataSource implements IDataSource {
  private items: VideoModel[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number { return this.items.length; }
  getData(index: number): VideoModel { return this.items[index]; }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); }
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener);
    if (pos >= 0) { this.listeners.splice(pos, 1); }
  }

  resetAll(items: VideoModel[]): void {
    this.items = items;
    this.listeners.forEach((l: DataChangeListener) => l.onDataReloaded());
  }
  append(items: VideoModel[]): void {
    const start = this.items.length;
    for (let i = 0; i < items.length; i++) { this.items.push(items[i]); }
    for (let i = start; i < this.items.length; i++) {
      this.listeners.forEach((l: DataChangeListener) => l.onDataAdd(i));
    }
  }
  updateItem(index: number, item: VideoModel): void {
    this.items[index] = item;
    this.listeners.forEach((l: DataChangeListener) => l.onDataChange(index));
  }
}
```

```ts
// pages/HomePage.ets
@ComponentV2
export struct HomePage {
  private ds: FeedDataSource = new FeedDataSource();
  @Local loading: boolean = true;
  private page: number = 0;

  aboutToAppear(): void { this.reload(); }

  async reload(): Promise<void> {
    this.loading = true;
    this.page = 0;
    const list = await feedApi.list(0);
    this.ds.resetAll(list);
    this.loading = false;
  }
  async loadMore(): Promise<void> {
    this.page++;
    const list = await feedApi.list(this.page);
    this.ds.append(list);
  }

  build() {
    List({ space: 12 }) {
      LazyForEach(this.ds, (item: VideoModel, index: number) => {
        ListItem() {
          FeedCard({ item: item })       // FeedCard 是 @ReusableV2 组件（§1.7）
        }
      }, (item: VideoModel) => item.id)  // key 必须稳定且唯一，否则复用会错乱
    }
    .cachedCount(6)                       // 预创建屏幕外 6 条，滑动更顺
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .divider({ strokeWidth: 0.5, color: '#1AFFFFFF' })
    .onReachEnd(() => { this.loadMore(); })
    .width('100%').height('100%')
  }
}
```

- `$SDK/component/lazy_for_each.d.ts:L804`（IDataSource）、`:L612`（DataChangeListener）、`:L656`（onDataAdd）
- **性能要点**：
  - key 生成器不要拼接会变的内容（如时间戳），否则整列表重建；
  - `cachedCount` 建议 4–8，瀑布流同理；
  - 卡片里不要做同步大计算；图片用 PixelMap 缓存（§3.9）；
  - 列表滚动时暂停自动播放/轮播（监听 `onScrollIndex`/`onDidScroll`）。

### 3.5 瀑布流：WaterFlow（**首页/发现页推荐**）

```ts
WaterFlow() {
  LazyForEach(this.ds, (item: VideoModel) => {
    FlowItem() { FeedCard({ item: item }) }.width('100%')
  }, (item: VideoModel) => item.id)
}
.columnsTemplate('1fr 1fr')      // 也可 'repeat(auto-fill, 160)' 自适应列数
.columnsGap(10)
.rowsGap(10)
.cachedCount(4)
.layoutMode(WaterFlowLayoutMode.TOP_DOWN)   // 可选：固定行高布局更省
.onReachEnd(() => { this.loadMore(); })
.width('100%').height('100%')
```

- `$SDK/component/water_flow.d.ts:L509`（columnsTemplate）、`:L586/L599`（gap）、`:L679`（cachedCount）、`:L773`（onReachEnd）、`:L318`（footer）
- 无限加载的"到底提示"用 `.footer(this.footerBuilder)`；空态用 `if (this.ds.totalCount() === 0)` 叠加。
- 瀑布流 + 大量图片是最容易掉帧的场景：务必配合 §3.9 的图片缓存与 §6 的封面解密。

### 3.6 轮播：Swiper（Banner）

```ts
Swiper(this.swiperController) {
  ForEach(this.banners, (b: BannerModel) => {
    Image(b.imageUrl).width('100%').height(180).borderRadius(16).objectFit(ImageFit.Cover)
  }, (b: BannerModel) => b.id)
}
.autoPlay(true)
.interval(4000)
.loop(true)
.indicator(true)
.duration(300)
.onChange((index: number) => { this.currentBanner = index; })
.width('100%').height(180)
```

- `$SDK/component/swiper.d.ts:L29`（SwiperController）、`.showNext()/showPrevious()`；`.indicator()`、`.autoPlay()`、`.interval()`、`.loop()`、`.onChange()`
- 页面切到后台（`onPageHide`/`aboutToDisappear`）时 `autoPlay(false)`，省电且避免后台动画。

### 3.7 下拉刷新：Refresh

```ts
Refresh({ refreshing: this.isRefreshing, promptText: '下拉刷新' }) {
  List() { /* ... */ }
}
.onRefreshing(() => { this.reload(); })   // 进入刷新态触发
.refreshOffset(64)
.onStateChange((state: RefreshStatus) => {
  // RefreshStatus.Inactive / Drag / OverDrag / Refresh / Done
})
```

```ts
async reload(): Promise<void> {
  try { await this.loadFirstPage(); } finally { this.isRefreshing = false; }  // 结束刷新必须置 false
}
```

- `$SDK/component/refresh.d.ts:L293`（onStateChange）、`:L305`（onRefreshing）、`:L320`（refreshOffset）
- 若要"滚动到顶部才触发下拉"，Refresh 需要包住可滚动组件（List/Scroll/WaterFlow），且内部滚动组件不要设置固定高度超出。

### 3.8 搜索与输入：Search / TextInput

```ts
Row({ space: 8 }) {
  Search({ value: this.keyword, placeholder: '搜索剧名、演员' })
    .width('100%').height(40).borderRadius(20)
    .backgroundColor('#1AFFFFFF')
    .placeholderColor('#66FFFFFF')
    .onChange((value: string) => { this.keyword = value; this.debouncedSearch(value); })
    .onSubmit((value: string) => { this.doSearch(value); })
    .searchButton('搜索')
}
TextInput({ text: this.account, placeholder: '手机号/邮箱' })
  .type(InputType.Normal)
  .maxLength(64)
  .height(48)
  .onChange((value: string) => { this.account = value; })
  .onSubmit((enterKey: EnterKeyType) => { this.login(); })
```

- `$SDK/component/search.d.ts:L729`（onSubmit）、`:L759`（onChange）、`:L524`（searchButton）；`$SDK/component/text_input.d.ts:L1091`（onSubmit）、`:L1107`（onChange）、`:L1148`（maxLength）
- 防抖：用 `setTimeout` + `clearTimeout`；输入框失焦 `onBlur` 收起键盘（`focusControl.requestFocus` 或 `KeyboardAvoidMode` 默认即可）。
- 键盘避让：页面根用 `Scroll` 并设置 `.expandSafeArea([])`；系统默认 `KeyboardAvoidMode.RESIZE` 可用 `window` 的 `setWindowKeyboardAvoidMode`?（该 API 在 `@ohos.window` 中名为 `setKeyboardAvoidMode`，确认后再用，否则用默认行为）。

### 3.9 图片：Image / PixelMap / 封面渲染（**与服务端 AES 封面强相关**）

`Image` 可以直接接网络 URL，但本项目**封面是 AES-128-CBC 密文**，必须走"http 下载 → AES 解密 → PixelMap → Image(PixelMap)"（§6.3 有完整代码）。`Image(PixelMap)` 的用法与优化：

```ts
Image(this.coverPixel)
  .width('100%')
  .aspectRatio(0.72)                  // 2:3 海报，避免布局抖动
  .objectFit(ImageFit.Cover)
  .borderRadius({ topLeft: 12, topRight: 12 })
  .interpolation(ImageInterpolation.Medium)   // 缩小时更平滑
  .draggable(false)                   // 禁止拖拽，减少长按手势冲突
  .alt($r('app.media.cover_placeholder'))
  .onComplete(() => { /* 加载完成 */ })
  .onError(() => { /* 失败兜底 */ })
```

- **不要在主线程做同步解码**：`createImageSource(...).createPixelMap({ desiredSize })` 是异步 Promise，且一定传 `desiredSize`（按控件实际像素下采样 = 内存减半以上；列表卡片 160×220 就够）。
- 列表滚动复用时必须 `pixelMap.release()`（或交给 LRU 统一释放），否则内存会持续上涨。`PixelMap` 是 native 对象，**不能从 taskpool 直接返回**（不可序列化），所以 AES 解密可在 taskpool（ArrayBuffer 可 Transfer），**解码放主线程异步 API**。
- 大图/长图用 `.sourceSize({ width, height })` 限制解码尺寸；`Image` 的 `autoResize` 默认 true，一般不用改。
- 需要"沉浸式模糊背景"（播放器页海报背景）时，把同一 PixelMap 放大 + `blur(40)` / `backgroundBlurStyle` 叠加，见 §3.15。

### 3.10 图标：SymbolGlyph（系统符号）与自定义 SVG

**SymbolGlyph 只接受系统 symbol 资源**（`$r('sys.symbol.xxx')`），不支持自定义图片；单色/多色渲染、动效是它的优势。已验证可用的资源名（来自官方 SymbolGlyph 文档示例）：`sys.symbol.ohos_wifi`、`sys.symbol.ohos_trash`、`sys.symbol.ohos_folder_badge_plus`、`sys.symbol.checkmark_circle`、`sys.symbol.repeat_1`、`sys.symbol.eye`、`sys.symbol.eye_slash`、`sys.symbol.chevron_down`、`sys.symbol.chevron_forward`。**完整符号清单以华为文档《Symbol 图标库》/ DevEco 资源预览为准**，不要凭感觉猜名字（写错会显示异常或编译报资源不存在）。

```ts
SymbolGlyph($r('sys.symbol.checkmark_circle'))
  .fontSize(22)
  .fontColor(['#FF5A5F', '#FFFFFF'])        // 数组支持多色渲染策略
  .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
  .effectStrategy(SymbolEffectStrategy.SCALE) // 点击缩放反馈（可选）
  .fontWeight(FontWeight.Medium)
```

- `$SDK/component/symbolglyph.d.ts:L641`（fontSize）、`:L659`（fontColor）、`:L745`（renderingStrategy）、`:L727`（effectStrategy）
- 自定义图标（播放/暂停/清晰度/投屏等业务图标）：放 `resources/base/media/*.svg`，用 `$r('app.media.ic_play')` 给 `Image`；单色 SVG 可用 `.fillColor('#FFFFFF')`（`Image` 的 `fillColor` 对 SVG 有效）。原项目的 `public/` 图标（app-icon.svg 等）可直接迁到 `resources/base/media/`。
- **图标规范建议**：一套 24×24 viewBox 的 SVG，统一 `stroke-width="2"`；深色背景用白色 `fill`；播放器控制条图标单独一套（28~32vp）。

### 3.11 弹层：bindSheet / bindMenu / bindContentCover / AlertDialog / promptAction

```ts
// 1) 半模态 Sheet（详情页"选集/线路/清晰度"底部弹层，首选）
@Local showSheet: boolean = false;

Button('选集').onClick(() => { this.showSheet = true; })
  .bindSheet(this.showSheet, this.sheetBuilder(), {
    height: SheetSize.MEDIUM,              // 或具体数值：'60%'
    dragBar: true,
    showClose: true,
    preferType: SheetType.BOTTOM,
    backgroundColor: '#17171C',
    onDisappear: () => { this.showSheet = false; }
  })

@Builder sheetBuilder() {
  Column() { /* 选集网格 */ }.padding(16)
}

// 2) 长按菜单（bindMenu）
Text('更多').bindMenu([
  { value: '下载', action: () => { this.download(); } },
  { value: '举报', action: () => { this.report(); } }
])

// 3) 全屏覆盖（登录/播放器全屏页）
Text('登录').bindContentCover(this.showLogin, this.loginBuilder(), {
  modalTransition: ModalTransition.DEFAULT,
  onDisappear: () => { this.showLogin = false; }
})

// 4) 系统 AlertDialog（确认框）
AlertDialog.show({
  title: '提示',
  message: '确定退出登录吗？',
  primaryButton: { value: '取消', action: () => {} },
  secondaryButton: { value: '退出', fontColor: '#FF5A5F', action: () => { this.logout(); } }
})

// 5) Toast / ActionMenu / 自定义弹窗（统一走 UIContext，避免全局 promptAction 弃用问题）
const ctx = this.getUIContext();
ctx.getPromptAction().showToast({ message: '已加入追剧', duration: 2000, bottom: 80 });
ctx.getPromptAction().showDialog({ title: '提示', message: '...', buttons: [{ text: '知道了', color: '#FF5A5F' }] });
```

- `$SDK/component/common.d.ts:L21649`（bindSheet）、`:L21466/L21480`（bindMenu）、`:L21609/L21628`（bindContentCover）
- `$SDK/component/alert_dialog.d.ts:L1042`（AlertDialog.show）、`:L965`（带两按钮参数）
- `$SDK/api/@ohos.promptAction.d.ts:L156`（ShowToastOptions）、`:L1831`（showToast）、`:L1918`（showDialog）、`:L1990`（openCustomDialog）
- `$SDK/api/@ohos.arkui.UIContext.d.ts:L725`（PromptAction）、`:L4555`（getPromptAction）
- 建议：**toast 类提示统一封装**，不要在业务代码里散落 `AlertDialog`；"选集"这种操作密度高的面板用 `bindSheet` 而不是全屏页。

### 3.12 进度与加载：Progress / LoadingProgress / 骨架屏

```ts
// 线性进度（播放器进度条自绘时用 Slider 更合适，见下）
Progress({ value: 40, total: 100, type: ProgressType.Linear })
  .width('100%').height(3).color('#FF5A5F').backgroundColor('#33FFFFFF')
  .style({ strokeWidth: 3, enableSmoothEffect: true })

// 环形加载
LoadingProgress().width(32).height(32).color('#FFFFFF')

// 播放器可拖拽进度条用 Slider
Slider({ value: this.store.currentTimeMs, min: 0, max: this.store.durationMs, step: 100 })
  .width('100%')
  .blockColor('#FFFFFF')
  .trackColor('#33FFFFFF')
  .selectedColor('#FF5A5F')
  .trackThickness(3)
  .onChange((value: number, mode: SliderChangeMode) => {
    if (mode === SliderChangeMode.End) { this.seekTo(value); }
  })
```

**骨架屏（首屏加载优化）**：不要用白屏/转圈，用与真实布局同尺寸的灰色块 + 呼吸动画（`animateTo` 循环改 opacity，或 `SymbolGlyph` 的 `symbolEffect`）。这是"更精致加载体验"的最低成本方案：

```ts
@Local shimmer: number = 0.35;
aboutToAppear(): void {
  const ctx = this.getUIContext();
  setInterval(() => {
    ctx.animateTo({ duration: 800, curve: Curve.EaseInOut }, () => {
      this.shimmer = this.shimmer > 0.5 ? 0.3 : 0.7;
    });
  }, 900);
}
// 使用：Rect().fill('#1AFFFFFF').opacity(this.shimmer)
```

### 3.13 手势：Tap / LongPress / Pan / GestureGroup

```ts
// 单击
Text('点我').gesture(TapGesture({ count: 1, fingers: 1 })
  .onAction(() => { this.onTap(); }))

// 双击点赞 + 单击暂停：GestureGroup(Exclusive) 解决冲突
Column() { /* 视频画面 */ }
  .gesture(
    GestureGroup(GestureMode.Exclusive,
      TapGesture({ count: 2 }).onAction(() => { this.like(); }),
      TapGesture({ count: 1 }).onAction(() => { this.togglePlay(); })
    )
  )

// 横向拖动换台/进度
Row() { /* ... */ }
  .gesture(
    PanGesture({ direction: PanDirection.Horizontal, distance: 20 })
      .onActionStart(() => { this.dragStart(); })
      .onActionUpdate((event: GestureEvent) => { this.updateDelta(event.offsetX); })
      .onActionEnd((event: GestureEvent) => { this.commitDelta(event.offsetX); })
  )
```

- 手势与滚动冲突：外层 `Scroll/List` 内使用 `PanGesture` 时加 `.gesture(..., GestureMask.IgnoreInternal)` 或给子组件 `.hitTestBehavior(HitTestMode.None)`；
- 播放器手势层建议**单独一层覆盖在 XComponent 上**，用 `.responseRegion()` 精确控制热区（如只让底部 40% 区域响应进度拖动）。

### 3.14 动画：animateTo / curves / transition / geometryTransition

```ts
// 1) 显式动画（推荐统一用 UIContext.animateTo；V2 下不要依赖 .animation()）
this.getUIContext().animateTo(
  { duration: 280, curve: curves.springMotion(0.38, 0.9), delay: 0 },
  () => { this.offsetX = 80; this.cardScale = 1.04; }
);

// 2) 弹性曲线（手势跟手/回弹）
curves.springMotion(                 // response, dampingFraction, overlapDuration
  0.4,                               // 响应时间（秒），越小越快
  0.8,                               // 阻尼比 0~1，1 无回弹
  0                                  // 重叠时间
);
curves.responsiveSpringMotion();     // 跟手更自然（滚动/拖拽用）

// 3) 出现/消失转场（列表项、弹层内容）
Column() { /* ... */ }
  .transition(
    TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: 24 }))
      .animation({ duration: 220, curve: Curve.EaseOut })
  )

// 4) 共享元素转场：海报 → 播放器（页面级）
Image(this.cover).geometryTransition('poster_' + this.videoId + ', follow: true')
// 目标页同 id 的 Image 也加 .geometryTransition(同一个 id)，配合 Navigation 转场即可"飞"过去
```

- `$SDK/api/@ohos.curves.d.ts:L371`（springMotion）、`:L398`（responsiveSpringMotion）
- `$SDK/component/common.d.ts:L5919`（animateTo 全局函数，已标注 `@useinstead UIContext.animateTo`）、`:L18966`（transition）、`:L21406/L21421`（geometryTransition）
- `$SDK/api/@ohos.arkui.UIContext.d.ts:L4703`（UIContext.animateTo）
- 动画规范建议：页面转场 250–320ms、按钮反馈 120–180ms、骨架呼吸 800–1200ms；统一用 `springMotion(0.4, 0.8)` 一套参数，避免风格发散。

### 3.15 模糊、材质与渐变（"精致布局"的核心）

```ts
// 1) 半透明毛玻璃导航栏（内容滚动到下方时出现）
Row() { /* 标题 + 操作 */ }
  .height(56).width('100%')
  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
    colorMode: ThemeColorMode.DARK,
    adaptiveColor: AdaptiveColor.DEFAULT,
    scale: 1.0
  })
  .backgroundColor('#66000000')

// 2) 局部背景模糊（播放器控件底栏）
Row() { /* controls */ }
  .backdropBlur(24, { grayscale: 0.2 })   // 半径 vp
  .backgroundColor('#33000000')

// 3) 渐变（海报遮罩、按钮、发光）
Column() { /* ... */ }
  .linearGradient({
    angle: 180,
    colors: [['#00000000', 0.0], ['#CC000000', 0.6], ['#000000', 1.0]]
  })

// 4) 播放器页动态取色背景（封面主色 → 渐变氛围光）
Column() { /* ... */ }
  .linearGradient({ angle: 160, colors: [['#40FF5A5F', 0.0], ['#00000000', 0.85]] })

// 5) 图像模糊（非材质）：Image 的 .blur(40) + .saturate(1.2)
Image(this.coverPixel).blur(40).opacity(0.5)
```

- `$SDK/component/common.d.ts:L17891`（backgroundBlurStyle）、`:L19596`（backdropBlur）、`:L20966`（linearGradient）、`:L19107`（linearGradientBlur，仅 1~12 级）
- `BlurStyle` 枚举：`Thin/Regular/Thick/BACKGROUND_*/COMPONENT_*/NONE`（`common.d.ts:L6614`）
- **性能**：模糊是高开销操作。列表项内不要用 `backdropBlur`；播放器/弹层等"少量大块"才用；模糊半径 > 40 时考虑先用 `Image.blur` 降采样图。

### 3.16 沉浸式与安全区（**全屏视频页必读**）

三种做法，推荐"全局沉浸式 + 局部 expandSafeArea"：

```ts
// 1) 窗口级：内容延伸到状态栏/导航条下（EntryAbility.onWindowStageCreate 或页面 aboutToAppear）
const win = await window.getLastWindow(this.getUIContext().getHostContext());
await win.setWindowLayoutFullScreen(true);
await win.setWindowSystemBarProperties({
  statusBarContentColor: '#FFFFFF',      // 状态栏文字白色（深色背景）
  navigationBarContentColor: '#FFFFFF'
});
// 顶部安全区高度（刘海/挖孔/状态栏）
const top: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
const topHeightVp: number = px2vp(top.topRect.height);

// 监听安全区变化（横竖屏切换/折叠屏）
win.on('avoidAreaChange', (data: window.AvoidAreaOptions) => {
  if (data.type === window.AvoidAreaType.TYPE_SYSTEM) { this.safeTop = px2vp(data.area.topRect.height); }
});

// 2) 组件级：只让背景/图片延伸进安全区，内容保持安全区内
Stack() {
  Image(this.coverPixel).width('100%').height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  Column() { /* 内容 */ }
}
```

- `$SDK/api/@ohos.window.d.ts:L2076`（getLastWindow）、`:L4523/L4546`（setWindowLayoutFullScreen）、`:L4713/L4736`（setWindowSystemBarProperties）、`:L4323`（getWindowAvoidArea）、`:L153`（AvoidAreaType：TYPE_SYSTEM/CUTOUT/KEYBOARD/NAVIGATION_INDICATOR）、`:L797`（AvoidArea：leftRect/topRect/rightRect/bottomRect）
- `$SDK/component/common.d.ts:L17263`（expandSafeArea）、`:L7749`（SafeAreaType.SYSTEM/CUTOUT/KEYBOARD）、`:L7790`（SafeAreaEdge.TOP/BOTTOM------

### 3.17 深色模式与资源限定目录

**硬编码颜色 = 适配失败**。统一用资源限定目录：

```text
entry/src/main/resources/
├── base/
│   ├── element/
│   │   ├── color.json          // 默认（浅色）颜色
│   │   ├── float.json          // 尺寸/圆角/字号
│   │   └── string.json
│   ├── media/                  // 图标/占位图
│   └── profile/
│       ├── main_pages.json     // 页面清单
│       └── network_config.json // 明文/GTS 配置（§9.2）
└── dark/
    └── element/
        └── color.json          // 深色模式覆盖（同名 key 自动生效）
```

```json
// base/element/color.json
{ "color": [
  { "name": "bg_page", "value": "#F5F5F7" },
  { "name": "text_primary", "value": "#1A1A1A" }
] }
// dark/element/color.json —— 同名 key 覆盖
{ "color": [
  { "name": "bg_page", "value": "#0B0B0F" },
  { "name": "text_primary", "value": "#F5F5F7" }
] }
```

```ts
Text('标题').fontColor($r('app.color.text_primary'))
Column().backgroundColor($r('app.color.bg_page'))

// 需要代码里判断当前模式时：
import { ConfigurationConstant } from '@kit.AbilityKit';
const ctx = this.getUIContext().getHostContext();
const isDark: boolean = ctx?.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
```

- `$SDK/api/@ohos.app.ability.Configuration.d.ts:L65`（colorMode）、`:L160`（fontSizeScale）
- **本项目是深色为主的视频 App**：建议 `base` 直接写深色（默认深色），`light/` 目录再做浅色适配；这样大多数页面不用改。若产品要求跟随系统，则 `base` 浅色 + `dark` 深色。
- 字体缩放：`Text` 支持 `.maxFontScale(1.3)`/`.minFontScale(0.8)`（`$SDK/component/text.d.ts:L214-L227`），标题类文本务必设上限，避免大字体撑破卡片；关键单行文本加 `.maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })`。
- 无障碍：交互控件加 `.accessibilityText('播放')`；图标按钮必须有文字或 `accessibilityText`；触摸热区 ≥ 40×40vp。

### 3.18 响应式断点

```ts
// 方案 A：媒体查询（简单场景）
import { mediaquery } from '@kit.ArkUI';
private listener: mediaquery.MediaQueryListener = mediaquery.matchMediaSync('(width>=840vp)');
aboutToAppear(): void {
  this.listener.on('change', (result: mediaquery.MediaQueryResult) => { this.isTablet = result.matches; });
}

// 方案 B：GridRow 断点栅格（推荐列表页布局）
GridRow({
  columns: { xs: 4, sm: 4, md: 8, lg: 12 },
  gutter: { x: 12, y: 12 },
  breakpoints: { value: ['320vp', '600vp', '840vp'], reference: BreakpointsReference.WindowSize }
}) {
  GridCol({ span: { xs: 4, sm: 4, md: 6, lg: 4 } }) { FeedCard() }
}

// 方案 C：UIContext 直接取当前宽度断点（API 18+）
const bp: WidthBreakpoint = this.getUIContext().getWindowWidthBreakpoint();
```

- `$SDK/api/@ohos.mediaquery.d.ts:L146`（matchMediaSync）、`:L49`（MediaQueryResult）、`:L87`（MediaQueryListener）
- `$SDK/component/grid_row.d.ts:L230`（BreakpointsReference）、`:L344`（reference）、`:L388`（columns）、`:L411`（breakpoints）
- `$SDK/api/@ohos.arkui.UIContext.d.ts:L5269`（getWindowWidthBreakpoint）
- 本项目建议：手机单列/双列瀑布流；平板 3~4 列；横屏时播放器全屏 + 详情页左右分栏（`GridRow` 的 `md/lg` 断点控制）。**不要为了平板单独写一套布局**，用栅格 + 条件渲染即可。

### 3.19 本节来源

- SDK：`$SDK/component/*.d.ts`（navigation/tabs/list/lazy_for_each/water_flow/swiper/refresh/search/text_input/image/symbolglyph/alert_dialog/common/progress/slider/grid_row）、`$SDK/api/@ohos.window.d.ts`、`@ohos.promptAction.d.ts`、`@ohos.curves.d.ts`、`@ohos.mediaquery.d.ts`、`@ohos.arkui.UIContext.d.ts`、`@ohos.app.ability.Configuration.d.ts`
- 官方文档：`ui/arkts-layout-development-*.md`、`ui/arkts-navigation-*.md`、`windowmanager/immersive-window-feature.md`、`windowmanager/launch-page-config.md`、`reference/apis-arkui/arkui-ts/ts-basic-components-symbolGlyph.md`

## 4. 媒体：AVPlayer / HLS / 自定义数据源 / 后台播放

> 本章是全项目风险最高的部分。**每条结论都标了等级**（A=SDK 声明、B=官方文档、C=待真机验证）。

### 4.1 AVPlayer 能力矩阵（A 级：本机 API 26 d.ts）

| 能力 | 接口 | d.ts |
| --- | --- | --- |
| 创建播放器 | `media.createAVPlayer(): Promise<AVPlayer>`（官方注释建议单应用最多 16 个实例） | `api/@ohos.multimedia.media.d.ts:L86`、`:L61` |
| 直接播 URL | `avPlayer.url = 'https://...m3u8'` | 属性 `:L2865` |
| 带自定义 HTTP 头 | `media.createMediaSourceWithUrl(url, headers?)` | `:L185` |
| 设置源+策略 | `avPlayer.setMediaSource(src: MediaSource, strategy?: PlaybackStrategy): Promise<void>` | `:L2469` |
| 本地 fd | `createMediaSourceWithFd(fdSrc)`（API 26）、`avPlayer.fdSrc` | `:L156`、`:L2899` |
| 自定义数据源 | `createMediaSourceWithDataSource(dataSrc)`（API 26） | `:L167` |
| 多码率 HTTP-FLV | `createMediaSourceWithStreamData(streams)`（API 19） | `:L197` |
| 自定义资源加载器 | `MediaSource.setMediaResourceLoaderDelegate(loader)`（API 18） | `:L4585` |
| 离线缓存 | `MediaSource.enableOfflineCache(enable)`（API 23） | `:L4602` |
| 本地 m3u8 MIME | `MediaSource.setMimeType(media.AVMimeTypes.APPLICATION_M3U8)` | `:L4574` |
| 播放控制 | `prepare/play/pause/stop/reset/release`（Promise） | `:L2189–L2328` |
| 跳转 | `seek(timeMs, SeekMode?)`；API 24 起直播也支持 seek | `:L2350` |
| 倍速 | `setSpeed(PlaybackSpeed)`；`setPlaybackRate(rate)` 0.125–8.0（API 24 及以下 0.125–4.0） | `:L3114`、`:L3133` |
| 音量 | `setVolume(0.0–1.0)` | `:L2363` |
| HLS/DASH 码率 | `setBitrate(bitrate)`（**仅 HLS/DASH**）+ `on('availableBitrates')` | `:L3151`、`:L3621` |
| 轨道 | `getTrackDescription/selectTrack/deselectTrack/getCurrentTrack/setTrackSelectionFilter` | `:L2378–L2492` |
| 外挂字幕 | `addSubtitleFromFd(...)` / `addSubtitleFromUrl(url)` | `:L2511`、`:L2524` |
| 播放区间 | `setPlaybackRange(startMs, endMs, mode?)` | `:L2647` |
| 统计 | `getPlaybackStatisticMetrics/getPlaybackInfo/getLoadedTimeRanges/getSeekableTimeRanges` | `:L2593`、`:L2533` |
| 视频渲染 | `surfaceId: string`（来自 XComponent） | `:L3053` |
| 缩放模式 | `videoScaleType?: VideoScaleType` | `:L3088` |
| 音频焦点模式 | `audioInterruptMode`（须首次 play 前设置） | `:L2971` |
| 音频流类型 | `audioRendererInfo`（视频默认 STREAM_USAGE_MOVIE） | `:L2987` |
| 循环 | `loop`；API 26 新增 `playlistLoopMode` | `:L2948`、`:L2958` |
| 起播偏好 | `PlaybackStrategy.preferredWidth/preferredHeight/preferredBufferDuration/preferredHdr/preferredAudioLanguage/preferredSubtitleLanguage/showFirstFrameOnPrepare/preferredBufferDurationForPlaying/enableSuperResolution` | `:L4620–L4740` |
| 播放列表 | `addPlaybackMediaSource/advanceToNextMediaSource/getMediaSources/clearPlaybackList` | `:L2740–L2830` |

**支持格式（B 级）**：HLS（m3u8 点播/直播）、HTTP-FLV、DASH、HTTPS；点播容器含 MP4/MPEG-TS/MKV 等。**HLS 原生支持，不需要 hls.js**。

### 4.2 状态机与事件

`AVPlayerState = 'idle' | 'initialized' | 'prepared' | 'playing' | 'paused' | 'completed' | 'stopped' | 'released' | 'error'`（`:L1935`）。

| 状态 | 允许操作 |
| --- | --- |
| idle | 设置 url / setMediaSource / **首次**设置 surfaceId / prepare |
| initialized | prepare |
| prepared | play / seek / setSpeed / setVolume / setBitrate / selectTrack / 更新 surfaceId |
| playing | pause / seek / setSpeed / setVolume / stop / 切轨道 |
| paused | play / seek / setSpeed / stop |
| completed | play（重播）/ seek / stop |
| stopped | play / reset |
| error | reset / release（先记录 `on('error')` 错误码） |
| released | 只能重建 |

**必须遵守**：
1. `on('stateChange')`、`on('error')` **必须在设置源之前注册**（官方：设置源后再注册可能收不到 initialized 过程事件）。
2. 操作前判断 `avPlayer.state`，非法调用抛 `5400102`。
3. 页面退出/切视频必须 `release()`；官方说明 prepared/playing/paused/completed 占用大量内存。

事件表（`media.d.ts`）：`stateChange`(`:L3244`)、`error`(`:L3640` 附近)、`timeUpdate`(`:L3451`)、`durationUpdate`(`:L3481`)、`bufferingUpdate`(`:L3509`)、`seekDone`(`:L3331`)、`speedDone`(`:L3361`)、`playbackRateDone`(`:L3389`)、`bitrateDone`(`:L3414`)、`availableBitrates`(`:L3621`)、`videoSizeChange`(`:L3563`)、`startRenderFrame`(`:L3534`)、`endOfStream`(`:L3299`)、`audioInterrupt`(`:L3592`)、`audioOutputDeviceChangeWithInfo`。

### 4.3 可抄代码：HLS 播放控制器

```ts
// player/VideoPlayerController.ets
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';

export const UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

export class VideoPlayerController {
  private player?: media.AVPlayer;
  private surfaceId: string = '';

  async init(onState: (s: string) => void, onError: (msg: string) => void): Promise<void> {
    this.player = await media.createAVPlayer();
    this.player.on('stateChange', (state: media.AVPlayerState, reason: media.StateChangeReason) => {
      onState(state);
    });
    this.player.on('error', (err: BusinessError) => {
      onError('播放错误 ' + err.code.toString() + ': ' + err.message);
    });
    this.player.on('timeUpdate', (t: number) => { /* 节流到 250ms 更新 UI */ });
    this.player.on('durationUpdate', (d: number) => { /* 更新总时长 */ });
    this.player.on('startRenderFrame', () => { /* 首帧：隐藏 loading */ });
    this.player.on('audioInterrupt', (info: audio.InterruptEvent) => {
      if (info.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE) { this.pause(); }
      else if (info.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) { this.play(); }
    });
  }

  attachSurface(surfaceId: string): void {
    this.surfaceId = surfaceId;
    if (this.player !== undefined && this.player.state === 'initialized') {
      this.player.surfaceId = surfaceId;
    }
  }

  async setHlsSource(m3u8Url: string, referer: string): Promise<void> {
    if (this.player === undefined) { return; }
    const headers: Record<string, string> = {
      'User-Agent': UA,
      'Referer': referer,
      'Accept': '*/*'
    };
    const src: media.MediaSource = media.createMediaSourceWithUrl(m3u8Url, headers);
    const strategy: media.PlaybackStrategy = {
      preferredBufferDuration: 3,
      preferredBufferDurationForPlaying: 1,
      showFirstFrameOnPrepare: true
    };
    if (this.surfaceId !== '') { this.player.surfaceId = this.surfaceId; }
    await this.player.setMediaSource(src, strategy);   // -> initialized
    await this.player.prepare();                       // -> prepared
    await this.player.play();                          // -> playing
  }

  async play(): Promise<void> {
    if (this.player !== undefined && (this.player.state === 'prepared' ||
        this.player.state === 'paused' || this.player.state === 'completed')) {
      await this.player.play();
    }
  }
  async pause(): Promise<void> {
    if (this.player !== undefined && this.player.state === 'playing') { await this.player.pause(); }
  }
  seek(timeMs: number): void {
    if (this.player === undefined) { return; }
    const s = this.player.state;
    if (s === 'prepared' || s === 'playing' || s === 'paused' || s === 'completed') {
      this.player.seek(timeMs, media.SeekMode.SEEK_CLOSEST);
    }
  }
  setRate(rate: number): void {
    if (this.player !== undefined && rate >= 0.125 && rate <= 8.0) {
      this.player.setPlaybackRate(rate);
    }
  }
  async release(): Promise<void> {
    if (this.player !== undefined) {
      this.player.off('stateChange');
      await this.player.release();
      this.player = undefined;
    }
  }
}
```

**错误码**：`5400101` 无内存、`5400102` 状态不允许、`5400105` 播放服务死亡、`5400106` 不支持格式、**`5411012` 明文 http 被禁（API 23+）**（见 §5.2 / §9.2）。

### 4.4 【Q1 核心】自定义 header 与 HLS 子请求的真实边界

#### 4.4.1 官方明确支持的（B 级，可直接用）

官方文档《使用AVPlayer设置播放URL》"情况三：设置HTTP请求头信息播放"给出示例并原文注释：

> "创建mediaSource实例对象，设置媒体来源，定制HTTP请求，如需要，可以键值对的形式设置User-Agent、Cookie、Referer等字段。"

```ts
let mediaSource: media.MediaSource = media.createMediaSourceWithUrl(url,
  { 'User-Agent': 'User-Agent-Value', 'Cookie': 'Cookie-Value', 'Referer': 'Referer-Value' });
```

`media.d.ts:L173-L177` 参数说明：`headers?: Record<string, string>` —— "HTTP header customized for streaming media pre-download"。
**结论（B）**：AVPlayer 支持给媒体流设 Referer/UA/Cookie 等自定义头，这是官方 API 能力。

#### 4.4.2 官方**没有**明确的（C 级，必须真机验证）

官方文档与 d.ts 都**没有**写"headers 会作用于 HLS 播放列表、子清单、分片、`EXT-X-KEY` 密钥请求的全部子请求"。存在三种可能：

| 可能 | 现象 | 应对 |
| --- | --- | --- |
| H1：headers 透传到同源所有子请求 | 一切正常，**零代理** | 最佳，去掉代理方案 |
| H2：只作用于主 m3u8 | 主清单 200，分片/密钥 403 | 需 §4.4.4 / §4.4.5 |
| H3：部分透传（清单走、key 不走） | 播到 key 才失败 | 同上 |

#### 4.4.3 真机验证方法（不请求上游，10 分钟出结论）

让 AVPlayer 请求**应用自己的 127.0.0.1 服务器**，服务器记录每个请求的 path 与 headers，再返回自造的多级 m3u8 + 分片。一次验证四件事：headers 是否透传、子清单/分片/KEY 是否走 HTTP、明文 http 是否放行、AES-128 key 请求是否发生。

1. 应用内起本地 HTTP 服务（§5.3，端口 0 由系统分配，`getLocalAddress()` 取端口）。
2. `/hls` 返回：
   ```m3u8
   #EXTM3U
   #EXT-X-VERSION:3
   #EXT-X-TARGETDURATION:4
   #EXT-X-KEY:METHOD=AES-128,URI="http://127.0.0.1:PORT/key?u=k1"
   #EXTINF:4.0,
   http://127.0.0.1:PORT/seg?u=s1
   #EXT-X-ENDLIST
   ```
   `/seg` 返回一段真实可解码的 TS（放一个 2 秒测试 ts 进 `rawfile`）；`/key` 返回 16 字节全 0 密钥。
3. AVPlayer 播 `http://127.0.0.1:PORT/hls?u=master`，headers 设 `{'Referer': 'https://verify.local/', 'User-Agent': 'verify-ua'}`。
4. 看日志：`/hls`、`/seg`、`/key` 各自收到的 `Referer/User-Agent/Range`。
5. 判定：H1 则三处都带 Referer；同时能看到 AVPlayer **是否主动请求 `/key`**（即 AES-128 是否由播放器处理，见 §4.9）。

> 该测试代码不要扔——它本身就是本地代理方案的雏形。

#### 4.4.4 方案 B：MediaSourceLoader（进程内接管，API 18+，A 级）

```ts
setMediaResourceLoaderDelegate(resourceLoader: MediaSourceLoader): void
type SourceOpenCallback  = (request: MediaSourceLoadingRequest) => number;   // 返回 >0 的 uuid
type SourceReadCallback  = (uuid: number, offset: number, length: number) => void;
type SourceCloseCallback = (uuid: number) => void;
interface MediaSourceLoadingRequest {
  url: string;                       // 播放器要打开的资源 URL
  header?: Record<string, string>;   // 播放器希望应用带上的请求头
  respondData(uuid: number, offset: number, buffer: ArrayBuffer): number;  // -2 停止 / -3 缓冲满
  respondHeader(uuid: number, header?: Record<string, string>, redirectUrl?: string): void; // 必须先于 respondData
  finishLoading(uuid: number, state: LoadingRequestError): void;
}
```

**能做到什么**：播放器把"要打开的资源"交给应用，应用用 `@ohos.net.http`（带 Referer/UA、可解 AES、可缓存）拉数据按 offset 推回。理论上可接管 HLS 的每个资源请求（主清单/子清单/分片/key）。

**三个限制**：
1. 官方只写"帮助播放器请求媒体数据"，**未明确 HLS `EXT-X-KEY` 密钥请求是否也经过 Loader**（C 级）。key 不走就断。
2. 回调同步返回、异步推数据：`read` 必须立即返回，数据到了再 `respondData`；要自己维护 `uuid -> 请求状态` 表（官方示例用 `HashMap`）。复杂度 ≈ 自写 HTTP 缓存层。
3. 并发、缓冲满（-3）、seek 乱序、取消（-2）、超时都要自己处理；出错表现为"卡住/花屏/无法起播"，无现成日志。

**建议**：只有实测 H2/H3 且本地代理方案被否时才上 Loader；**不要一上来就写 Loader**。

#### 4.4.5 方案 C：本地 127.0.0.1 TCP HTTP 代理（**推荐兜底**，可移植原 Rust 逻辑）

架构（与 `src-tauri/media.rs` 一一对应）：

```text
AVPlayer ──http──> 127.0.0.1:<动态端口>/hls?u=<百分号编码的原始 m3u8 URL>
                         ├─ /hls：@ohos.net.http 拉取（Referer+UA）→ rewrite_playlist 改写所有 URI → application/vnd.apple.mpegurl
                         ├─ /seg：拉取（Referer+UA）→ 若响应是 m3u8 则继续改写；否则原样返回
                         ├─ /key：拉取 AES key（带 Referer）→ 原样 16 字节返回
                         └─ /img：拉取 → AES-128-CBC 解密 → 返回 image/*
```

- 需要改写的位置（照抄 `media.rs:rewrite_playlist` 规格）：`#EXT-X-KEY:URI`、`#EXT-X-MAP:URI`、`#EXT-X-MEDIA:URI`、`#EXT-X-SESSION-KEY:URI`、`#EXT-X-PART:URI`、`#EXT-X-PRELOAD-HINT:URI`、`#EXT-X-DATERANGE`（丢弃 `URI/X-ASSET-LIST` 字段，保留时间线/SCTE-35）、普通分片行；`#EXT-X-CONTENT-STEERING` 整行丢弃。
- 百分号编码用 `encodeURIComponent` / `decodeURIComponent`（与原项目 `NON_ALPHANUMERIC` 等价可用）。
- 服务端实现见 §5.3（`socket.constructTCPSocketServerInstance()`，监听 `127.0.0.1`，`port: 0` 系统分配，`listen` 后 `getLocalAddress()` 取端口）。
- **明文策略**：AVPlayer 访问 `http://127.0.0.1` 属 cleartext，需 §9.2 放开 Media Kit（API 23+ 默认禁止），**必须做**。
- 支持 `Range` 透传（`206 + Content-Range`）；上游失败返回 502 让 UI 提示"切换线路"。

#### 4.4.6 决策树

```text
实测 §4.4.3
├─ H1（headers 全透传）且 AES-128 可播 → 直连 createMediaSourceWithUrl + headers，零代理
├─ headers 只到主清单/分片 403 → 方案 C 本地代理（推荐，逻辑与原 Rust 一致）
├─ 不接受本地端口/明文策略 → 方案 B MediaSourceLoader（先验证 key 请求是否经过 loader）
└─ 任何情况都建议保留"直连/代理"可配置开关，避免上游策略变化导致全挂
```

### 4.5 XComponent 渲染视频（surfaceId）

```ts
@ComponentV2
export struct VideoSurface {
  private controller: XComponentController = new XComponentController();
  @Event onSurfaceReady: (surfaceId: string) => void = (surfaceId: string) => {};
  build() {
    XComponent({
      id: 'hg_video_surface',
      type: XComponentType.SURFACE,
      libraryname: '',
      controller: this.controller
    })
      .onLoad(() => { this.onSurfaceReady(this.controller.getXComponentSurfaceId()); })
      .onDestroy(() => { /* 通知 controller 解绑 */ })
      .width('100%').height('100%').backgroundColor(Color.Black)
  }
}
```

- `$SDK/component/xcomponent.d.ts:L494-L500`（参数对象）、`:L171`（getXComponentSurfaceId）、`:L585`（onLoad）、`:L597`（onDestroy）；`$SDK/component/enums.d.ts:L3797`（XComponentType.SURFACE=0/TEXTURE=2）
- **坑**：surfaceId 必须在 `prepare()` 前设置；转屏/全屏导致 surface 重建时要**重新赋值**（prepared/playing/paused 状态可更新）；"有声音没画面"99% 是 surfaceId 没设/设晚，用 `on('startRenderFrame')` 判断。

### 4.6 seek / 倍速 / 音轨 / 字幕 / 码率

```ts
// 进度：拖动中只更新 UI，松手才 seek
Slider({ value: this.dragMs, min: 0, max: this.durationMs, step: 100 })
  .onChange((value: number, mode: SliderChangeMode) => {
    this.dragMs = value;
    if (mode === SliderChangeMode.End) { this.controller.seek(value); }
  })

this.player.setPlaybackRate(1.25);                    // 0.125–8.0
const tracks: media.MediaDescription[] = await this.player.getTrackDescription();
await this.player.selectTrack(index, media.SwitchMode.SMOOTH);   // 平滑切音轨
await this.player.addSubtitleFromUrl('https://example.com/sub.vtt');
this.player.on('availableBitrates', (bitrates: Array<number>) => { this.availableBitrates = bitrates; });
this.player.setBitrate(bitrates[index]);              // 仅 HLS/DASH；触发 on('bitrateDone')
```

- 倍速下建议调大 `PlaybackStrategy.preferredBufferDuration`；官方建议最大缓冲 ≈ 起播水位 + 2 秒。
- 直播流：`duration = -1`、`currentTime` 默认 -1，用 `getPlaybackPosition()/getCurrentPresentationTimestamp()`。

### 4.7 后台播放 / 锁屏控制：AVSession + 长时任务

规则（B 级）：流类型为 `STREAM_USAGE_MUSIC/MOVIE/AUDIOBOOK/GAME` 的后台播放**必须同时**接入 AVSession + 申请 `AUDIO_PLAYBACK` 长时任务，否则退后台被静音冻结；接了 AVSession 后通知由 AVSession 发（API 20+）。权限 `ohos.permission.KEEP_BACKGROUND_RUNNING`；module.json5 配 `"backgroundModes": ["audioPlayback"]`。

```ts
import { avSession as AVSessionManager } from '@kit.AVSessionKit';

const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
const session = await AVSessionManager.createAVSession(context, 'hg_player', 'video');
await session.activate();
await session.setAVMetadata({
  assetId: this.videoId, title: this.title, artist: this.author, album: 'HGhub',
  duration: this.durationMs > 0 ? this.durationMs : undefined
});
await session.setAVPlaybackState({
  state: AVSessionManager.PlaybackState.PLAYBACK_STATE_PLAY,
  speed: this.rate,
  position: { elapsedTime: this.currentMs, updateTime: Date.now() }
});
session.on('play', () => { this.controller.play(); });
session.on('pause', () => { this.controller.pause(); });
session.on('seek', (timeMs: number) => { this.controller.seek(timeMs); });

// 退后台时（UIAbility.onBackground）申请长时任务
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent } from '@kit.AbilityKit';
const info: wantAgent.WantAgentInfo = {
  wants: [{ bundleName: 'com.example.hghub', abilityName: 'EntryAbility' }],
  actionType: wantAgent.OperationType.START_ABILITY,
  requestCode: 0,
  wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
};
const agent: wantAgent.WantAgent = await wantAgent.getWantAgent(info);
await backgroundTaskManager.startBackgroundRunning(context, ['audioPlayback'], agent);
```

- `$SDK/api/@ohos.multimedia.avsession.d.ts:L64`（createAVSession）、`:L1673`（activate）、`:L313`（setAVMetadata）、`:L367`（setAVPlaybackState）、`:L829/L859/L1236`（on play/pause/seek）、`:L2972`（AVMetadata）、`:L3419`（AVPlaybackState）、`:L4016`（PlaybackState 常量）
- `$SDK/api/@ohos.resourceschedule.backgroundTaskManager.d.ts:L771`（startBackgroundRunning bgModes）、`:L913`（stop）、`:L1116`（AUDIO_PLAYBACK）
- **画中画（PiP）**：API 26 SDK 仅在 `window.GlobalWindowMode.PIP = 1 << 3`（`:L1754`）出现"系统窗口模式"，**未发现三方应用主动进入 PiP 的公开 API**。结论：**一期不做 PiP**，只做后台音频 + 锁屏控制（C）。

### 4.8 音频焦点与中断

```ts
this.player.audioInterruptMode = audio.InterruptMode.SHARE_MODE;   // 须首次 play 前
this.player.on('audioInterrupt', (event: audio.InterruptEvent) => {
  if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE) {
    this.pauseBySystem = true; this.controller.pause();
  } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
    if (this.pauseBySystem) { this.controller.play(); }
  } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
    this.controller.release();
  }
});
```

- `$SDK/api/@ohos.multimedia.audio.d.ts:L1583`（InterruptMode）、`:L1677`（InterruptHint）、`:L1790`（InterruptEvent: eventType/forceType/hintType）
- 原则：**用户主动暂停不得被 RESUME 自动恢复**（用 `pauseBySystem` 区分）。

### 4.9 【Q4】HLS AES-128：原生还是代理？

**事实（A 级）**：AVPlayer/MediaSource 声明中**没有任何"HLS AES-128"字样**；也没有 key 请求回调；`setDecryptionConfig` 只针对 **DRM（MediaKeySession）**，与 HLS `EXT-X-KEY:METHOD=AES-128` 不是一回事。
**事实（B 级）**：官方《流媒体播放》文档未提 HLS 标准加密处理方式，示例均为明文流。

**推论（C 级，必须真机验证）**：
- 标准 HLS AES-128 是播放器常规能力，**大概率原生处理**（验证方法：§4.4.3 观察 AVPlayer 是否主动请求 `/key` 且能出画面）。
- 但"key 请求是否带 Referer"是另一个问题：即使原生支持 AES-128，若 key 被 CDN 校验 Referer 而播放器不透传 headers → 解密失败。
- 若原生不支持或 key 请求无法带 Referer：**走方案 C 代理**——代理请求 key（带 Referer）、下载分片后**在代理内解密**，对播放器暴露"已解密明文分片 + 去掉 #EXT-X-KEY 的 m3u8"。这是最可控兜底（等价原 hls.js 行为），代价是代理做 AES 解密（`AES128|CBC|NoPadding` + 手动去 PKCS7，§6.1）。

### 4.10 播放器 UI 自绘方案

```text
Stack
├─ VideoSurface（XComponent，铺满，expandSafeArea）
├─ 手势层（单击暂停 / 双击点赞 / 横滑进度 / 竖滑亮度音量 / 长按倍速）
├─ 顶部渐变条：返回 + 标题 + 更多（linearGradient 或 backgroundBlurStyle）
├─ 中部：LoadingProgress / 首帧封面 / 错误重试
└─ 底部控制条（backdropBlur 材质）：进度条 + 播放/暂停 + 时间 + 倍速/清晰度/线路/全屏
```

体验优化清单：
1. **首帧**：先显示封面 + 骨架，`startRenderFrame` 后淡出（`animateTo` 150ms）。
2. **预起播**：列表点击立即 `createAVPlayer` + `setMediaSource`，转场期间就开始 prepare（官方最佳实践：短视频可预建多个 AVPlayer，最多 16 个）。
3. **缓冲**：`bufferingUpdate` 只在 > 200ms 才显示 loading，避免闪烁。
4. **进度**：`timeUpdate` 节流 250ms；拖动时暂停自动进度更新。
5. **长按倍速**：`setPlaybackRate(2.0)`，松手恢复。
6. **切集**：复用同一 AVPlayer（`reset()` → 重新 `setMediaSource`），减少创建开销。

### 4.11 本节来源

- SDK：`$SDK/api/@ohos.multimedia.media.d.ts`、`@ohos.multimedia.avsession.d.ts`、`@ohos.multimedia.audio.d.ts`、`@ohos.resourceschedule.backgroundTaskManager.d.ts`、`$SDK/component/xcomponent.d.ts`、`enums.d.ts`
- 官方文档：`media/media/using-avplayer-for-playback.md`、`media/media/playback-url-setting-method.md`、`media/media/streaming-media-playback-development-guide.md`、`media/media/video-playback.md`、`media/avsession/avsession-access-scene.md`、`media/avsession/avsession-background-scene.md`、`task-management/continuous-task.md`
- 参考实现（只读）：`src-tauri/src/media.rs`、`src-tauri/src/net.rs`、`src-tauri/src/lib.rs`

## 5. 网络

### 5.1 @ohos.net.http：能力与可抄代码

| 能力 | 说明 | d.ts |
| --- | --- | --- |
| 请求方法 | GET/POST/HEAD/PUT/DELETE/TRACE/CONNECT/OPTIONS | `RequestMethod` `:L1927` |
| 自定义头 | `header?: Object`（键值对；默认 content-type 按方法推断） | `:L171` |
| 超时 | `connectTimeout`（默认 60000ms）、`readTimeout`（默认 60000ms） | `:L182/L191` |
| 响应类型 | `expectDataType: HttpDataType.STRING/OBJECT/ARRAY_BUFFER` | `:L135`、`:L2409` |
| 大响应 | 默认单次最多 5MB；更大用 `maxLimit` 或 `requestInStream`（流式最多 50MB 限制同理可绕开） | `:L329`、`:L1611` |
| 流式下载 | `requestInStream()` + `on('headersReceive')`、`on('dataReceive')`、`on('dataEnd')`、`on('dataReceiveProgress')` | `:L1611`、`:L1759`、`:L1800`、`:L1825`、`:L1855` |
| 缓存 | `usingCache`（默认 true），`createHttpResponseCache(size)` | `:L146`、`:L2802` |
| 协议版本 | `usingProtocol`（HTTP1.1/2/3；HTTPS 默认 2，失败回退 1.1） | `:L200`、`:L2364` |
| 证书 | `caPath/caData/clientCert/certificatePinning/remoteValidation` | `:L230`、`:L1284`、`:L353` |
| 并发优先级 | `priority` 1–1000 | `:L156` |
| 响应 | `result`、`responseCode`、`header`、`cookies`、`performanceTiming` | `:L2446` |
| 错误码 | `2300997` 明文被禁；`2300006` 域名解析失败；`2300007` 连接失败；`2300028` 超时等 | `:L1362` 等 |

```ts
// network/HttpClient.ets —— 全项目统一出口（带 Referer/UA、重试、超时、日志）
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

export const UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

// 返回二进制（封面密文 / 分片 / m3u8）
export async function fetchBytes(url: string, referer: string, range?: string): Promise<ArrayBuffer> {
  const req = http.createHttp();
  try {
    const header: Record<string, string> = { 'User-Agent': UA, 'Referer': referer, 'Accept': '*/*' };
    if (range !== undefined) { header['Range'] = range; }
    const resp: http.HttpResponse = await req.request(url, {
      method: http.RequestMethod.GET,
      header: header,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 10000,
      readTimeout: 20000,
      usingCache: false,
      maxLimit: 32 * 1024 * 1024
    });
    if (resp.responseCode !== http.ResponseCode.OK && resp.responseCode !== 206) {
      throw new Error('HTTP ' + resp.responseCode.toString());
    }
    if (resp.result instanceof ArrayBuffer) { return resp.result; }
    throw new Error('unexpected result type');
  } finally {
    req.destroy();          // 必须销毁
  }
}

// 返回 JSON 文本（接口）
export async function fetchText(url: string, referer: string): Promise<string> {
  const req = http.createHttp();
  try {
    const resp = await req.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.STRING,
      header: { 'User-Agent': UA, 'Referer': referer, 'Accept': 'application/json' },
      connectTimeout: 10000,
      readTimeout: 15000
    });
    if (resp.responseCode !== http.ResponseCode.OK) { throw new Error('HTTP ' + resp.responseCode); }
    return resp.result as string;
  } finally { req.destroy(); }
}

// 大文件流式下载（缓存视频/大图，避免一次性占内存）
export async function downloadToFile(url: string, referer: string): Promise<void> {
  const req = http.createHttp();
  const chunks: ArrayBuffer[] = [];
  req.on('dataReceive', (data: ArrayBuffer) => { chunks.push(data); });
  req.on('dataEnd', () => { /* 全部收完，写文件（§7.2） */ });
  await req.requestInStream(url, {
    method: http.RequestMethod.GET,
    header: { 'User-Agent': UA, 'Referer': referer },
    connectTimeout: 10000,
    readTimeout: 60000
  });
}
```

**注意**：
- 每次请求必须 `destroy()`，否则句柄泄漏（长时间播放/翻页会触发）。
- 请求头里不要出现换行/非法字符；`Referer` 必须带 `scheme://host/` 结尾（与原 `net.rs` 的 `format!("{}/", base())` 一致）。
- **重定向**：`@ohos.net.http` 默认跟随重定向（最多若干跳）；如果要做"每一跳重新校验"的安全策略（原项目做得很细），需要手动处理 `Location`（`header` 里取）并自行限制跳数——短剧场景一般默认跟随即可，但**跨域重定向到内网需要有防护**（原项目 `network_policy.rs` 的等价物，二期再做）。

### 5.2 【Q2】明文 HTTP 策略（**必读，直接影响代理方案与接口可用性**）

**默认值（B 级，官方 `network/http-request.md`）**：

| 组件 | 默认是否允许明文 HTTP | 说明 |
| --- | --- | --- |
| Network Kit（`@ohos.net.http`） | **允许**（API 18 起默认支持；API 20 起可配置） | 但配置了 `domain-config.cleartextTrafficPermitted=false` 就抛 `2300997` |
| Media Kit（AVPlayer） | **不允许**（API 23 起默认禁止） | 抛 `5411012`；必须显式放开 |
| ArkWeb | 不允许（默认 false） | 本项目禁用 WebView，无关 |
| Request/RemoteCommunication | 允许 | 与本项目无关 |

**结论**：
1. 上游接口如果是 `http://`，`@ohos.net.http` **默认可用**。
2. **AVPlayer 播放 `http://` 流（包括 `http://127.0.0.1` 本地代理）默认会被拦截**，必须配置 `network_config.json`（API 23+）放开 Media Kit 明文。
3. 明文开关按 **base-config（应用级）→ domain-config（域名级）→ component-config（组件级）** 优先级覆盖。

```json5
// entry/src/main/resources/base/profile/network_config.json —— 文件名与目录固定
{
  "network-security-config": {
    "base-config": {
      "cleartextTrafficPermitted": false          // 全局默认收紧：只放行必要域名
    },
    "domain-config": [
      {
        "domains": [ { "include-subdomains": true, "name": "127.0.0.1" } ],
        "cleartextTrafficPermitted": true          // 本地代理（如采用）必须放行
      },
      {
        "domains": [ { "include-subdomains": false, "name": "example-api.com" } ],
        "cleartextTrafficPermitted": true          // 上游接口若是 http，按域名精确放行
      }
    ],
    "component-config": {
      "Network Kit": true,                         // API 20+ 可配；允许 http 组件走明文（受 domain 限制）
      "Media Kit": true                            // API 23+ 可配；AVPlayer 明文开关，默认 false
    }
  }
}
```

- 依据：官方 `network/http-request.md` "明文HTTP访问权限配置说明"（配置示例与字段表）；`@ohos.net.networkSecurity.d.ts` 的 `isCleartextPermitted()/isCleartextPermittedByHostName()`（API 18+，需 `ohos.permission.INTERNET`）。
- **验证**：`networkSecurity.isCleartextPermittedByHostName('127.0.0.1')` 返回 true；播放 `http://127.0.0.1:<port>/hls` 不再报 5411012。
- **语义细节（C 级，待真机）**：`component-config` 的 true/false 与 `domain-config` 的优先级、以及 "127.0.0.1/localhost 是否有系统级豁免"，官方文档没有逐条说明。建议**同时**配 `domain-config(127.0.0.1)` 与 `component-config["Media Kit"]=true`，双保险。
- 该文件**不需要**在 module.json5 里声明（按官方文档路径放置即可；如构建未打包，检查 `resources/base/profile/` 是否在 HAP 内——`build` 后解包 `entry-default-unsigned.hap` 验证，这一步列入 §12）。

### 5.3 【备选方案】`@ohos.net.socket` 本地 TCP HTTP 代理（**方案 C 的实现基础**）

**先回答 Lead 的问题（A 级，全部来自 `@ohos.net.socket.d.ts` API 26 真实签名）**：

| 项目 | 结论 |
| --- | --- |
| 服务器接口 | `socket.constructTCPSocketServerInstance(): TCPSocketServer`（`:L115`），API 10+ |
| 绑定+监听 | `listen(address: NetAddress): Promise<void>`（`:L3314`）；文档：一次调用完成 bind/listen/accept；**bind 失败时系统随机分配端口** |
| 端口选择 | `NetAddress { address: string; port?: number; family?: number }`（`:L2249`）；`port: 0` 表示系统分配，随后用 `getLocalAddress()` 取实际端口（`:L3430`） |
| 事件 | `on('connect', callback: Callback<TCPSocketConnection>)`（`:L3447`）、`on('error')`（`:L3477`） |
| 权限 | **`ohos.permission.INTERNET`**（`listen/close/getState/getSocketFd` 全部标注 `@permission`，未授权抛 `201`） |
| 并发 | 文档说明 "Multiple threads are used to process client data concurrently"，即 accept 与多连接由系统处理，应用只需处理每个 `TCPSocketConnection` |
| 连接对象 | `TCPSocketConnection`：`clientId`、`on('message', Callback<SocketMessageInfo>)`、`on('close')`、`send(TCPSendOptions)`、`getRemoteAddress()/getLocalAddress()`、`close()` |
| 超时/保活 | `setExtraOptions(TCPExtraOptions)`：`keepAlive/OOBInline/TCPNoDelay/receiveBufferSize/sendBufferSize/socketTimeout` |
| 其他 | `getSocketFd()`（API 23+，可拿 fd 做 NAPI 高级玩法，不建议） |

```ts
// player/LocalHlsProxy.ets —— 本地 HLS 代理服务器的骨架（可直接演进为完整实现）
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

export class LocalHlsProxy {
  private server?: socket.TCPSocketServer;
  private port: number = 0;

  get baseUrl(): string { return 'http://127.0.0.1:' + this.port.toString(); }

  async start(): Promise<void> {
    this.server = socket.constructTCPSocketServerInstance();
    const addr: socket.NetAddress = { address: '127.0.0.1', port: 0 };   // 系统分配端口
    await this.server.listen(addr);
    const local: socket.NetAddress = await this.server.getLocalAddress();
    this.port = local.port ?? 0;
    this.server.on('connect', (client: socket.TCPSocketConnection) => { this.onClient(client); });
    this.server.on('error', (err: BusinessError) => { console.error('proxy server error: ' + err.code); });
  }

  async stop(): Promise<void> {
    if (this.server !== undefined) {
      await this.server.close();      // 只停止监听，不断已建立连接
      this.server = undefined;
    }
  }

  private onClient(client: socket.TCPSocketConnection): void {
    let pending: Uint8Array = new Uint8Array(0);
    client.on('error', () => { client.close(); });
    client.on('message', (info: socket.SocketMessageInfo) => {
      pending = LocalHlsProxy.concat(pending, new Uint8Array(info.message));
      const text: string = new util.TextDecoder('utf-8').decodeWithStream(pending);
      const headerEnd: number = text.indexOf('\r\n\r\n');
      if (headerEnd < 0) { return; }                       // 头没收全
      const head: string = text.substring(0, headerEnd);
      const requestLine: string = head.split('\r\n')[0];  // GET /hls?u=... HTTP/1.1
      const parts: string[] = requestLine.split(' ');
      const target: string = parts.length > 1 ? parts[1] : '/';
      this.route(target).then((resp: ArrayBuffer) => {
        client.send({ data: resp }).then(() => client.close()).catch(() => client.close());
      }).catch(() => {
        client.send({ data: LocalHlsProxy.errorResponse(502) }).then(() => client.close()).catch(() => client.close());
      });
    });
  }

  // 路由：/hls /seg /key /img —— 用 @ohos.net.http 带 Referer 拉取
  private async route(target: string): Promise<ArrayBuffer> {
    const u: string = LocalHlsProxy.queryParam(target, 'u');
    if (u === '') { return LocalHlsProxy.errorResponse(400); }
    if (target.startsWith('/hls')) {
      const raw: ArrayBuffer = await fetchBytes(u, REFERER);        // §5.1
      const text: string = new util.TextDecoder('utf-8').decodeWithStream(new Uint8Array(raw));
      const rewritten: string = rewritePlaylist(u, text, this.baseUrl);   // 见 §4.4.5 规格
      return LocalHlsProxy.response(200, 'application/vnd.apple.mpegurl', new util.TextEncoder().encodeInto(rewritten));
    }
    if (target.startsWith('/seg') || target.startsWith('/key')) {
      const bytes: ArrayBuffer = await fetchBytes(u, REFERER);
      const isM3u8: boolean = new Uint8Array(bytes).length > 7;
      return LocalHlsProxy.response(200, 'application/octet-stream', new Uint8Array(bytes));
    }
    return LocalHlsProxy.errorResponse(404);
  }

  private static concat(a: Uint8Array, b: Uint8Array): Uint8Array {
    const out = new Uint8Array(a.length + b.length);
    out.set(a, 0); out.set(b, a.length);
    return out;
  }
  private static queryParam(target: string, key: string): string {
    const idx: number = target.indexOf('?');
    if (idx < 0) { return ''; }
    const pairs: string[] = target.substring(idx + 1).split('&');
    for (let i = 0; i < pairs.length; i++) {
      const kv: string[] = pairs[i].split('=');
      if (kv.length === 2 && kv[0] === key) { return decodeURIComponent(kv[1]); }
    }
    return '';
  }
  private static response(status: number, contentType: string, body: Uint8Array): ArrayBuffer {
    const head: string = 'HTTP/1.1 ' + status.toString() + ' OK\r\n' +
      'Content-Type: ' + contentType + '\r\n' +
      'Access-Control-Allow-Origin: *\r\n' +
      'Content-Length: ' + body.length.toString() + '\r\n' +
      'Connection: close\r\n\r\n';
    return LocalHlsProxy.concat(new util.TextEncoder().encodeInto(head), body).buffer as ArrayBuffer;
  }
  private static errorResponse(status: number): ArrayBuffer {
    return LocalHlsProxy.response(status, 'text/plain', new Uint8Array(0));
  }
}
// 说明：REFERER / rewritePlaylist / fetchBytes 为工程内函数，分别对应 §5.1、§4.4.5、`media.rs:rewrite_playlist`。
```

**实现注意**（踩坑点，按优先级）：
1. **必须支持 `Range`**：HLS 播放器可能对分片发 `Range: bytes=...`；代理要透传 `Range`，上游返回 206 时透传 `206 + Content-Range`。否则偶发花屏/起播慢。
2. **不要把 4xx/5xx 透传给播放器**：AVPlayer 对 HTTP 状态敏感，上游 403 时返回 403 会让播放器直接 error（反而利于暴露问题，但体验差）；建议返回 200 + 空体由应用兜底重试。**推荐**：上游失败时返回 502，并让 UI 显示"线路异常，请切换线路"（比静默黑屏好）。
3. **请求体/管线**：只处理 `GET/HEAD`；收到 `

` 即可路由，不要等 body。
4. **连接管理**：每个连接处理完就 `close()`（`Connection: close`），避免 keep-alive 状态机复杂度；HLS 分片数量多，close-per-request 在短剧码率下可接受（如后续有性能问题再实现 keep-alive）。
5. **并发**：AVPlayer 可能同时发多个分片请求；`on('message')` 回调里不要做同步重活，把 fetch 丢给异步 Promise；建议加一个全局信号量（最多 4–6 个并发上游请求，§8.4）。
6. **不要在主线程做 AES 解密大分片**：单分片 200KB~2MB，解密应在 taskpool（§6 / §8.2）；代理服务器本身在主线程是 OK 的（socket 回调轻量），但解析/解密要异步。
7. **端口**：每次启动端口不同，代理 URL 由 `baseUrl` 动态拼；播放器切集时 m3u8 要重新改写（因为前缀不同）——**用同一个代理实例并保持端口不变**，只在 `start()` 时分配一次。

### 5.4 TLS 与证书校验

- 默认走系统 CA，无需配置。需要自定义 CA/客户端证书时用 `caPath/caData/clientCert/clientEncCert`（`http.d.ts:L220-L260`）。
- **证书固定（可选）**：`certificatePinning: { publicKeyHash: '<sha256-base64>', type: 'sha256' }`（`http.d.ts:L1284`；对应官方文档"预置证书公钥哈希值"章节）。注意：固定的是**证书链上所有证书**的哈希，服务端轮换证书会失败，**必须配降级/更新策略**（原项目没做 pinning，建议二期评估，不要一期强上）。
- `remoteValidation: 'system' | 'skip' | 自定义回调`（`http.d.ts:L353/L617`）——`skip` 仅用于调试，**禁止**进生产包。
- **AVPlayer 的 HTTPS**：走系统信任链，**没有 pinning 配置项**；如需 pinning 只能走本地代理（自己用 http 客户端 + pinning 拉流，再喂给 AVPlayer）。
- 协议版本：`usingProtocol: http.HttpProtocol.HTTP2` 可强制；HLS 分片场景建议默认（HTTP2 复用连接，更快）。

### 5.5 网络状态监听

```ts
import { connection } from '@kit.NetworkKit';

const netConn: connection.NetConnection = connection.createNetConnection();
netConn.on('netAvailable', (handle: connection.NetHandle) => { /* 恢复网络：重试失败请求 */ });
netConn.on('netLost', (handle: connection.NetHandle) => { /* 断网：暂停自动重试，提示用户 */ });
netConn.on('netCapabilitiesChange', (info: connection.NetCapabilityInfo) => {
  // info.netCapabilities.bearerTypes 可判断 WIFI/CELLULAR，蜂窝下可降低码率/禁用预加载
});
netConn.register((err) => { /* 注册成功才回调 */ });
```

- `$SDK/api/@ohos.net.connection.d.ts:L89`（createNetConnection）、`:L1490`（netAvailable）、`:L1548`（netLost）、`:L1519`（netCapabilitiesChange）、`:L1808`（NetCapabilities）
- 注意：`register()` 后才生效；页面销毁 `unregister()`。

### 5.6 本节来源

- SDK：`$SDK/api/@ohos.net.http.d.ts`、`@ohos.net.socket.d.ts`、`@ohos.net.networkSecurity.d.ts`、`@ohos.net.connection.d.ts`
- 官方文档：`network/http-request.md`（含明文 HTTP 配置与证书固定）、`network/socket-connection.md`、`network/net-connection-manager.md`、`network/net-dns.md`
- 参考实现（只读）：`src-tauri/src/net.rs`（Referer/UA/重试/代理）、`src-tauri/src/network_policy.rs`（重定向与内网防护）

---

## 6. 加密与编码

### 6.1 AES-128-CBC 解密（封面/分片通用）

**原项目参数（只读自 `src-tauri/src/media.rs:26-27`）**：算法 AES-128-CBC，**key/iv 为固定常量**（`IMG_KEY`/`IMG_IV`，各 16 字节），解密后**手动去 PKCS7 padding**（实现里还做了"非法 padding 不删"的兜底，说明部分密文可能不是标准 PKCS7）。

```ts
// crypto/AesCbc.ets
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

// 与 Rust 的 aes_cbc_decrypt + strip_padding 等价
export function aesCbcDecryptNoPadding(data: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array {
  const keyGen: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
  const symKey: cryptoFramework.SymKey = keyGen.convertKeySync({ data: key });
  const ivSpec: cryptoFramework.IvParamsSpec = {
    algName: 'IvParamsSpec',
    iv: { data: iv }
  };
  const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES128|CBC|NoPadding');
  cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, ivSpec);
  const out: cryptoFramework.DataBlob = cipher.doFinalSync({ data: data });
  return stripPkcs7(out.data);
}

// 与原项目 strip_padding 一致：仅当末尾 1..16 字节都等于 pad 值时才截断
function stripPkcs7(buf: Uint8Array): Uint8Array {
  if (buf.length === 0) { return buf; }
  const pad: number = buf[buf.length - 1];
  if (pad <= 0 || pad > 16 || pad > buf.length) { return buf; }
  for (let i = buf.length - pad; i < buf.length; i++) {
    if (buf[i] !== pad) { return buf; }
  }
  return buf.subarray(0, buf.length - pad);
}

// 备选写法（标准 PKCS7，交给框架去 padding；密文 padding 异常时会抛错，需 try/catch）
export function aesCbcDecryptPkcs7(data: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array {
  const keyGen = cryptoFramework.createSymKeyGenerator('AES128');
  const symKey = keyGen.convertKeySync({ data: key });
  const cipher = cryptoFramework.createCipher('AES128|CBC|PKCS7');
  cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, { algName: 'IvParamsSpec', iv: { data: iv } });
  return cipher.doFinalSync({ data: data }).data;
}
```

- `$SDK/api/@ohos.security.cryptoFramework.d.ts`：`createSymKeyGenerator`、`createCipher`、`Cipher.initSync/doFinalSync`、`IvParamsSpec`、`CryptoMode.DECRYPT_MODE`、`DataBlob{data: Uint8Array}`（行号见 `L1669/L1459/L1796/L1944/L212/L490/L132`）
- 官方文档：`security/CryptoArchitectureKit/crypto-sym-encrypt-decrypt-spec.md`（AES 7 种模式与填充规格：CBC+PKCS7 合法；**AES 分组 16 字节，PKCS5 与 PKCS7 等价**）
- **性能**：`doFinalSync` 是同步调用，大分片（>512KB）会阻塞 UI 线程 → 放 taskpool（§8.2）。封面（一般 < 300KB）在主线程可接受，但仍建议异步。

### 6.2 Base64 / UTF-8 / 随机数

```ts
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

const b64: util.Base64Helper = new util.Base64Helper();
const text: string = b64.encodeToStringSync(new Uint8Array([1, 2, 3]));       // "AQID"
const bytes: Uint8Array = b64.decodeSync('AQID');                             // Uint8Array

const encoder = new util.TextEncoder();
const utf8: Uint8Array = encoder.encodeInto('你好');                          // UTF-8 编码
const decoder = new util.TextDecoder('utf-8');
const str: string = decoder.decodeWithStream(utf8);

// 安全随机（IV/nonce/临时 token）
const random: cryptoFramework.Random = cryptoFramework.createRandom();
const iv: Uint8Array = random.generateRandomSync(16).data;
```

- `$SDK/api/@ohos.util.d.ts:L1739`（Base64Helper）、`:L1790`（encodeToStringSync）、`:L1806`（decodeSync）、`:L430`（TextEncoder）、`:L278`（TextDecoder）
- `$SDK/api/@ohos.security.cryptoFramework.d.ts:L1126`（createRandom）、`:L1072`（generateRandomSync）
- **代码中禁止 `atob/btoa`（不存在）**；也禁止自己写 base64（用 Base64Helper）。

### 6.3 【Q5】封面解密 → PixelMap 的正确姿势

```ts
// image/CoverLoader.ets
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { aesCbcDecryptNoPadding } from '../crypto/AesCbc';
import { fetchBytes } from '../network/HttpClient';

// 注意：key/iv 从 src-tauri/src/media.rs 的 IMG_KEY/IMG_IV 取，不要在本文件另存多份
const COVER_KEY: Uint8Array = new Uint8Array([/* 16 bytes */]);
const COVER_IV: Uint8Array = new Uint8Array([/* 16 bytes */]);

function looksLikeImage(buf: Uint8Array): boolean {
  if (buf.length < 12) { return false; }
  if (buf[0] === 0xFF && buf[1] === 0xD8) { return true; }                       // JPEG
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4E && buf[3] === 0x47) { return true; } // PNG
  if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46) { return true; }     // GIF
  if (buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46) { return true; } // WEBP
  return false;
}

export async function loadCover(url: string, referer: string, targetW: number): Promise<image.PixelMap> {
  const raw: ArrayBuffer = await fetchBytes(url, referer);
  const encrypted: Uint8Array = new Uint8Array(raw);
  // 原项目逻辑：已是图片则直接用（部分封面未加密），否则 AES 解密
  const plain: Uint8Array = looksLikeImage(encrypted)
    ? encrypted
    : aesCbcDecryptNoPadding(encrypted, COVER_KEY, COVER_IV);
  const source: image.ImageSource = image.createImageSource(plain.buffer as ArrayBuffer);
  try {
    const info: image.ImageInfo = await source.getImageInfo();
    const ratio: number = info.size.height / info.size.width;   // 保持宽高比，按宽度下采样
    const pixel: image.PixelMap = await source.createPixelMap({
      desiredSize: { width: targetW, height: Math.round(targetW * ratio) }
    });
    return pixel;
  } finally {
    source.release();
  }
}
```

**正确姿势清单**：
1. **先判魔数再解密**（原项目就这么做）：有的封面 URL 返回的就是明文图，盲目解密会花屏。
2. **一定传 `desiredSize`**：列表卡片 160×220 对应宽度 320px 左右即可（3x 屏），内存可降 4–8 倍。
3. **解密放 taskpool**（可选优化）：`loadCover` 里的 AES 部分做成 `@Concurrent` 函数，输入输出都是 `ArrayBuffer`；解码留在主线程（`createPixelMap` 是异步 native 调用，不阻塞）。
4. **缓存 PixelMap**：内存 LRU（`Map<string, image.PixelMap>`，容量 ~100–200 张，按屏幕尺寸算），命中直接 `Image(pixel)`；淘汰时 `pixel.release()`。
5. **磁盘缓存密文**（可选）：缓存原始密文到 `cacheDir`，重进 App 不用再走网络（解密成本低）。
6. **不要每帧 new PixelMap**：列表复用 `@ReusableV2` 组件，`aboutToRecycle` 里释放图片引用。
7. **占位/失败兜底**：`Image.alt($r('app.media.cover_placeholder'))`；失败不要显示空白（原项目有 `Placeholder` 视觉）。

### 6.4 本节来源

- SDK：`$SDK/api/@ohos.security.cryptoFramework.d.ts`、`@ohos.util.d.ts`、`@ohos.multimedia.image.d.ts`（`createImageSource(buf: ArrayBuffer)` `:L4258`、`createPixelMap(options?: DecodingOptions)` `:L11816`）
- 官方文档：`security/CryptoArchitectureKit/crypto-sym-encrypt-decrypt-spec.md`、`arkts-utils/buffer.md`
- 参考实现（只读）：`src-tauri/src/media.rs:49-116`（AES 解密、padding、图片类型判定、内存 LRU 240 张）

---

## 7. 持久化

### 7.1 选型（先看结论再写代码）

| 需求 | 方案 | 理由 |
| --- | --- | --- |
| 设置项（线路、清晰度、弹幕开关、深色/字体） | **`@ohos.data.preferences`**（少量 key）或 **`PersistenceV2`**（`@ObservedV2` 对象） | 两者都简单；需要 UI 自动刷新用 PersistenceV2，纯读写用 preferences |
| 登录 token / 刷新 token | **Asset Store Kit（`@ohos.security.asset`）** 或 HUKS | token 属敏感数据，preferences 是明文文件 |
| 播放进度 / 观看历史（结构化、条数多） | **preferences（每集一个 key）** 或 **RDB**（`@ohos.data.relationalStore`） | 数十~数百条 preferences 够用；上千条/需要查询排序用 RDB |
| 图片/视频缓存 | **`@ohos.file.fs` + `context.cacheDir`** | 系统可清理，不占用户数据 |
| 大对象（离线缓存索引） | `fileIo` + JSON 文件 | 避免 preferences 16MB 上限与单进程限制 |

### 7.2 preferences（用户首选项）

```ts
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

export class SettingsRepo {
  private pref?: preferences.Preferences;

  async init(context: common.UIAbilityContext): Promise<void> {
    this.pref = await preferences.getPreferences(context, 'hg_settings');
  }
  // 同步 API（API 10+）：初始化完成后可直接同步读写
  getString(key: string, defValue: string): string {
    return this.pref === undefined ? defValue : this.pref.getSync(key, defValue) as string;
  }
  putString(key: string, value: string): void {
    if (this.pref !== undefined) { this.pref.putSync(key, value); }
  }
  // 写入后必须 flush 才落盘（putSync 只改内存）
  async flush(): Promise<void> {
    if (this.pref !== undefined) { await this.pref.flush(); }
  }
  async remove(key: string): Promise<void> {
    if (this.pref !== undefined) { this.pref.deleteSync(key); await this.pref.flush(); }
  }
}

// 存对象：JSON 字符串（不要塞原始对象）
const line: number = 2;
repo.putString('lineIndex', line.toString());
repo.putString('watchLater', JSON.stringify(ids));   // ids: string[]
```

- `$SDK/api/@ohos.data.preferences.d.ts:L284`（getPreferencesSync）、`:L683`（getSync）、`:L836`（putSync）、`:L946/L958`（flush）、`:L893`（deleteSync）
- **容量**（B 级，官方文档常量表）：key ≤ **1024 字节**；value ≤ **16MB**；文件名 ≤ 255 字节且不能含 `/`。
- **限制**：**不支持多进程并发**（官方明确会损坏文件），所有读写集中在主进程（本项目单进程，OK）。
- 持久化文件在 `preferencesDir`，卸载即清除。

### 7.3 文件缓存（`@ohos.file.fs`）

```ts
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

export class DiskCache {
  private dir: string = '';

  init(context: common.UIAbilityContext): void {
    this.dir = context.cacheDir + '/hg_cache';      // cacheDir：系统可清理
    if (!fileIo.accessSync(this.dir)) { fileIo.mkdirSync(this.dir); }
  }
  pathOf(name: string): string { return this.dir + '/' + name; }
  exists(name: string): boolean { return fileIo.accessSync(this.pathOf(name)); }
  read(name: string): ArrayBuffer {
    const file = fileIo.openSync(this.pathOf(name), fileIo.OpenMode.READ_ONLY);
    try {
      const stat = fileIo.statSync(file.fd);
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      return buf;
    } finally { fileIo.closeSync(file); }
  }
  write(name: string, data: ArrayBuffer): void {
    const file = fileIo.openSync(this.pathOf(name),
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, data); } finally { fileIo.closeSync(file); }
  }
}
```

- `$SDK/api/@ohos.file.fs.d.ts:L336`（accessSync）、`:L127`（OpenMode）、`:L1003`（openSync）；`@ohos.file.fs.d.ts` 的 statSync/readSync/writeSync/closeSync
- 缓存目录约定：`context.cacheDir`（系统可能清理，适合图片/分片）、`context.filesDir`（持久，适合下载完成的内容）、`context.tempDir`（临时）。
- 缓存淘汰：按 `stat.mtime` 排序删除最旧（或实现 `LRU index.json`）；**单文件 + 总大小上限**（如 200MB）并在 `onBackground` 时清理。

### 7.4 token 安全存储：【Q8】

**推荐：Asset Store Kit（`@ohos.security.asset`）**——系统级"关键资产"存储（小数据、硬件加密、可设置访问条件），比 HUKS 简单得多。

```ts
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';

async function saveToken(token: string): Promise<void> {
  const attr: asset.AssetMap = new Map();
  attr.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(token));
  attr.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto('hg_access_token'));
  attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
  await asset.add(attr);
}

async function loadToken(): Promise<string> {
  const query: asset.AssetMap = new Map();
  query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto('hg_access_token'));
  const res: Array<asset.AssetMap> = await asset.query(query);
  if (res.length === 0) { return ''; }
  const secret: Uint8Array = res[0].get(asset.Tag.SECRET) as Uint8Array;
  return new util.TextDecoder('utf-8').decodeWithStream(secret);
}
```

- `$SDK/api/@ohos.security.asset.d.ts`：`add`（`:L58`）、`query`（`:L363`）、`update`（`:L216`）、`remove`（`:L140`）、`Tag.SECRET/ALIAS/ACCESSIBILITY`（`:L817+`）；`set IS_PERSISTENT` 需要 `ohos.permission.STORE_PERSISTENT_DATA`（本项目不需要，卸载即清可接受）。
- **HUKS（`@ohos.security.huks`）**：适合"自管理密钥 + 加解密/签名"，API 是 `generateKeyItem/initSession/updateSession/finishSession` 流程，复杂度高一个量级；**token 场景不建议**，除非需要"密钥不可导出 + 每次启动重新派生"的强安全模型。
- **不推荐**：preferences 存 token（明文文件）、AppStorage/PersistenceV2 存 token（会落盘且可能进快照）。
- 迁移成本：原项目 token 在 `session.rs`（Rust 侧 keyring/文件）。鸿蒙端建议启动时读 Asset → 放内存 `SessionStore`（`@ObservedV2`）→ 请求拦截器统一加 `Authorization`。

### 7.5 关系型数据库（RDB）：要不要用？

- 适用：观看历史 > 1000 条、需要按时间/剧集查询排序、收藏夹离线检索。
- 不适用：设置项、少量进度（preferences 足够，省掉建表/迁移成本）。
- 结论：**一期不用 RDB**；历史记录用 `preferences + 每剧一个 key` 或"单个 JSON 文件"即可，二期数据量上来再迁移。

### 7.6 本节来源

- SDK：`$SDK/api/@ohos.data.preferences.d.ts`、`@ohos.file.fs.d.ts`、`@ohos.security.asset.d.ts`、`@ohos.security.huks.d.ts`、`@ohos.data.relationalStore.d.ts`
- 官方文档：`database/data-persistence-by-preferences.md`、`database/data-persistence-by-rdb-store.md`、`file-management/app-sandbox-directory.md`、`security/AssetStoreKit/Readme-CN.md`、`security/UniversalKeystoreKit/Readme-CN.md`

---

## 8. 并发与线程

### 8.1 线程模型（Stage 模型）

- **主线程（UI 线程）**：ArkUI 渲染、状态更新、所有 `on('...')` 回调（默认）都在这里。**禁止**在主线程做 > 5ms 的同步计算（AES 大分片、m3u8 大文本解析、JSON 大对象解析）。
- **TaskPool**：托管的任务池（默认并发度由系统按 CPU 决定），适合"一次性、可并行、无共享状态"的任务；`@Concurrent` 函数。
- **Worker**：常驻线程 + `postMessage` 通信，适合"长期运行、有状态"的任务（本项目暂无必需场景）。
- **网络/媒体回调**：`@ohos.net.http` 的 Promise 回调在调用方线程（主线程）；AVPlayer 事件也在主线程——**不要在 `timeUpdate` 里做重活**。

### 8.2 taskpool 可抄代码（封面解密/大 JSON 解析）

```ts
// worker/CryptoTask.ets
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

// @Concurrent 必须是顶层函数；参数/返回值必须可序列化（ArrayBuffer 可以）
@Concurrent
export function decryptAes128Cbc(input: ArrayBuffer, key: ArrayBuffer, iv: ArrayBuffer): ArrayBuffer {
  const keyGen = cryptoFramework.createSymKeyGenerator('AES128');
  const symKey = keyGen.convertKeySync({ data: new Uint8Array(key) });
  const cipher = cryptoFramework.createCipher('AES128|CBC|NoPadding');
  cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey,
    { algName: 'IvParamsSpec', iv: { data: new Uint8Array(iv) } });
  return cipher.doFinalSync({ data: new Uint8Array(input) }).data.buffer as ArrayBuffer;
}
```

```ts
// 主线程调用
import { taskpool } from '@kit.ArkTS';
import { decryptAes128Cbc } from '../worker/CryptoTask';

async function decryptOffMain(enc: ArrayBuffer, key: Uint8Array, iv: Uint8Array): Promise<ArrayBuffer> {
  const keyBuf: ArrayBuffer = key.slice().buffer as ArrayBuffer;   // Uint8Array -> ArrayBuffer
  const ivBuf: ArrayBuffer = iv.slice().buffer as ArrayBuffer;
  const out: Object = await taskpool.execute(decryptAes128Cbc, enc, keyBuf, ivBuf);
  return out as ArrayBuffer;
}
```

- `$SDK/api/@ohos.taskpool.d.ts:L821`（execute）、`:L134`（Task）、`:L586`（LongTask）；`@Concurrent` 由 `@ohos.arkts#concurrent` 装饰器提供（`arkts` 目录）。
- **约束**：`@Concurrent` 函数不能访问 `this`、不能闭包捕获外部变量（只能靠参数）；类实例要满足 Sendable 规则（`@Sendable`）；**不要传 PixelMap/AVPlayer 等 native 对象**。
- 任务时长：TaskPool 普通任务有执行时长上限（约 3 分钟），超长任务用 `LongTask` 或 Worker 常驻。

### 8.3 Worker（仅当需要常驻线程时）

```ts
// workers/proxy.ets —— Worker 入口（在 build-profile 里无需额外配置，文件放 ets/workers/）
import { worker, MessageEvents } from '@kit.ArkTS';

const port: worker.ThreadWorker = worker.workerPort;
port.onmessage = (e: MessageEvents) => {
  const data: string = e.data as string;
  port.postMessage('ack:' + data);
};
```

主线程：`const w = new worker.ThreadWorker('entry/ets/workers/proxy.ets'); w.postMessage('x'); w.onmessage = (e) => {...}`。
**本项目一期不需要 Worker**：本地代理用主线程异步 socket + taskpool 解密足够；引入 Worker 反而增加调试成本。

### 8.4 并发控制建议

| 场景 | 建议 |
| --- | --- |
| 列表图片/封面请求 | 并发 ≤ 6；超出排队；同 URL 去重（in-flight map） |
| HLS 代理上游请求 | 并发 ≤ 4（分片大，带宽优先） |
| 接口请求 | 并发 ≤ 4；失败重试 1 次（指数退避 300ms/900ms）；403/404 不重试 |
| 预加载 | 只预取下一页第一屏；WIFI 才预解码下一集 |
| UI 更新 | 所有状态更新回到主线程（taskpool 回调本身就在主线程，直接改 `@Local` 即可） |

### 8.5 本节来源

- 官方文档：`arkts-utils/taskpool-introduction.md`、`taskpool-vs-worker.md`、`independent-time-consuming-task.md`、`long-time-task-guide.md`、`worker-introduction.md`、`concurrency-overview.md`
- SDK：`$SDK/api/@ohos.taskpool.d.ts`

---

## 9. 权限与安全

### 9.1 module.json5 配置样例（可直接改）

```json5
// entry/src/main/module.json5
{
  "module": {
    "name": "entry",
    "type": "entry",
    "mainElement": "EntryAbility",
    "deviceTypes": ["phone", "tablet"],
    "deliveryWithInstall": true,
    "installationFree": false,
    "pages": "$profile:main_pages",
    "abilities": [
      {
        "name": "EntryAbility",
        "srcEntry": "./ets/entryability/EntryAbility.ets",
        "icon": "$media:layered_image",
        "label": "$string:app_name",
        "exported": true,
        "launchType": "singleton",
        "backgroundModes": ["audioPlayback"],
        "startWindow": "$profile:start_window",
        "startWindowIcon": "$media:start_icon",
        "startWindowBackground": "$color:start_window_background",
        "skills": [
          { "entities": ["entity.system.home"], "actions": ["ohos.want.action.home"] }
        ]
      }
    ],
    "requestPermissions": [
      { "name": "ohos.permission.INTERNET" },
      {
        "name": "ohos.permission.KEEP_BACKGROUND_RUNNING",
        "reason": "$string:background_play_reason",
        "usedScene": { "abilities": ["EntryAbility"], "when": "always" }
      }
    ]
  }
}
```

- 权限声明格式参考官方 `quick-start/module-configuration-file.md`（`requestPermissions` 字段）；完整权限清单见 `security/AccessToken/permissions-for-all.md`。
- **INTERNET 是 system_grant**：安装即授予，无需运行时弹窗。
- **KEEP_BACKGROUND_RUNNING**：需在 module.json5 声明 + `reason/usedScene`；部分系统版本仍要求运行时申请，兜底写法：
  ```ts
  import { abilityAccessCtrl } from '@kit.AbilityKit';
  const atManager = abilityAccessCtrl.createAtManager();
  await atManager.requestPermissionsFromUser(context, ['ohos.permission.KEEP_BACKGROUND_RUNNING']);
  ```
  （是否需要运行时申请 + 弹窗文案，列 §12 真机验证。）
- 不需要申请的权限不要声明（商店审核会查"声明了但未使用"）。

### 9.2 network_config.json（明文 HTTP 开关）

完整示例见 §5.2。要点复述：

| 组件 | 默认明文 | 本项目要做什么 |
| --- | --- | --- |
| Network Kit（http） | 允许 | 接口是 https 保持默认；若是 http 需 domain-config 精确放行 |
| **Media Kit（AVPlayer）** | **禁止（API 23+）** | **必须 component-config 的 "Media Kit"=true**，否则 5411012 |
| 本地代理 127.0.0.1 | 跟随配置 | domain-config 放行 127.0.0.1（若采用代理方案） |

**验证方法（必需）**：
1. 构建后解包 HAP，确认 `resources/base/profile/network_config.json` 存在；
2. App 内调用 `networkSecurity.isCleartextPermittedByHostName('127.0.0.1')` 断言 true；
3. 播放 `http://127.0.0.1:<port>/hls` 观察是否还报 `5411012`。

### 9.3 安全清单（对齐原项目 docs/security.md 的取舍）

| 项 | 建议 |
| --- | --- |
| 明文 HTTP | 仅放行必要域名（接口域名 + 127.0.0.1）；绝不全量 true 进生产包 |
| 证书固定（pinning） | 一期不做（上游可能轮换证书，固定导致全量不可用）；二期用 certificatePinning 并配灰度/降级 |
| WebView | 本项目禁用（不引入 Web/ArkWeb 组件），天然规避 H5 注入 |
| 日志脱敏 | 日志禁止打印完整 URL 与 query（原项目 playback_log 做了脱敏）；token/authorization 绝不落日志 |
| 密钥 | 封面 AES key/iv 已硬编码在 src-tauri/src/media.rs（公开仓库），鸿蒙端保持一致即可，不要复制到多个文件 |
| token | Asset Store Kit（§7.4），不放 preferences |
| 截图/隐私 | 播放器页如需防截屏：window 的隐私模式 API（需确认 API 版本，列入 §12） |
| 混淆 | release 构建开启 ArkGuard（build-profile.json5 的 arkOptions），二期做 |

### 9.4 本节来源

- 官方文档：`security/AccessToken/declare-permissions.md`、`security/AccessToken/permissions-for-all.md`、`network/http-request.md`、`quick-start/module-configuration-file.md`
- SDK：`$SDK/api/@ohos.abilityAccessCtrl.d.ts`、`@ohos.net.networkSecurity.d.ts`

---

## 10. 打包与资源

### 10.1 工程结构（对齐参考工程 dsh-harmony/harmony）

```text
HGhub-Harmony/
└── harmony/                               # 原生工程根（Lead 创建）
    ├── AppScope/
    │   ├── app.json5                      # bundleName / versionCode / icon / label
    │   └── resources/base/{element,media}/
    ├── entry/                             # 主 HAP 模块
    │   ├── src/main/
    │   │   ├── ets/
    │   │   │   ├── entryability/EntryAbility.ets
    │   │   │   ├── pages/                 # @Entry 页面（Index.ets）
    │   │   │   ├── view/                  # 自定义组件（@ComponentV2）
    │   │   │   ├── model/                 # @ObservedV2 模型 + DTO
    │   │   │   ├── network/               # http 封装
    │   │   │   ├── player/                # AVPlayer / 代理 / 播放器组件
    │   │   │   ├── crypto/                # AES / Base64
    │   │   │   └── workers/               # taskpool @Concurrent / Worker
    │   │   ├── resources/
    │   │   │   ├── base/{element,media,profile}/
    │   │   │   ├── dark/element/
    │   │   │   ├── rawfile/                # 测试流等原始文件
    │   │   │   └── resfile/                # 原样打包（证书等）
    │   │   └── module.json5
    │   ├── build-profile.json5
    │   ├── hvigorfile.ts
    │   └── oh-package.json5
    ├── build-profile.json5                # products / signingConfigs / modules
    ├── hvigorfile.ts
    └── oh-package.json5                   # modelVersion / dependencies
```

### 10.2 资源引用：$r / $rawfile / $media / resfile

| 引用 | 位置 | 访问方式 | 用途 |
| --- | --- | --- | --- |
| app.color.xxx | resources/base/element/color.json | $r | 颜色（深浅色自动切换） |
| app.float.xxx | element/float.json | $r | 尺寸/圆角 |
| app.string.xxx | element/string.json | $r | 文案（多语言） |
| app.media.xxx | resources/base/media/xxx.png / .svg | $r | 图标/占位图 |
| sys.symbol.xxx | 系统符号 | $r | SymbolGlyph 系统图标 |
| rawfile | resources/rawfile/ | $rawfile / resourceManager.getRawFd | 测试流、内置文件 |
| resfile | resources/resfile/ | resourceManager.getRawFileContent | 原样打包（证书等） |

**规则**：除 rawfile/resfile 外资源会编译成资源索引（必须走 $r）；图片优先 SVG（体积小、可 fillColor），位图给 3x 一份即可（系统按密度缩放）。

### 10.3 应用图标（分层图标）与启动页

- **应用图标**：HarmonyOS NEXT 要求分层图标（background + foreground）。在 AppScope/resources/base/media/ 放 layered_image.json（引用前景/背景图，DevEco 可生成），app.json5 的 icon 指向 `$media:layered_image`。参考工程用 `app_layered_image`。
- **启动页**：
  - 兼容写法：startWindowIcon + startWindowBackground（API 20 仍有效）；
  - 推荐写法（API 20+）：`"startWindow": "$profile:start_window"`，在 resources/base/profile/start_window.json 配置；配置后 startWindowIcon/Background 不再生效（官方 windowmanager/launch-page-config.md）。
  - 体验：启动页背景色与首屏骨架屏一致（避免"启动页→白屏→内容"闪断）；本项目深色背景建议 #0B0B0F。
- 参考工程目录与资源命名可直接照抄（app_layered_image、start_window_background、app_icon）。

### 10.4 build-profile.json5 与 targetSdk 26 影响

```json5
{
  "app": {
    "signingConfigs": [ /* 见 §10.5 */ ],
    "products": [{
      "name": "default",
      "compatibleSdkVersion": "6.1.0(23)",
      "targetSdkVersion": "26.0.0",
      "runtimeOS": "HarmonyOS",
      "signingConfig": "default"
    }],
    "buildModeSet": [{ "name": "debug" }, { "name": "release" }]
  },
  "modules": [{ "name": "entry", "srcPath": "./entry", "targets": [{ "name": "default", "applyToProducts": ["default"] }] }]
}
```

**targetSdkVersion 26 的影响（B 级 + C 级）**：
- 以 API 26 为目标时新版本行为默认生效，最典型：**API 23 起 Media Kit 明文 HTTP 默认禁止**（5411012）→ 必须配 network_config.json（§9.2）。
- 权限/后台/安全类行为按 targetSdk 分档收紧（长时任务、通知权限、隐私接口），升级前应跑官方"行为变更"清单（release-notes 各版本 changelog）。
- 建议 compatibleSdkVersion 保持 6.1.0(23)（覆盖 HarmonyOS 6.1 设备），targetSdk 26 享受新特性；若真机遇到 26 行为差异导致问题，可临时降到 23 定位，但最终仍应上 26。
- compatibleSdkVersion/targetSdkVersion 必须与本机已安装 SDK 匹配（SDK 26.0.0.105 + 6.1.0(23) 已由参考工程验证可构建）。

### 10.5 签名（本机 ~/.ohos/config 材料能否复用？）

- 现有 default_harmony_*.cer/.p7b/.p12 是 DevEco 自动签名产物；dsh-harmony-release.* 是参考工程的发布签名产物。
- **关键限制**：HarmonyOS 的 Profile（.p7b）绑定 bundleName（以及调试设备/证书）。参考工程 bundleName 是 `io.github.stlin256.dshharmony`，**HGhub 新 bundleName 不同 → 直接复用该 p7b 会签名/安装失败**（安装时报 bundleName 与 profile 不匹配）。
- **可行做法（按优先级）**：
  1. DevEco Studio 打开 harmony/ 工程 → File → Project Structure → Signing Configs → 勾选 Automatic signing 重新生成（会为新 bundleName 生成新的 .p12/.cer/.p7b 并写入 build-profile.json5）；
  2. 命令行构建时，把生成的签名材料路径填进 build-profile.json5 的 signingConfigs.material（参考工程格式：certpath/keyAlias/keyPassword/profile/signAlg/storeFile/storePassword）；
  3. 上架时再申请发布证书 + 发布 Profile（绑定正式 bundleName 与证书指纹）。
- **验证**：hdc install 若报 9568320 / profile / bundleName 相关错误，即签名与 bundle 不匹配；用 DevEco 签名面板或 hapsigntool 查看 p7b 内容确认。
- **安全**：不要把 .p12 密码/私钥提交仓库（参考工程把调试密码写进 build-profile.json5 是因为其公开仓库的调试材料；本项目应改为本地未跟踪文件或 CI secret）。

### 10.6 构建与真机命令（参考工程已验证的调用方式）

```powershell
# 环境（与 DevEco 内置工具链一致）
$ide = '%LOCALAPPDATA%\Programs\Huawei\DevEcoStudio-26.0.0'
$env:NODE_HOME = "$ide\tools\node"
$env:JAVA_HOME = "$ide\jbr"
$env:DEVECO_SDK_HOME = "$ide\sdk"
$env:Path = "$env:NODE_HOME;$env:JAVA_HOME\bin;$env:Path"

cd %USERPROFILE%\Documents\projects\HGhub-Harmony\harmony
& "$ide\tools\ohpm\bin\ohpm.bat" install
& "$env:NODE_HOME\node.exe" "$ide\tools\hvigor\bin\hvigorw.js" --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon

# 产物：entry/build/default/outputs/default/entry-default-signed.hap
# 安装 + 启动 + 日志（设备连上后）
$hdc = "$ide\sdk\default\openharmony\toolchains\hdc.exe"
& $hdc list targets
& $hdc install -r <hap路径>
& $hdc shell aa start -a EntryAbility -b <bundleName>
& $hdc hilog | Select-String 'hg'
```

- 参考脚本：dsh-harmony/scripts/build-harmony.ps1（hvigorw 调用方式，含 ohpm install、环境变量、assembleHap/assembleApp）；scripts/device-ui-*.ps1（hdc 截图/点击/文本断言的回归测试流程，可复用）。
- 当前 hdc list targets = [Empty]（无设备）；本阶段只做编译验证，真机联调等用户插机。

### 10.7 本节来源

- 官方文档：quick-start/application-package-structure-stage.md、quick-start/resource-categories-and-access.md、quick-start/app-configuration-file.md、quick-start/module-configuration-file.md、quick-start/layered-image.md、windowmanager/launch-page-config.md、security/hapsigntool-guidelines.md、security/app-provision-structure.md
- 参考工程（只读）：dsh-harmony/harmony/build-profile.json5、entry/src/main/module.json5、AppScope/app.json5、scripts/build-harmony.ps1

---

## 11. 关键结论 FAQ（Q1–Q10）

> 记号：**A**=SDK 声明实证；**B**=官方文档；**C**=待真机验证。所有"C"都必须在 §12 清单里闭环后再写正式实现。

### Q1. AVPlayer 能否带自定义 header / Referer？若不行，本地 127.0.0.1 TCP 代理可行吗？

- **支持设置自定义头（B 级，确定）**：`media.createMediaSourceWithUrl(url, headers?)`（API 12+），官方示例明确可设 `User-Agent/Cookie/Referer`（`playback-url-setting-method.md` 情况三；`media.d.ts:L185`）。
- **是否作用于 HLS 全部子请求（播放列表/子清单/分片/密钥）：官方未写明（C 级）**。必须用 §4.4.3 的自建 127.0.0.1 日志服务器实测；三种结果（H1/H2/H3）对应不同架构。
- **若 headers 不透传：本地 127.0.0.1 TCP 代理可行（A 级）**。`socket.constructTCPSocketServerInstance()` + `listen({address:'127.0.0.1', port:0})` + `getLocalAddress()` 取端口；需要 `ohos.permission.INTERNET`；系统多线程处理并发连接（§5.3）。**注意**：AVPlayer 播 `http://127.0.0.1` 需放开 Media Kit 明文（§9.2），否则 5411012。
- **替代方案（官方推荐的自定义数据源）**：`MediaSource.setMediaResourceLoaderDelegate(MediaSourceLoader)`（API 18+）可在**进程内**接管播放器资源请求（open/read/close + respondHeader/respondData/finishLoading），避免本地端口与明文配置；但复杂度高，且 HLS key 请求是否经过 Loader **未知（C）**。
- **行动建议**：先做 §4.4.3 验证（半天）→ H1 直连；H2/H3 落地方案 C（本地代理）。**不要先写 Loader**。

### Q2. 明文 http + 127.0.0.1 是否可用？AVPlayer 播本地代理 http 流有什么限制？

- `@ohos.net.http`：明文默认允许（API 18+），但可被 network_config.json 的 domain-config 关闭（2300997）。
- **AVPlayer（Media Kit）：API 23 起默认禁止明文**（5411012），**必须**在 `resources/base/profile/network_config.json` 里把 `component-config["Media Kit"]` 设为 true（必要时再对 127.0.0.1/接口域名做 domain-config）。**这是本地代理方案的前置条件**（B 级，官方配置表）。
- 127.0.0.1 是否有系统级豁免：官方未写明（C）。按"没有豁免"设计，即**必须配置**。
- AVPlayer 播本地代理的限制：
  1. 必须支持 **Range 请求**（分片/seek 时播放器可能发 Range），代理需透传并返回 206 + Content-Range；
  2. 代理返回的 m3u8 `Content-Type` 建议 `application/vnd.apple.mpegurl`；
  3. 代理失败不要返回空 200（播放器会静默卡住），返回 502 + 应用层切线路提示；
  4. 代理端口每次启动可能不同（系统分配）→ 同一播放会话内只启动一次、端口固定；m3u8 内的改写前缀必须与该端口一致；
  5. 本地代理会增加一次内存拷贝，4K 高码率会吃力（本项目 720p/1080p 短剧可接受）。

### Q3. ArkTS 能否引入 npm/ohpm 第三方库（hls.js 替代、m3u8 解析）？

- **npm 包不能直接用于 ArkTS**：没有 Node 运行时/DOM，`fs/path/process/Buffer/XMLHttpRequest/MediaSource` 全不可用；`.ets` 可 import 同工程 `.ts/.js` 源码，但源码必须符合 ArkTS 约束。
- **ohpm 是唯一正规依赖渠道**（`ohpm.openharmony.cn`）：`ohpm install @scope/pkg` → `oh-package.json5` 的 `dependencies`；HAR/HSP 包在 ArkTS 工程可用。当前项目**零三方依赖**即可完成（AVPlayer 覆盖 HLS，图片/加密/存储都是系统能力）。
- **hls.js 不可移植**（依赖浏览器 MediaSource/SourceBuffer/XHR）；**m3u8 解析器可以自己写**（纯字符串处理，~200 行；§4.4.5 已给出需要改写的标签清单，直接照 `src-tauri/src/media.rs` 的测试用例迁移）。
- 若将来必须用 C/C++ 库（FFmpeg 等）：NAPI（`.so` + `.d.ts`）可行但成本高、商店审核与体积代价大；**本期明确不走**。
- 本地 har 打包：`ohpm pack` 生成 `.har`，在 `oh-package.json5` 里用 `"file:../libs/xxx.har"` 引用（仅当拆多模块时才需要）。

### Q4. HLS AES-128 加密切片由 AVPlayer 原生处理，还是要代理解密？

- **官方没有明说（C 级）**。SDK 中 `setDecryptionConfig` 只针对 DRM（MediaKeySession），不等于 HLS AES-128。
- **验证方法**：§4.4.3 的测试 m3u8 带 `#EXT-X-KEY:METHOD=AES-128`，观察 AVPlayer 是否请求 `/key` 且能出画面。
- **若原生支持**：确认 key 请求是否带 Referer（若不带 → 仍需代理接管 key，或代理预取 key 后改写 m3u8？注意：HLS 规范要求播放器自己取 key，改写 key URI 到本地代理即可让代理带 Referer 转发，**这是最小改动方案**）。
- **若不支持/无法带 Referer**：方案 C 代理内解密（`AES128|CBC|NoPadding` + 去 PKCS7，§6.1），对播放器暴露明文分片与去掉 `#EXT-X-KEY` 的 m3u8。
- **风险提示**：若上游是 `SAMPLE-AES`/FairPlay/Widevine，则 AVPlayer 的 DRM 路径不一定可用，需另行评估（**本项目先确认上游就是标准 AES-128**，原项目 hls.js 能解 → 大概率是标准 AES-128）。

### Q5. 封面 AES 解密 → PixelMap 的正确姿势与性能

- 姿势：`fetchBytes（带 Referer/UA）` → 判魔数（是图片则跳过解密）→ `AES128|CBC|NoPadding` 解密 + 手动去 PKCS7（与原 Rust 逐块 CBC 行为一致，避免框架对非标准 padding 抛错）→ `image.createImageSource(ArrayBuffer)` → `createPixelMap({desiredSize})` → `Image(pixelMap)`（§6.3）。
- 性能：
  1. **一定传 desiredSize**（列表 320px 宽即可），内存降 4–8 倍；
  2. AES 解密放 taskpool（>300KB 或批量时；ArrayBuffer 可传递），解码留主线程异步 API；
  3. PixelMap 内存 LRU（100–200 张）+ 淘汰 `release()`；列表复用组件 `aboutToRecycle` 释放；
  4. 磁盘缓存**密文**（省二次下载；解密 CPU 成本低）；
  5. 失败兜底 alt 占位图，避免布局跳动（固定 aspectRatio）。
- 结论：**可行且性能可控**；短剧列表一屏 6–10 张封面，按上述做可稳定 60fps。

### Q6. 长列表 + 大量网络图 + 视频封面页的性能建议

1. **LazyForEach + IDataSource**（禁止 ForEach 全量渲染），key 稳定唯一，`cachedCount` 4–8（§3.4）。
2. 列表项组件 `@ReusableV2` + `aboutToReuse/aboutToRecycle`（§1.7）。
3. 图片：PixelMap LRU + 磁盘密文缓存 + 并发限 6 + 同 URL 去重 + 预取下一屏（§6.3、§8.4）。
4. 轮播/Banner：滚动时暂停 autoPlay，切后台停止。
5. 预加载：点击卡片立即创建 AVPlayer 预起播（最多 16 实例上限，留余量）。
6. 避免在 build/onScroll 里做同步计算；`timeUpdate` 等高频事件节流 250ms。
7. 瀑布流避免不定高元素频繁重排；图片未加载时用固定比例占位。
8. 首屏：骨架屏 + 分页 20 条起（不要一次拉 200 条）。

### Q7. 后台播放 / 锁屏控制 / 画中画

- **后台播放（B 级确定）**：接入 **AVSession**（createAVSession/activate/setAVMetadata/setAVPlaybackState/on play|pause|seek）+ 申请 **AUDIO_PLAYBACK 长时任务**（`backgroundTaskManager.startBackgroundRunning(context, ['audioPlayback'], wantAgent)`）+ 权限 `ohos.permission.KEEP_BACKGROUND_RUNNING` + module.json5 `backgroundModes: ["audioPlayback"]`。缺一不可，否则退后台被静音冻结。
- **锁屏/播控中心控制**：AVSession 的 on('play'/'pause'/'seek'/'stop') 回调 + setAVPlaybackState 同步进度；通知由 AVSession 发出（API 20+）。
- **画中画（PiP）**：API 26 SDK 仅在 `window.GlobalWindowMode.PIP`（系统窗口模式枚举）出现，**未发现三方应用主动进入 PiP 的公开 API**；本期不做（C，后续版本再评估）。

### Q8. token 安全存储选型

- **推荐 Asset Store Kit（@ohos.security.asset）**：系统级关键资产存储，`asset.add/query/update/remove` + `Tag.SECRET/ALIAS/ACCESSIBILITY`，API 简单、数据加密、卸载即清（§7.4）。
- 备选 HUKS（@ohos.security.huks）：适合自管密钥，流程 `generateKeyItem/initSession/updateSession/finishSession`，复杂度高，**token 场景不建议**。
- 禁止：preferences/AppStorage/PersistenceV2 存 token（明文落盘）。

### Q9. 沉浸式全屏视频页 + 刘海/挖孔/安全区 + 状态栏样式

- `window.setWindowLayoutFullScreen(true)` + `setWindowSystemBarProperties({statusBarContentColor:'#FFFFFF', navigationBarContentColor:'#FFFFFF'})`；
- 用 `getWindowAvoidArea(TYPE_SYSTEM/TYPE_CUTOUT)` 拿 topRect/bottomRect，控件层加 padding；`on('avoidAreaChange')` 监听转屏/折叠；
- 组件级用 `expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])` 让背景延伸、内容不越界；
- 横屏全屏：`setPreferredOrientation(window.Orientation.LANDSCAPE)`，退出恢复；状态栏可 `setWindowSystemBarEnable([])` 隐藏（全屏观看时）。
- 参考 §3.16 代码。

### Q10. 应用图标 / 启动页 / 深色模式 / 大字体适配

- 图标：**分层图标**（background+foreground，layered_image.json），AppScope 内配置（§10.3）；
- 启动页：`startWindow`（API 20+）或 startWindowIcon/Background；背景色与首屏一致；
- 深色模式：资源限定目录 `base/` + `dark/`（同名 color 覆盖），禁止硬编码颜色；本项目建议默认深色（§3.17）；
- 大字体：`Text.maxFontScale(1.3)` 限制标题、`maxLines + textOverflow` 防溢出、`Column/Row` 用 flex 而非固定高；关键页面在系统字体调到最大时走查（§12）。

---

## 12. 待真机验证清单（连上设备后按序执行，闭环后更新本文等级）

| # | 验证项 | 判定标准 | 方法/工具 | 优先级 |
| --- | --- | --- | --- | --- |
| V1 | HLS headers 是否透传到子请求 | 观察 /hls、/seg、/key 收到的 Referer/UA | §4.4.3 自建 127.0.0.1 日志服务器 | **P0** |
| V2 | HLS AES-128 是否原生解密 | 播放器是否请求 /key 且出画面 | 同上（用真实 TS + 全 0 key） | **P0** |
| V3 | Media Kit 明文放行 | http://127.0.0.1 播放不报 5411012 | network_config.json + `isCleartextPermittedByHostName` | **P0** |
| V4 | network_config.json 是否被打进 HAP | HAP 内存在 resources/base/profile/network_config.json | 解包 HAP / 构建日志 | **P0** |
| V5 | 上游 m3u8 直连可播（headers 生效） | 起播出画面、可 seek | 真机播放真实剧集 | P0 |
| V6 | 本地代理方案全链路 | 起播/seek/切集/弱网稳定 | 代理 + 真实剧集 30min 播放 | P1 |
| V7 | 后台播放 + 锁屏控制 | 退后台不断音、锁屏可控制 | AVSession + 长时任务 | P1 |
| V8 | KEEP_BACKGROUND_RUNNING 是否需运行时申请 | 不申请时后台是否被冻结 | 真机日志 + 通知栏 | P1 |
| V9 | 沉浸式/安全区在刘海与挖孔机型 | 内容不被遮挡、背景延伸 | 真机截图 | P1 |
| V10 | 深色模式/最大字体 | 无溢出、无低对比度 | 系统设置切换 + 截图走查 | P1 |
| V11 | 大列表性能 | 100 条 60fps、无内存暴涨 | DevEco Profiler / 真机 | P1 |
| V12 | 封面 AES 解密正确率 | 列表封面全部正确显示 | 真机抽样 30 张 + 失败日志 | P1 |
| V13 | 明文接口（http）可用 | 接口正常返回 | 真机网络请求 | P1 |
| V14 | 签名可安装 | hdc install 成功、桌面图标正常 | 重新自动签名后安装 | **P0** |
| V15 | 启动页/图标/应用名 | 桌面与应用内一致、无白屏 | 真机冷启动 | P2 |
| V16 | AVPlayer surface 重建（转屏/全屏） | 转屏后画面正常、不黑屏 | 播放中旋转/全屏切换 | P1 |
| V17 | PiP 能力是否存在 | 是否有三方入口（预期无） | 系统设置/文档确认 | P2 |
| V18 | 证书固定（若启用） | 服务端轮换可降级 | 二期 | P2 |
| V19 | 音频焦点中断 | 来电/其他 App 播放时暂停、恢复逻辑正确 | 真机 | P1 |
| V20 | 代理端口复用/切集 | 连续切 10 集不泄漏、端口不变 | 真机 + hilog | P1 |

---

## 13. 官方文档索引

> 路径前缀：OpenHarmony 官方文档镜像 `https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/`（GitHub 同构：`https://github.com/openharmony/docs/tree/master/zh-cn/application-dev/`）。华为开发者文档中心同主题页面可在 `developer.huawei.com/consumer/cn/doc/` 搜索同名文档标题。

| 主题 | 文档路径 |
| --- | --- |
| ArkTS 语言约束（全量规则+错误码） | `quick-start/typescript-to-arkts-migration-guide.md` |
| ArkTS 适配案例 | `quick-start/arkts-more-cases.md` |
| ArkTS 高性能编程 | `quick-start/arkts-high-performance-programming.md` |
| 状态管理 V2（Local/Param/Event/Provider/Consumer） | `ui/state-management/arkts-new-local.md`、`arkts-new-param.md`、`arkts-new-event.md`、`arkts-new-provider-and-consumer.md` |
| ObservedV2/Trace/Monitor/Computed | `ui/state-management/arkts-new-observedV2-and-trace.md`、`arkts-new-monitor.md`、`arkts-new-computed.md` |
| AppStorageV2 / PersistenceV2 | `ui/state-management/arkts-new-appstoragev2.md`、`arkts-new-persistencev2.md` |
| V1/V2 迁移与混用 | `ui/state-management/arkts-v1-v2-migration.md`、`arkts-v1-v2-mixusage.md` |
| Navigation 路由 | `ui/arkts-navigation-navigation.md`（若路径变化，检索"Navigation"） |
| 列表与懒加载 | `ui/arkts-layout-development-create-list.md`、`ui/arkts-rendering-control-lazyforeach.md` |
| 瀑布流 | `ui/arkts-layout-development-waterflow.md`（检索"WaterFlow"） |
| 动画 | `ui/arkts-animation.md`（检索"animateTo"）、`reference/apis-arkui/arkui-ts/ts-explicit-animation.md` |
| SymbolGlyph | `reference/apis-arkui/arkui-ts/ts-basic-components-symbolGlyph.md` |
| 沉浸式窗口 | `windowmanager/immersive-window-feature.md`、`windowmanager/launch-page-config.md` |
| 深色模式/资源限定 | `quick-start/resource-categories-and-access.md`、`ui/arkts-dark-mode.md`（检索"深色模式"） |
| AVPlayer 播放 | `media/media/using-avplayer-for-playback.md`、`media/media/video-playback.md` |
| AVPlayer 设置 URL 与 headers | `media/media/playback-url-setting-method.md` |
| 流媒体（HLS/DASH） | `media/media/streaming-media-playback-development-guide.md` |
| AVPlayer API 参考 | `reference/apis-media-kit/arkts-apis-media-AVPlayer.md`、`arkts-apis-media-MediaSource.md`、`arkts-apis-media-MediaSourceLoadingRequest.md` |
| 后台播放/AVSession | `media/avsession/avsession-access-scene.md`、`media/avsession/avsession-background-scene.md` |
| 长时任务 | `task-management/continuous-task.md` |
| 音频焦点 | `media/audio/audio-playback-concurrency.md` |
| HTTP 请求（含明文策略/证书固定） | `network/http-request.md` |
| Socket（TCP/UDP/TLS 客户端与服务端） | `network/socket-connection.md` |
| 网络连接管理 | `network/net-connection-manager.md` |
| 对称加解密规格 | `security/CryptoArchitectureKit/crypto-sym-encrypt-decrypt-spec.md` |
| Asset Store Kit | `security/AssetStoreKit/Readme-CN.md` |
| HUKS | `security/UniversalKeystoreKit/Readme-CN.md` |
| preferences | `database/data-persistence-by-preferences.md` |
| 应用沙箱目录 | `file-management/app-sandbox-directory.md` |
| taskpool / Worker / 并发 | `arkts-utils/taskpool-introduction.md`、`taskpool-vs-worker.md`、`worker-introduction.md` |
| 应用/模块配置 | `quick-start/app-configuration-file.md`、`quick-start/module-configuration-file.md` |
| 分层图标 | `quick-start/layered-image.md` |
| 签名与 Profile | `security/hapsigntool-guidelines.md`、`security/app-provision-structure.md` |
| 行为变更（targetSdk） | `release-notes/`（各版本 changelog） |
| 最佳实践：网络 CA 安全 | `https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-network-ca-security` |
| 最佳实践：在线视频卡顿优化 | `https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-online-video-playback-lags-practice` |

### 13.1 本机 SDK 声明文件速查

| 文件 | 内容 |
| --- | --- |
| `$SDK/api/@ohos.multimedia.media.d.ts` | AVPlayer / MediaSource / MediaSourceLoader / 事件 |
| `$SDK/api/@ohos.multimedia.avsession.d.ts` | AVSession / 播控 |
| `$SDK/api/@ohos.multimedia.audio.d.ts` | 音频焦点/中断 |
| `$SDK/api/@ohos.net.http.d.ts` / `@ohos.net.socket.d.ts` / `@ohos.net.networkSecurity.d.ts` | 网络 |
| `$SDK/api/@ohos.security.cryptoFramework.d.ts` / `@ohos.security.asset.d.ts` / `@ohos.security.huks.d.ts` | 加密/存储 |
| `$SDK/api/@ohos.data.preferences.d.ts` / `@ohos.file.fs.d.ts` / `@ohos.data.relationalStore.d.ts` | 持久化 |
| `$SDK/api/@ohos.arkui.StateManagement.d.ts` / `@ohos.arkui.UIContext.d.ts` | 状态管理 V2 / UI 上下文 |
| `$SDK/api/@ohos.window.d.ts` / `@ohos.mediaquery.d.ts` / `@ohos.curves.d.ts` / `@ohos.promptAction.d.ts` | 窗口/断点/动画/弹窗 |
| `$SDK/component/*.d.ts` | 全部 ArkUI 组件（navigation/tabs/list/lazy_for_each/water_flow/swiper/refresh/search/text_input/image/symbolglyph/xcomponent/common/enums…） |
| `$SDK/api/@ohos.taskpool.d.ts` | 并发 |

---

## 附录 A：与原 Tauri 实现的逐文件映射（迁移 checklist）

| 原文件（只读参考） | 鸿蒙端落点 | 说明 |
| --- | --- | --- |
| `src-tauri/src/net.rs` | `network/HttpClient.ets` | Referer/UA/超时/重试（不搬 reqwest 的代理逻辑） |
| `src-tauri/src/media.rs`（cover/AES/HLS 改写） | `crypto/AesCbc.ets`、`player/PlaylistRewriter.ets`、`image/CoverLoader.ets`、`player/LocalHlsProxy.ets` | 逻辑等价重写，参数常量从原文件取 |
| `src-tauri/src/lib.rs`（自定义协议） | `player/LocalHlsProxy.ets` 或 MediaSourceLoader | 协议路径 `/hls`、`/seg`、`/img` 保持一致便于对照 |
| `src-tauri/src/session.rs` | `model/SessionStore.ets` + Asset Store | token 安全存储 |
| `src/api.ts`（接口层） | `network/Api.ets` + DTO/Model | JSON→模型手写映射（§1.2） |
| `src/components/*`（React） | `view/*.ets`（@ComponentV2） | 布局重做，交互按 §3/§4.10 优化 |
| `scripts/build-harmony.ps1` | `scripts/build-harmony.ps1`（新增，Lead 负责） | 直接复制 hvigorw 调用方式 |

## 附录 B：写实现时的 10 条铁律

1. 写任何 ArkTS 代码前先看 §1 —— 出现 `any`、解构、`!`、索引签名，编译就过不了。
2. 新页面/组件一律 V2；**不混用 V1**。
3. 任何网络回调、状态更新都在主线程；重 CPU 放 taskpool。
4. 播放器 3 件事必做：`on('error')` 兜底、`startRenderFrame` 关 loading、`release()`。
5. 封面必须判魔数 + AES + `desiredSize`；PixelMap 必须释放。
6. 列表必须 LazyForEach + 稳定 key + cachedCount；卡片组件 @ReusableV2。
7. 颜色/尺寸/文案全走资源（`$r`），不硬编码。
8. 所有交互控件有 accessibilityText，热区 ≥ 40vp。
9. 日志不打印完整 URL/token；错误日志带错误码。
10. **C 级结论（尤其 Q1/Q4 的 headers 与 AES-128）在真机验证前，代码要能被"直连/代理"开关切换**——不要写死单一路径。



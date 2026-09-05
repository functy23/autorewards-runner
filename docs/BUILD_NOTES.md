# 附录 A：本机编译踩坑记录（macOS + Flutter 3.47）

## A.1 `flutter_inappwebview_android 1.1.3` 与 AGP 9 不兼容

现象：`:flutter_inappwebview_android` evaluate 报错
`getDefaultProguardFile('proguard-android.txt') is no longer supported`。

修法（二选一）：

1. 修补插件缓存（`flutter pub get` 后执行，路径以 pub-cache 实际为准）：

```bash
sed -i '' "s/getDefaultProguardFile('proguard-android.txt')/getDefaultProguardFile('proguard-android-optimize.txt')/g" \
  ~/.pub-cache/hosted/pub.dev/flutter_inappwebview_android-*/android/build.gradle
```

2. 等待插件上游发版修复后升级版本号。

## A.2 插件 Java/Kotlin JVM target 不一致

现象：`:flutter_timezone:compileDebugKotlin` 报
`Inconsistent JVM-target compatibility ... (11) and (1.8)`。

修法：已在 `android/build.gradle.kts` 的 `subprojects` 里通过
`pluginManager.withPlugin("com.android.library")` 统一
`compileOptions` 与 `KotlinCompile.compilerOptions.jvmTarget` 为 17。
若其它插件报类似错误，把 17 换成报错里 Java 侧的值即可。

## A.3 项目路径含撇号（`functy's idk`）导致 macOS 构建失败

现象：`Pods-Runner-frameworks.sh: eval: line 174: unexpected EOF while looking for matching '`。

原因：CocoaPods 生成的 `code_sign_if_enabled` 用单引号包路径，路径里的 `'`
截断了 eval 字符串。属于 CocoaPods 对特殊字符路径的处理缺陷。

修法：把项目放到不含撇号的路径再构建（如 `~/rewards_runner`）。

## A.4 Android SDK 许可

首次构建报 `LicenceNotAcceptedException: ndk;28.2.13676358`：

```bash
yes | sdkmanager --licenses
yes | sdkmanager "ndk;28.2.13676358" "platforms;android-35" "build-tools;35.0.0"
```

## A.5 验证结论（2026-09-05）

- `flutter analyze`：No issues found
- `flutter build macos --debug`：✓ Built rewards_runner.app
  - 运行验证：进程存活，日志输出「日志系统初始化完成 / 调度器已启动」
  - 油猴脚本资产已打进 flutter_assets
- `flutter build apk --debug`：✓ Built app-debug.apk

## A.6 米游社扫码登录接口实测（2026-09-05）

- ✅ 创建：`POST https://passport-api.mihoyo.com/account/ma-cn-passport/app/createQRLogin`
  （headers: `x-rpc-app_id: bll8iq97cem8` 等）→ 返回 `data.url`（二维码内容）+ `data.ticket`
- ✅ 轮询：`POST .../account/ma-cn-passport/app/queryQRLoginStatus?ticket=<ticket>`
  → `data.status`: `Created → Scanned → Confirmed`；Confirmed 后 `tokens`
  （token_type=1 为 stoken v2）+ `user_info.aid/mid`
- ❌ `ma-cn-verifier/createQRLogin`（新旧两种路径）均 404 —— 网上流传的 verifier 路径已失效，
   正确域名段是 **ma-cn-passport**

## A.7 qr_flutter 在 AlertDialog 内崩溃

`QrImageView` 内部使用 LayoutBuilder，放进 `AlertDialog`（会做 intrinsic 尺寸测量）时抛
"LayoutBuilder does not support returning intrinsic dimensions"，对话框内容无法渲染。
修法：改用 `CustomPaint(size: Size(220,220), painter: QrPainter(...))` 固定尺寸绘制。

## A.8 PlayCover 提取的图标是 CgBI PNG

iOS 应用的 PNG 常为 Apple 私有 CgBI 变体（如原神 `AppIcon76x76@2x~ipad.png`），
Flutter/Rust 解码器均不认。用 `sips -s format png x.png --out y.png` 重编码为标准 PNG 即可。

## A.9 主页空白根因：SliverFillRemaining(hasScrollBody:false) 包含可滚动子树（2026-09-05 修复）

**现象**：主页（含大标题/状态卡/日志窗口）整片空白，仅侧栏与 FAB 可见；控制台无异常输出；
`flutter analyze` 0 issues；概率复现（窗口内容区从首帧起就画不出来）。

**排查手段**（值得复用）：桌面端 Flutter 无异常输出时，用 Dart VM service dump 渲染树：
连接 `ws://127.0.0.1:<port>/<path>/ws`，调 `ext.flutter.debugDumpApp` /
`ext.flutter.debugDumpRenderTree`。本次 dump 直接看到 `RenderSliverFillRemaining
geometry: null` + 子树 `constraints: MISSING`（布局从未完成）。

**根因链**（本次在 main() 里临时加了 `FlutterError.onError` +
`PlatformDispatcher.instance.onError` → AppLog 文件，一跑就抓到 32k 条/分钟的栈）：

1. `_homeBody` 用 `CustomScrollView` + `SliverFillRemaining(hasScrollBody: false)`
   承载日志窗口，而 LogWindow 内含 `ListView`。
2. Flutter SDK `RenderSliverFillRemaining.performLayout`（sliver_fill.dart）
   布局时调用 `child.getMaxIntrinsicHeight()`；`RenderViewport`（ListView 的
   渲染对象）**不支持 intrinsic 查询** → `debugThrowIfNotCheckingIntrinsics` 抛
   "RenderViewport does not support returning intrinsic dimensions"。
3. sliver 的 `geometry` 永远为 null → 之后每帧 `layoutChildSequence`/`_paintContents`
   /`hitTestChildren` 里的 `geometry!` 连环空指针，渲染管线每帧中断 → 内容区永不绘制。
   SDK 源码里那条 assert 文案明说：child 是 scrollable 时不要把 hasScrollBody 设为 false。

**修复**：
- `main.dart` `_homeBody` 弃用 sliver 结构 → `Column`：
  `Flexible(SingleChildScrollView(大标题+状态卡))` + `Expanded(LogWindow())`。
  标题+卡片区内容超高时自身滚动兜底，日志窗口吃满剩余空间。
- 连带暴露第二颗雷：`log_window.dart` `_LogRow` 的
  `Row(crossAxisAlignment: stretch)` 在 ListView 行高不受限约束下，
  stretch 会给子项传 `h=Infinity` 紧约束 → "BoxConstraints forces an infinite
  height" → 上游 8 层 "RenderBox was not laid out" 级联。修法：Row 外包
  `IntrinsicHeight`（先按文本内容求出有限行高，4dp 色条照样撑满整行）。
- `_scroll.jumpTo(position.maxScrollExtent)` 三处加 `hasContentDimensions`
  防御：`hasClients == true` 不代表维度已解析（首帧/上级布局被打断时读
  maxScrollExtent 空指针）。统一收进 `_scrollToBottom()`。

**验证**：修复后运行 0 异常（此前 32,287 条/分钟），主页大标题/三状态卡/日志窗口
渲染正常，实时日志滚动正常（截图验证）。

**桌面排障经验**：macOS 上 Flutter 未捕获异常默认走 stderr，`open` 启动的 app
拿不到；`PlatformDispatcher.instance.onError` 兜底写 AppLog 文件是最省事的路子
（本次已常驻 main()，保留）。

## A.10 六项修复（2026-09-05 晚，第二轮）

1. **WorkBuddy 已签到但卡片显示未完成**：`checkin-status.today_checked_in` 实测不可靠
   （代码注释早已记录）。`TaskService.refreshStatuses` 现在与本地 `done.*` 标记取或
   （任务成功时已由调度器写入标记）。
2. **侧栏模式下进 Bing 页侧栏上移**：旧代码按 tab 把外层 Scaffold 的 appBar 置 null，
   Bing 页自带 Scaffold——顶栏消失导致整体上移 40px。现在外层 BlurredAppBar 常驻，
   Bing 页不再自带 Scaffold，操作按钮（开始/兜底/重注入）提升到 `BingWebViewPageState`
   公开方法，主页经 `GlobalKey` 挂到外层顶栏 actions。闭包必须在按下时才读
   `currentState`（构建期页面可能未挂载）。
3. **Bing 页底部导航模糊不生效**：WebView 是原生平台视图，合成在 Flutter 引擎之外，
   `BackdropFilter` 采不到它的像素——这是引擎限制，无法真正模糊。修复：Bing tab 时
   `extendBody=false`，内容不延伸到栏下，底栏落在纯背景上，观感一致。
4. **账号页两处假开关**：`SettingsSwitchItem`（value:false 且 onChanged 空）换成新增的
   `SettingsStatusItem`（纯状态行）；米游社状态同时标注是否有 stoken。
5. **网页登录后米游社任务不跑**：实测（用户真实 cookie，2026-09）——
   - `getUserMissionsState`（任务状态）web cookie 可用；
   - `getForumPostList`/`getPostFull`/`getShareConf` web 通道（client_type=5 +
     saltWeb DS1）可用，**但任务进度不累计**（跑完看帖 mission 59 不出现在 states）；
   - `signIn`/`upvotePost` web 通道 -10001 拒绝，必须 stoken（app 通道）。
   另发现「帖子列表为空」的真正原因：默认兜底 forum_id='2' 是空分区（原神是 26），
   与登录态无关。修复：gids（签到）/forum_id（帖子）按 MihoyoBBSTools 映射表归一化
   （`gidsToForumId`/`forumIdToGids`），默认分区改 gids '2,6'；无 stoken 时任务直接
   给出「请用扫码登录」引导并返回失败（不做无效请求）。**网页登录拿不到 stoken 是
   平台限制（现代登录页不再下发 login_ticket），不是 bug——引导用户用扫码登录。**
6. **日志框随主页滚动**：LogWindow 去掉内部 ListView/ScrollController/自动滚动，
   行直接铺进主页 SingleChildScrollView。注意两点：行仍有 `IntrinsicHeight`
   （stretch Row 需要有限行高）；不能再把 ListView 塞进滚动结构（intrinsic 断言，
   见 A.9）。

验证：analyze 0 issues；macOS debug 构建成功；实机确认 WorkBuddy 卡「已完成」、
账号页无开关、宽屏 Bing 页顶栏常驻侧栏不跳、任务日志输出扫码引导、0 渲染异常。

## A.11 扫码登录 stoken「拿不到」的完整定位（2026-09-05 深夜，已修复）

**现象**：扫码 Confirmed 后弹「stoken 验证未通过」，stoken 不落盘。

**排查路径**（三层递进，全程用户真扫码 + AppLog 留痕）：
1. 无 `x-rpc-app_id` 头 → `-3005 参数不合法`（参数层拒）。补上后 →
2. `-5300 请升级应用版本或删除账号后重新登录`。穷举验证（真 stoken + 8 种头组合：
   版本 2.109/2.114、DS 有无/X6/passport-salt、device_fp 有无、client_type 1/2、
   cookie 带/不带 mid）全部 -5300，其中 passport 专用 salt
   `JwYDpKvLj6MrMqqYU6jTKF17KNO2PXoS` 与 DS 算法（r 含大写，b=body,q=空）
   从米游社 2.114.0 APK 反编译 `RequestUtils.createSign` 提取——头没有问题。
3. **结论：`ma-cn-session/app/getTokenBySToken` 对非官方设备环境有风控，全新有效
   的 stoken 也会被拒**。而 stoken 本身完全有效——用老接口
   `GET api-takumi.mihoyo.com/auth/api/getCookieAccountInfoBySToken`
   （Cookie: stuid/stoken/mid + DS1 + app 通道头）retcode=0 且能换出新 cookie_token；
   用该 stoken 走 bbs `apihub/app/api/signIn`（DS2/X6）**真实签到成功 retcode=0**。

**修复**：`verifyStoken` 改用老接口（成功即有效，顺带刷新 mhy.cookie 里的
cookie_token 并持久化）；彻底放弃 getTokenBySToken。删掉 `_sessionHeaders`/
`ds2Passport`/debug 落盘等临时代码。QR Confirmed 的 token 结构现在会记入日志
（type/len，不含值）。

**排障技巧沉淀**：
- 验证失败的 stoken 先落到本机调试文件，即可离线穷举头组合，不用反复扫码。
- 用户 plist（`~/Library/Preferences/com.autotask.rewardsRunner.plist`，键带
  `flutter.` 前缀）可直接读写；写前必须停 App（cfprefsd 会用内存值覆盖）。
- stoken 种回 prefs 后无需再扫码：`defaults write com.autotask.rewardsRunner
  flutter.sec.mhy.stoken ...`。

**同轮其它改动**：FAB 改纯图标；Bing 起始页改为随机二字词搜索
（`/search?q=<词>&PC=U316&FORM=CHROMN`，词库 1000 词内置 `core/cn_words.dart`，
兜底搜索器同源、次数 30/间隔 12-28s 固定）；设置页 Bing 分组整体删除；
CRX 插件不可行（WKWebView 无扩展运行时，连 Safari 扩展也无法嵌入）。

## A.12 Bing 脚本注入改走原生 UserScript（2026-09-05 深夜，修复悬浮框不出现）

**现象**：Bing 页油猴脚本的悬浮框（Microsoft Rewards 助手面板）不出现，日志整段
生命周期刷「evaluateJavascript 通道未就绪 ×6 → 放弃」，reload 后也无效。

**定性**：不是 AGENTS.md §4.4 记的「注册晚于 onLoadStop」竞态（那个重试能救），
而是该 webview 实例的 method channel 整段死亡——onLoadStop/onConsoleMessage 事件
通道正常回调，evaluateJavascript 的 MethodChannel 永远 MissingPluginException。
无法从 Dart 侧修复。

**修复**：脚本注入彻底弃用 evaluateJavascript，改 `initialUserScripts`
（WKUserContentController 原生注册，webview 创建时传入，每次导航自动执行）：
- 主脚本 + autoStartPatch 都作为 AT_DOCUMENT_END 的 UserScript 挂载
  （autoStartPatch 本身就是 setInterval 轮询点击，天然适合）；
- 脚本异步准备（读资产/自定义脚本）完成后才创建 InAppWebView
  （initialUserScripts 只能在创建时传入）；
- `_safeEval` 仅剩交互按钮与兜底监测在用，retries 降为 2 防刷屏；
- `markDoneToday('bing')` 移到 onLoadStop。

**实测**：悬浮框正常出现，日志「Microsoft Rewards 助手已加载」+
「[AutoStart] clicked 开始自动搜索」，本轮 0 通道错误。

**教训**：WKWebView 里做类油猴注入，一律优先 WKUserScript；
evaluateJavascript 只用于运行期交互。

### A.12.1 autoStartPatch 无限循环回归（同日晚，已修复）

原生 UserScript 化后，autoStartPatch 每次**导航**都重新执行；而点击「开始自动搜索」
本身触发搜索导航 → 新页面又点 → **每 ~1.5s 一轮无限搜索**（旧实现是进入时 eval 一次，
无此问题）。修复：补丁开头检查 localStorage 标记 `__gm_autostart_done_at`，
30 分钟 TTL 内只自动点一次；顶栏手动播放按钮传 `force:true` 绕过标记。
实测：进 Bing 页只加载/解析一次，无重复。
**教训**：挂成 UserScript 的 JS 会在每个页面重新执行，任何"只该做一次"的动作
都要自带持久化去重标记。

## A.13 六项迭代（2026-09-05 深夜第三轮）

1. **Bing 后台运行/切页不刷新**：主页 body 改 `IndexedStack` 四页常驻保活；
   Bing 页按需挂载（`_bingMounted`，进 Bing 页或一键运行时置 true）。
   账号页保活后 `initState` 只跑一次 → 公开 `AccountsPageState.refresh()`，
   `_selectTab` 回访时调用。宽窄判定统一改 MediaQuery 窗口宽度（与 Scaffold 同源）。
2. **Android 进度通知**：`MethodChannel rewards_runner/notifications` +
   MainActivity.kt（NotificationChannel task_progress / POST_NOTIFICATIONS 运行时权限 /
   start/busy/progress/finish/cancel，finish 后 5s 自消）。Dart 封装
   `core/task_notifier.dart`（全部吞异常，非 Android no-op）。设置页「通知」分组
   仅 Android 显示；分组渲染改为按组名聚合（消除下标漂移）。
3. **一键并行**：runAll 改 `Future.wait` 并行 wb+mhy（步骤日志 tag 从 TASK 改为
   WB/MHY，供日志分窗过滤）；Bing 阶段经 `onBingStage` 回调由 UI 后台挂载 webview，
   不切页面，脚本随页面原生注入自动执行。
4/5. **平板主页三列**：宽屏主页 = 每张状态卡下挂对应日志窗口（LogWindow 新增
   `tags` 过滤 + `scrollable` 自滚动模式，含 hasContentDimensions 防御的自动滚底），
   Row `crossAxisAlignment.start` 顶对齐；窄屏（手机竖屏）保持单滚动流 + 全量日志
   不变。展开态改按 LogLine 对象记录（过滤后索引不错位）。
6. **状态本地缓存**：refreshStatuses 里 `isDoneToday` 直接短路（打「本地标记」日志），
   不再查接口——消除「启动日志说未完成、卡片已完成」的矛盾。

**验证**：analyze 0 issues；启动日志（本地标记路径）✓；宽屏三列+顶对齐+按 tag
过滤截图 ✓；单任务执行（用户实测）✓。FAB 一键并行的合成点击验证因与用户实际
操作抢焦点未完成，路径与已验证的单任务执行同构。

## A.14 第四轮：日志行去空白 + MiyoQian 全功能移植 + 米游社图标（2026-09-05 深夜）

1. **日志行前空白**：原行布局 tag 列 flex3 占 30% 宽（tag 只有 2-4 字符，剩下全是
   空白）。改为 tag 紧跟色条 + message 占满剩余宽；步骤日志的两格缩进同时去掉。
2. **米游社任务 MiyoQian（米游签）移植**（只取签到+米游币任务，WebUI/云游戏/
   商品兑换/推送/多账号不要）：
   - **游戏社区签到（luna）**：`event/luna/home|info|sign`（zzz 走
     act-nap-api 的 zzz 路径）+ `x-rpc-signgame`（genshin=hk4e, zzz=zzz），
     web DS（saltBbsWebV206=G1ktdwFL…+2.106.2）+ client_type 5 + web cookie。
     按 game_biz 拉绑定角色逐个签；-5003=今日已签；`data.success==1`=触发
     验证码（未接打码平台，跳过并留痕）。默认游戏 genshin/starrail/zzz
     （`mhy.signGames`）。六游戏 act_id 全部内置。
   - **米游币任务**：任务状态/分享走裸 web 头（无 DS）；任务 app 通道全部换
     MiyoQian 盐（saltBbsV206=idMMaGYm…+2.106.2，与老 K2/2.109.0 并存均可用于不同端）。
     **点赞换了端点**：`POST /post/api/post/upvote` body 带 `gids`（旧
     apihub/sapi/upvotePost 弃用）。任务完成态按 mission 58-61 的 is_get_award
     + happened_times 折算剩余次数（看帖 3/点赞 5）。-100 自动用 stoken 刷
     cookie_token（老接口 getCookieAccountInfoBySToken）重试一次。
   - 分区配置 mhyForums 默认改 '5,2'（大别野/原神，MiyoQian 默认）。
3. **米游社图标**：从米游社 2.114.0 APK `res/mipmap-xxxhdpi-v4/ic_launcher.png`
   (192px) 提取为 `assets/icons/miyoushe.png`，替换原神图标（yuanshen.png 与
   bing_normalized.png 已删）。圆角仍由 SquircleIcon 统一裁切。
4. AGENTS.md 代码地图/4.3/平台配置已同步。

**注意**：任务状态接口当日报「可得 0 分」时会整体跳过（服务端判定已完成），
这是正常短路；游戏签到 luna 与米游币任务是两套独立奖励体系。

### A.14.1 首跑实测与两个修复（同晚）

MiyoQian 移植版首次真实执行：原神签到✓（冒险家的经验x2）、星铁签到✓（凝缩以太x1）、
大别野/原神社区签到✓、看帖3✓、点赞5帖✓（新端点 upvote 带 gids 工作）。唯一失败：
**分享 getShareConf 用 web 裸头返回 403（10B 非 JSON）**，jsonDecode 异常把整个
runAll 炸断。修复：
- `HttpResult.jsonSafe`：非 JSON 响应合成 {retcode:-1, message:…}，任务流程记失败
  步骤而不是中断（mihoyobbs_service 全部改用 jsonSafe）；
- 分享 403 时退避后用 app 通道（stoken+DS1 saltBbsV206）重试一次。
另外：用户连点暂停时 WARN 会刷屏，但 cancel 是粗粒度（任务间生效），属预期。

### A.12.2 自动启动失效真凶：Dart→JS 未插值的 `force`（2026-09-06 凌晨，已修复）

A.12.1 的去重版上线后自动启动全灭（补丁零输出）。逐级插桩（patch entered →
waiting xN → clicked）定位：补丁死于 `if (!force && …)` —— `force` 是 Dart 侧
参数，**从没插值进 JS**，在 JS 里是未定义变量 → ReferenceError 静默死亡；
错误消息不含 [AutoStart] 前缀，被 onConsoleMessage 过滤器吞掉，故无任何痕迹。
修复：`!$force` 插值为 JS 字面量。另两项加固：
- 自动启动补丁并入主脚本同一个 UserScript（多 UserScript 曾疑点之一，合并消除）；
- localStorage 去重标记改为点击**成功派发后**写入（派发失败不写，下页重试）；
- 补丁全程留痕（entered/waiting xN/clicked/give up），间隔 500ms×120（60s 窗口）。

**最终实测**：进 Bing 页 → patch entered → clicked → 面板按钮变「停止搜索」，
搜索词「technology vf0」（词库词+脚本随机后缀）自动搜索进行中。

**教训**：Dart 拼接 JS 时，所有 Dart 参数必须显式插值为 JS 字面量；
裸标识符就是 JS 未定义变量。未捕获的 JS 异常不会经过 onConsoleMessage
的消息过滤器能匹配的文本——关键路径要有自己的 console 留痕。

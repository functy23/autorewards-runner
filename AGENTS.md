# AGENTS.md — AutoRewards Runner (rewards_runner)

> 本文件是 AI 代理（ZCode/Claude 等）在此仓库工作的完整操作手册。目标：任何代理读完后，
> 不需要重新侦查就能正确构建、修改、排错、交付本项目。**请先通读本文再动代码。**

---

## 0. 项目一句话

Flutter（Dart）跨平台 App（macOS + Android），自动化三类本地任务：

| 任务 | 实现方式 | 关键文件 |
|------|---------|---------|
| Microsoft Bing Rewards 刷分 | App 内 WebView 注入油猴脚本（greasyfork 538825 v1.3.2 内置）+ 自动点击启动 + 兜底搜索器 | `lib/webview/bing_webview_page.dart`、`lib/services/userscript/userscript_engine.dart` |
| 米游社（米游币）每日任务 | 纯 HTTP：DS1/DS2 签名 + stoken 登录态；支持扫码/网页/Cookie 三种登录 | `lib/services/mihoyobbs/`、`lib/webview/mihoyo_web_login_page.dart` |
| WorkBuddy 每日积分 | 读取本机桌面端明文登录态 + 官方接口（仅需 Bearer token） | `lib/services/workbuddy/workbuddy_service.dart` |

**硬性红线（用户明确要求，不可违反）：**
1. 所有凭据（cookie/stoken/WorkBuddy token/Bing Cookie）**只存本机**（SharedPreferences `sec.*` 键），不连任何第三方服务器。
2. 日志层对 `stoken=/accessToken/Bearer` 等有正则打码兜底——改动 `app_log.dart` 时必须保留。
3. UI **不允许"AI 味"通用卡片布局**；主页日志窗口与设置页/账号页**逐像素移植 aShellYou**（参考仓库在用户本地 `/Users/functy/Downloads/aShellYou-master`，若存在必须先读源码再仿写）。
4. 底部导航栏/侧栏**禁止悬停 tooltip**（用户明确要求删除过）。
5. 侧栏**只有纯图标一种形态**，展开/收起功能已按用户要求删除，不要再加回来。
6. 主页顶栏**不显示 App 名称**（名称是主页内随滚动的大标题）；右上角**没有全局执行按钮**（执行入口是主页右下角 FAB「执行全部」和每张状态卡右侧的播放小按钮）。

---

## 1. 环境事实（functy 的 Mac，2026-09 实测）

| 项 | 值 |
|----|-----|
| Flutter | 3.47.2 stable（`/opt/homebrew/bin/flutter`），Dart 3.13.2 |
| Xcode | 16.2 (16C5032a) |
| CocoaPods | 1.17.0（brew，`/opt/homebrew/bin/pod`） |
| Android SDK | `~/Library/Android/sdk`（platform-tools 35 / build-tools 35 / NDK 28.2.13676358），cmdline-tools 在 `/opt/homebrew/share/android-commandlinetools` |
| Java | Zulu 25（gradle 兼容，无需额外配置） |
| 网络 | **curl 必须走代理** `http://127.0.0.1:7890`（系统代理已开），否则外网 SSL 直连失败 |
| node/git | `/opt/homebrew/bin/node`、`/usr/bin/git` |

### ⚠️ 最重要的环境陷阱：工作区路径含撇号

本项目位于 `/Users/functy/Desktop/functy's idk/rewards_runner/`——路径中的 `'` 会让
CocoaPods 生成的 `Pods-Runner-frameworks.sh` 在 `eval` 时引号断裂，macOS 构建报：

```
Pods-Runner-frameworks.sh: eval: line 174: unexpected EOF while looking for matching `'
```

**唯一可靠解法：在无撇号的影子目录构建。** 影子目录约定：

- 影子路径：`/Users/functy/rewards_runner/`（已存在且验证可编译）
- 同步命令（工作区 → 影子，构建前必跑）：

```bash
rsync -a --delete \
  --exclude build --exclude .dart_tool --exclude "macos/Pods" \
  --exclude "macos/Podfile.lock" --exclude .gradle \
  "/Users/functy/Desktop/functy's idk/rewards_runner/" /Users/functy/rewards_runner/
```

- **构建一律在影子目录执行**；**改代码一律在工作区**（影子目录只是构建镜像，不要手改）。
- 改完 → rsync → 影子目录 `flutter build ...`。
- 如果影子目录被删：先 `flutter pub get`，再 `cd macos && pod install`，然后正常构建。

### 构建产物交付（用户硬性要求）

**所有最终产物复制到 `~/Downloads/`**（已写入全局记忆，每次交付都必须做）：

```bash
cp /Users/functy/rewards_runner/build/app/outputs/flutter-apk/app-debug.apk ~/Downloads/rewards_runner-debug.apk
cp -R /Users/functy/rewards_runner/build/macos/Build/Products/Debug/rewards_runner.app ~/Downloads/
```

---

## 2. 常用命令速查

```bash
cd /Users/functy/rewards_runner          # 影子目录（构建用）
flutter analyze                          # 交付前必须 0 issues
flutter build macos --debug              # macOS 构建 → build/macos/Build/Products/Debug/rewards_runner.app
flutter build apk --debug                # Android 构建 → build/app/outputs/flutter-apk/app-debug.apk
flutter run -d macos --debug             # 带控制台运行（查渲染异常/崩溃栈用这个）
flutter pub get                          # pubspec 变更后
```

运行时验证建议：`open .../rewards_runner.app` 启动后看日志文件
`~/Library/Application Support/rewards_runner/logs/app-YYYYMMDD.log`。

**Android 依赖修补（pub get 后可能需要重做，见 §6）：**

```bash
sed -i '' "s/getDefaultProguardFile('proguard-android.txt')/getDefaultProguardFile('proguard-android-optimize.txt')/g" \
  ~/Library/.pub-cache/hosted/pub.dev/flutter_inappwebview_android-*/android/build.gradle
# 实际路径以 flutter pub cache 为准：~/.pub-cache/hosted/pub.dev/...
```

---

## 3. 代码地图（20 个 Dart 文件，职责一览）

```
lib/
├── main.dart                     # 入口 + HomePage：IndexedStack 四页保活/自适应布局/模糊顶底栏/
│                                 #   大标题/纯图标 FAB；宽屏=侧栏+三列(卡片+各自日志窗口)，窄屏=底栏+单滚动流
├── core/
│   ├── app_log.dart              # 全局日志：内存环形缓冲(500) + 文件(7天轮转) + 敏感信息正则打码 + 广播流
│   ├── app_prefs.dart            # SharedPreferences 封装：普通配置 + sec.* 机密 + 导出/导入 JSON
│   ├── task_notifier.dart        # Android 进度通知封装（MethodChannel→MainActivity，非 Android no-op）
│   ├── cn_words.dart             # 内置 1000 汉语二字词（Bing 随机搜索词）
│   └── http_box.dart             # HTTP 封装：超时/重试(指数退避)/UA 常量/只记 URL+状态码
├── crypto/
│   ├── md5.dart                  # 手写 RFC1321 MD5（DS 签名依赖，勿引入 crypto 包替代）
│   └── uuid_v3.dart              # uuid3(NAMESPACE_URL, seed) → 米游社 device_id
├── services/
│   ├── mihoyobbs/
│   │   ├── ds_sign.dart          # DS1/DS2 签名：K2+2.109.0（老组合，已验证）与 MiyoQian 配对
│   │   │                         #   saltBbsV206/saltBbsWebV206+2.106.2（任务用）两套并存
│   │   └── mihoyobbs_service.dart# 登录态解析+扫码登录(QR stoken v2)+游戏签到(luna/act_id+角色+奖励列表)
│   │                             #   +米游币任务(社区签到/看帖/点赞(post/api/post/upvote带gids)/分享)
│   │                             #   ——任务段为 MiyoQian(米游签) 移植，盐与流程以其为准
│   ├── workbuddy/
│   │   └── workbuddy_service.dart# 本机 auth 文件读取(macOS)+checkin-status+daily-checkin
│   └── userscript/
│       └── userscript_engine.dart# 油猴元数据解析+GM_* polyfill+自动启动补丁(30min 去重；Dart 拼 JS
│                                 #   的参数必须插值成字面量——裸 force 曾致 ReferenceError 静默失效)
├── tasks/
│   └── scheduler_service.dart    # TaskService：runAll(wb/mhy并行+onBingStage回调)/runSingle/cancel
│                                 #   +refreshStatuses(本地标记短路)+statuses ValueNotifier
├── ui/
│   ├── theme.dart                # buildAppTheme(fromSeed)+BlurredAppBar+SquircleIcon+StatusCard
│   ├── pages/
│   │   ├── accounts_page.dart    # 账号页（AccountsPageState 公开 refresh()，米游社三登录+WorkBuddy）
│   │   └── settings_page.dart    # 设置页（搜索+按组名聚合+游戏签到开关+通知权限(Android)+导出/导入）
│   └── widgets/
│       ├── common.dart           # CopyableField（复制按钮→对勾动效 1.5s）
│       ├── log_window.dart       # 日志窗口：tags 过滤 + scrollable 双形态（内联铺开/自滚动窗口）
│       └── settings_items.dart   # aShellYou settings-dsl 移植：GroupHeader/CardGroup/SwitchItem/
│                                 #   TapItem/ContentItem/StatusItem(纯状态行)/ItemLeadingIcon/PressableScale
└── webview/
    ├── bing_webview_page.dart    # Bing 页：initialUserScripts 原生注入（勿用 evaluateJavascript 注入）+
    │                             #   随机二字词起始搜索页+兜底搜索器；BingWebViewPageState 公开操作方法
    └── mihoyo_web_login_page.dart# 米游社官方网页登录 → 多域 Cookie 提取（仅状态查询，任务需扫码）
```

平台配置：

```
macos/Runner/MainFlutterWindow.swift  # 沉浸式顶栏（titleVisibility hidden + titlebarAppearsTransparent
                                      #   + fullSizeContentView + isMovableByWindowBackground）
macos/Runner/*.entitlements           # 沙盒关闭 + network.client + user-selected 读写（读本机 auth 必须）
android/app/src/main/AndroidManifest.xml  # INTERNET/ACCESS_NETWORK_STATE/POST_NOTIFICATIONS + enableOnBackInvokedCallback
android/app/.../MainActivity.kt   # 任务进度通知（MethodChannel rewards_runner/notifications，见 core/task_notifier.dart）
android/build.gradle.kts              # 子项目 JVM target 统一 17（withPlugin("com.android.library") 钩子）
assets/userscripts/                   # 内置油猴脚本（74KB，greasyfork 538825 v1.3.2 原版）
assets/icons/                         # 官方图标：workbuddy(icns→png)、miyoushe(APK res/mipmap-xxxhdpi 提取)、
                                      #   bing(官网 apple-touch-icon)；SquircleIcon 裁 G2 圆角
```

---

## 4. 架构决策与约定（改动前必读）

### 4.1 UI 设计体系（两条规范交叉执行）

- **Material Design 3**：`ColorScheme.fromSeed`（种子 `0xFF3949AB`），light/dark 全 token，
  禁止业务代码硬编码 `Colors.green/red/grey.xxx`——用角色（primary/onSurfaceVariant/errorContainer…）。
- **aShellYou 移植 token**（settings_items.dart 已实现，直接复用，不要另起炉灶）：
  - 分组标题：`labelLarge` + primary 色，左缩进 31，上 24 下 8
  - 卡片组连体圆角：单卡 24 / 首卡上24下4 / 中卡 4 / 末卡上4下24，卡间距 1，surfaceContainer 无描边无阴影
  - 条目：内边距 17，列间距 17；前导图标 = primaryContainer 圆底 + 10dp padding + 20dp 图标
  - 标题 titleMedium w600，描述 bodySmall 70% 透明度
  - 按压缩放 0.98（PressableScale，120ms easeOut）
  - 日志行：4dp 左色条撑满行高 + tag 列 flex3（mono w600 11sp）+ message 列 flex7（onSurface 87%），
    无圆角无间距，点击展开（AnimatedSize 200ms）
  - 级别色：DEBUG 0xFF4FC3F7 / INFO 0xFF81C784 / WARN 0xFFFFB74D / ERROR 0xFFE57373 / 其它灰；
    暗色用原色，亮色 `Color.lerp(base, black, 0.45)`
- **Apple 规范**：顶栏/底栏用半透明 + BackdropFilter 模糊（材质层，内容从其下滚过）；
  macOS 顶栏高度 40 给交通灯留位（`BlurredAppBar` 已处理 leadingWidth 逻辑在 main.dart `_appBar`）。

### 4.2 布局断点

- `< 840dp`（手机竖屏）：底部 NavigationBar（模糊背景）+ 状态卡竖向全宽堆叠 + `extendBody: true`
- `≥ 840dp`（横屏/平板/桌面）：图标 NavigationRail + 状态卡横排
- 断点常量在 main.dart `_wideBreakpoint`。

### 4.3 状态与数据流

- **真实完成状态**：`TaskService.statuses`（ValueNotifier<Map<String,bool?>>，键 `wb/mhy/bing`）。
  刷新时**本地当日标记直接短路**（日志打「本地标记」，不再调接口——接口 today_checked_in
  不可靠，且避免启动时日志与卡片矛盾）；无标记才查线上（wb 查 checkin-status、
  mhy 查 getUserMissionsState）。主页启动时和任务结束后各刷一次。
  StatusCard 显示：未配置 / 查询中… / 已完成 / 未完成——**不是**"跑过就算完成"。
- **任务执行**：主页 FAB（runAll：wb/mhy **并行** + onBingStage 后台挂载 Bing 页）+
  状态卡小播放按钮（runSingle）。Bing 单任务执行 = 挂载并切到 Bing 页。
- **页面保活**：IndexedStack 四页常驻；Bing 按需挂载（`_bingMounted`），切走后
  webview 继续跑，切回不刷新。
- **日志驱动 UI**：HomePage 订阅 `AppLog.stream`，每条日志 setState 刷新（简单但有效，勿改成局部通知除非卡顿）。
- **米游社任务（MiyoQian 移植）**：游戏签到（luna，`mhyGameSign`，默认
  genshin/starrail/zzz，`mhySignGames` 可配）+ 米游币任务（社区签到 `mhySign`/
  看帖/点赞/分享/取消点赞，分区 `mhyForums` 默认 '5,2'）。任务请求用 MiyoQian
  盐对（saltBbsV206/saltBbsWebV206 + 2.106.2）；验证码不接打码平台，触发即跳过。

### 4.4 WebView 与 JS 注入

- macOS 上 flutter_inappwebview 的 MethodHandler 注册晚于 `onLoadStop`，直接
  `evaluateJavascript` 会抛 `MissingPluginException`——**所有 JS 调用必须走
  `_safeEval()`（带退避重试）**，bing_webview_page.dart 里的实现照抄即可。
- `PullToRefreshController` 仅 Android 支持，必须 `Platform.isAndroid ? ... : null`。
- `QrImageView`（qr_flutter）放进 AlertDialog 会崩（内部 LayoutBuilder 与 intrinsic 测量冲突）——
  必须用 `CustomPaint + QrPainter` 固定尺寸（accounts_page.dart 已是正确写法）。
- 米游社扫码登录接口（实测 2026-09）：`POST passport-api.mihoyo.com/account/ma-cn-passport/app/createQRLogin`
  → `queryQRLoginStatus?ticket=`（**不是** ma-cn-verifier，那个 404）。
  Confirmed 后 tokens 里 token_type=1 是 stoken v2。

### 4.5 敏感字段与存储

- 键约定：`sec.mhy.cookie/stoken/stuid/mid`、`sec.wb.token/uid/domain/enterpriseId`。
- WorkBuddy 桌面端明文登录态（macOS）：
  `~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info`
  （JSON：`auth.accessToken` + `account.uid`）。旧版 state.vscdb 加密分支**不做**。
- 配置导出/导入：`_format: autorewards-config` JSON，含 prefs 全量 + bingCookies（Bing 登录态）。
  导出落 `~/Downloads/`（macOS）。

---

## 5. 文档资产

| 文件 | 内容 | 何时读 |
|------|------|--------|
| `docs/REVERSE_REPORT.md` | 米游社接口/DS 算法/请求头、WorkBuddy 文件与接口、Bing 脚本改造要点、防检测策略 | 改服务层、更新 salt/接口前 |
| `docs/BUILD_NOTES.md` | 本机全部踩坑：AGP9 proguard、JVM target、撇号路径、SDK 许可、QR 接口实测、QrPainter、CgBI PNG | 构建失败、加新依赖前 |
| `README.md` | 面向用户的使用说明 | 写发布说明时对齐 |

---

## 6. 已知问题清单（截至最后修改）

0. **2026-09-05 晚修复汇总**（WorkBuddy 状态卡采信本地标记 / 顶栏常驻侧栏不跳 /
   Bing 页 extendBody=false / 账号页 SettingsStatusItem / 米游社 gids 映射+无 stoken
   引导 / 日志随主页滚动 / FAB 纯图标 / Bing 随机二字词起始页（词库 core/cn_words.dart）/
   设置页 Bing 分组已删 / **扫码登录 stoken 已打通**——验证改用老接口
   getCookieAccountInfoBySToken，getTokenBySToken 有设备风控勿再用，见 BUILD_NOTES A.11）：
   细节见 `docs/BUILD_NOTES.md` A.9-A.11。
   **红线新增**：主页日志行禁止改回 ListView/内部滚动（RenderViewport intrinsic
   断言会让整页空白）；Bing 页禁止自带 Scaffold（外层顶栏会消失）；
   米游社验证/换 token 禁止走 ma-cn-session（风控 -5300）。
   CRX 浏览器插件不可行：WKWebView 无扩展运行时。
1. **工作区撇号路径** → 影子目录构建（§1），永久有效，除非项目搬走。
2. **flutter_inappwebview_android 1.1.3 与 AGP 9 不兼容**（proguard-android.txt 被移除）→
   修补 pub-cache（§2）。`flutter pub get`/升级依赖后若 Android 构建报同样错误，重跑 sed。
3. **插件 JVM target 不一致** → android/build.gradle.kts 的 subprojects 钩子统一 17（已修，勿删）。
4. **主页空白**（2026-09-05 已修复，根因与修法见 `docs/BUILD_NOTES.md` A.9）——
   `SliverFillRemaining(hasScrollBody:false)` 布局时查子树 intrinsic 高度，包住含
   ListView 的 LogWindow 首帧即炸（RenderViewport 不支持 intrinsic 查询），geometry
   永远 null，渲染管线每帧中断 → 主页整片空白。已改为 `Column + Flexible(
   SingleChildScrollView)` + `Expanded(LogWindow)`；连带修复 `_LogRow` stretch 行
   无限高度（外包 IntrinsicHeight）与 jumpTo 的 `hasContentDimensions` 防御。
   **勿再往 sliver 结构里塞可滚动子树。**
5. **设置页动画**（用户最后需求，未完成）：aShellYou 设置页顶部有「大 logo + 动态背景」
   （源码在 `/Users/functy/Downloads/aShellYou-master/feature/settings/.../presentation/`，
   找 `ProfilePic.kt` / `AiGenerationAnimationBox.kt` / animatedcomposable 目录），尚未移植。
6. `assets/icons/bing_normalized.png` 是冗余文件（重编码试验残留），可删。
7. `lib/accounts/` 目录曾出现但为空/未使用，可删。

---

## 7. 工作流规矩（本项目实操经验）

1. **改代码 → analyze → rsync → 影子构建 → 运行验证 → 产物到 ~/Downloads**，缺一步都可能翻车。
2. **大任务先 TodoWrite 列清单**，用户是一次性多需求派工型（一口气 7-11 条），漏条会被点名。
3. 用户偏好：不要中途提问（大构建自主完成）；只有需要凭据/真机测试才开口。
4. 每轮踩坑**追加到 `docs/BUILD_NOTES.md`**（不要重写），下一轮代理靠它省侦查时间。
5. 用 Edit/Write 工具改文件；**避免用 python/sed 批量改源码**——会绕过文件状态追踪，
   后续 Edit 会被 "File has been modified" 拦截，浪费来回（本项目已发生多次）。
   必须用脚本时，改完后 Read 一次目标文件再继续工具编辑。
6. 中文回复用户；日志/代码注释/文档保持中文优先。
7. UI 改动必须**实际启动截图/无障碍树验证**（macOS 用 computer-use），不是 analyze 过就算完。
8. 用户在用电脑时避免抢焦点做全屏验证；改用 `get_app_state` 无障碍树后台确认。

---

## 8. 测试与验收基线

- `flutter analyze`：0 issues（当前基线，别让数字倒退）。
- macOS debug build 成功 + 启动后日志文件出现「日志系统初始化完成 / AutoRewards Runner 启动中…」。
- Android debug APK 构建成功。
- 主页三张状态卡 + 日志窗口渲染正常（日志窗口应有实时输出——启动即有 APP/TASK 行）。
- 米游社扫码登录：点扫码 → 二维码渲染 → 日志出现 queryQRLoginStatus 轮询（200 Created）。
- Bing 页：加载 bing.com → 状态栏「脚本已注入」或进入兜底模式（20s 无脚本 UI）。

---

*最后更新：2026-09-05（第三轮 UI 打磨会话中，会话被中断于 §6.4/§6.5 两项）。*

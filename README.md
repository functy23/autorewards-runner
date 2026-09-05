# AutoRewards Runner

一个 Flutter 跨平台（Android + macOS）自动任务 App：

- **Microsoft Bing Rewards 自动刷分**：App 内 WebView 注入油猴脚本（greasyfork 538825
  「Microsoft Bing Rewards 自动搜索助手」v1.3.2 内置），支持自动启动 + 兜底搜索器。
- **米游社每日任务**：纯 HTTP 实现（看帖/点赞/分享/签到），DS 签名 Dart 实现；
  支持扫码登录 / 网页登录（密码、短信验证码）/ Cookie 粘贴三种登录方式。
- **WorkBuddy 每日积分**：读取本机桌面端登录态调用官方签到接口（macOS 免粘贴）。
- **自适应布局**：窄屏底部导航栏（毛玻璃）；≥840dp（横屏/平板/桌面）切换为
  纯图标侧栏；平板比例下主页为三列布局（每张任务卡下挂各自的实时日志窗口）。
- **任务并行**：一键运行 WorkBuddy + 米游社 并行执行，Bing 页后台挂载自动跑脚本；
  Android 端任务进度实时通知。
- **配置文件**：全量配置 + 凭据 + Bing 浏览器 Cookie 一键导出/导入，可跨客户端迁移。

> ⚠️ **风险提示**：自动刷分/签到可能违反 Bing Rewards、米游社、WorkBuddy 用户协议，
> 存在封号风险。所有登录态仅保存在本机、不连接任何第三方服务器。请自行评估风险，
> 勿用于他人账号或批量账号。

---

## 1. 环境配置（macOS 开发机）

```bash
# Xcode（App Store 或 xcodes）+ 命令行工具
xcode-select --install

# Homebrew 基础包
brew install --cask flutter   # 若未装 flutter
brew install cocoapods

# Android（可选，只发 macOS 可跳过）
brew install --cask android-studio
# 在 Android Studio → SDK Manager 安装 SDK 34+，然后：
flutter config --android-sdk ~/Library/Android/sdk

# 验证
flutter doctor
```

本项目开发时的版本参考：Flutter 3.47.2 / Dart 3.13.2 / Xcode 16.2 / CocoaPods 1.16+。
Android 侧 minSdk=23。

## 2. 项目创建（本仓库已创建，此步骤留档）

```bash
flutter create --org com.autotask --project-name rewards_runner \
  --platforms macos,android rewards_runner
cd rewards_runner
flutter pub get
```

## 3. 编译运行

### macOS

```bash
cd rewards_runner
flutter run -d macos                 # 开发
flutter build macos --release        # 产物:
# build/macos/Build/Products/Release/rewards_runner.app
```

### Android

```bash
flutter devices                      # 确认设备/模拟器
flutter run -d <device-id>
flutter build apk --release          # 产物:
# build/app/outputs/flutter-apk/app-release.apk
```

## 4. 使用说明

### 4.1 WorkBuddy（最省事）

1. macOS 上安装并**登录 WorkBuddy 桌面端**（v5.3.8+）。
2. App → 账号 → WorkBuddy → 点「从本机读取」。
   （Android：把桌面端的 accessToken 粘贴进输入框）
3. 完成。手动执行或等定时；已签到时接口返回 10001 自动跳过。

### 4.2 米游社

1. 抓包米游社 App 任意请求的 Cookie（推荐含 `stoken=v2_...`），或在网页登录后复制。
   支持三种格式：`stoken`（推荐）、`login_ticket`（30 分钟内自动兑换）、普通 cookie。
2. App → 账号 → 米游社 → 粘贴 → 「导入并验证」。
3. 可选配置：任务开关（签到/看帖/点赞/分享）、点赞后自动取消、分区列表（默认原神+星铁）。

### 4.3 Bing Rewards

1. App → Bing 页，WebView 打开 bing.com。
2. **登录 Microsoft 账号**（首次手动登录一次，cookie 会保留）。
3. 若开启「自动开始」（默认开），脚本 UI 出现后会自动点击「开始自动搜索」。
   也可以点 AppBar 的 ▶ 手动开始。
4. 若脚本 UI 20 秒未出现（改版等），App 自动启用兜底搜索器（本地词库+随机延迟）。

### 4.4 运行时机（当前版本）

- 每日定时调度已移除。设置页提供「App 启动时自动运行所有任务」开关（默认关闭）；
  打开后每次启动 App 自动跑一轮，也可随时点主页右上角 ▶ 手动执行。

### 4.5 换成/添加自己的油猴脚本

- 账号页 → 「自定义油猴脚本」，粘贴完整脚本（含 `==UserScript==` 头）即可覆盖内置
  脚本；清空则恢复内置。
- 引擎自动提供 `GM_getValue/GM_setValue/GM_addStyle/GM_xmlhttpRequest/unsafeWindow`
  polyfill（localStorage 持久化）。
- 想内置多个脚本：把 `.user.js` 放进 `assets/userscripts/`，在 pubspec 注册后于
  `lib/webview/bing_webview_page.dart` 的 `_injectUserscript()` 里按 URL 匹配注入。

## 5. 项目结构

```
rewards_runner/
├── assets/userscripts/
│   └── bing_rewards_1.3.2.user.js      # 内置油猴脚本（greasyfork 538825 原版）
├── docs/
│   └── REVERSE_REPORT.md               # 逆向/抓包分析报告（接口、签名、文件路径）
├── lib/
│   ├── main.dart                       # 入口 + 主页（总览/手动执行）
│   ├── core/
│   │   ├── app_log.dart                # 日志（环形缓冲 + 文件，敏感信息打码）
│   │   ├── app_prefs.dart              # 本地配置/机密存储（sec.* 命名空间）
│   │   └── http_box.dart               # HTTP 封装（超时/重试/退避）
│   ├── crypto/
│   │   ├── md5.dart                    # RFC1321 MD5（DS 签名依赖）
│   │   └── uuid_v3.dart                # uuid3(cookie) → 米游社 device_id
│   ├── services/
│   │   ├── mihoyobbs/
│   │   │   ├── ds_sign.dart            # DS1/DS2 签名算法
│   │   │   └── mihoyobbs_service.dart  # 登录态解析+全任务流程
│   │   ├── workbuddy/
│   │   │   └── workbuddy_service.dart  # 本地 auth 读取 + 签到
│   │   └── userscript/
│   │       └── userscript_engine.dart  # 油猴解析/GM polyfill/自动启动补丁
│   ├── tasks/
│   │   └── scheduler_service.dart      # 应用内调度 + launchd 配置生成
│   ├── webview/
│   │   └── bing_webview_page.dart      # Bing WebView + 兜底搜索器
│   └── ui/pages/
│       ├── accounts_page.dart          # 账号/配置页
│       └── logs_page.dart              # 日志页
├── macos/Runner/*.entitlements         # 关沙盒 + network.client（读本机 auth 必需）
└── android/app/src/main/AndroidManifest.xml  # INTERNET 权限
```

## 6. 配置与存储

| 数据 | 位置 | 键 |
|------|------|----|
| 米游社 cookie/stoken | 本机 SharedPreferences | `sec.mhy.*` |
| WorkBuddy token | 本机 SharedPreferences | `sec.wb.*` |
| 调度/任务开关/Bing 词库 | 本机 SharedPreferences | `scheduler.* / mhy.* / bing.*` |
| 运行日志 | `<AppSupport>/logs/app-YYYYMMDD.log`（7 天轮转） | — |

导出/检查：日志页可看全部运行日志；`AppPrefs.exportJson()` 可在调试时 dump 全部配置
（含机密，**不要外传**）。

## 7. 已知限制

- 米游社极验（retcode 1034）不过码：触发时该分区/帖子跳过，次日再试。
- WorkBuddy 旧版（< v5.3.8，state.vscdb 加密存储）不支持在 App 内解密——先打开
  桌面端登录一次，登录态会迁移为明文文件。
- Bing 的 mobile 端分数需要单独用移动 UA 会话刷，App 内 WebView 默认刷 PC 分。
- Android 定时依赖 App 进程存活；如需强保证，建议后续加 `workmanager` 原生插件。
- **工作区路径含撇号（如 `functy's idk`）会导致 CocoaPods 生成的签名脚本 eval 失败**
  （`Pods-Runner-frameworks.sh` 用单引号包路径）。解决：把项目移到无撇号路径再
  `flutter build macos`，或编译前 `pod install` 后手工把该脚本里的
  `--preserve-metadata=identifier,entitlements '$1'` 改为双引号。
- `flutter_inappwebview_android 1.1.3` 的 build.gradle 使用 AGP9 已移除的
  `proguard-android.txt`：本仓库已说明修法（替换为 `proguard-android-optimize.txt`），
  若重新 `flutter pub get` 后报同样错误，按 docs/REVERSE_REPORT.md 附录 A 修补。

---

## 8. 致谢与参考项目

本项目的实现大量参考/移植了以下开源项目与脚本，感谢这些作者的慷慨分享：

| 项目 | 用途 |
| --- | --- |
| [MiyoQian（米游签）](https://github.com/Marchen-orz/MiyoQian) | 米游社任务核心实现参考与移植来源：游戏社区签到（luna 接口/act_id/角色/奖励）、米游币任务流程（社区签到/看帖/点赞/分享）、新一代 DS salt 配对、点赞新端点（`post/api/post/upvote` 带 gids） |
| [MihoyoBBSTools](https://github.com/Womsxd/MihoyoBBSTools) | 米游社接口与 DS 签名算法的逆向参照（salt/版本对应关系、请求头、云游戏 Token 获取方法） |
| [aShellYou](https://github.com/DP-Hridayan/aShellYou) | 日志窗口与设置页的 UI 设计移植来源（LogEntryRow 行设计、settings-dsl 连体卡片组） |
| [workbuddy-checkin](https://github.com/Coco-katarina/workbuddy-checkin)（原始 skill：[cat-xierluo/legal-skills](https://github.com/cat-xierluo/legal-skills)） | WorkBuddy 签到接口与桌面端登录态机制的逆向来源 |
| [Microsoft Bing Rewards 自动搜索助手](https://greasyfork.org/zh-CN/scripts/538825)（作者 WretchedSniper，MIT） | App 内置的 Bing Rewards 油猴脚本本体（v1.3.2 原版，见 `assets/userscripts/`） |
| [GetToken](https://github.com/HolographicHat/GetToken) | 扫码登录/Token 交换的排障参考 |
| [UIGF 米游社 API 文档](https://uigf.org/zh/mihoyo-api-collection/hoyolab/user/token.html) | Token 相关接口的社区文档 |

主要依赖：[Flutter](https://flutter.dev)、[flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview)、[http](https://pub.dev/packages/http)、[qr_flutter](https://pub.dev/packages/qr_flutter)、[shared_preferences](https://pub.dev/packages/shared_preferences)。

> 以上项目版权归原作者所有；本项目对其的使用方式见各项目开源协议。米游社相关接口
> 的 salt/版本会随官方客户端更新而轮换，失效时请参照上述上游项目的最新值更新
> `lib/services/mihoyobbs/ds_sign.dart`。

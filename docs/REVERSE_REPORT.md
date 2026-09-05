# 逆向 / 抓包分析报告

> 本报告是 `rewards_runner` App 的逆向依据。所有结论均来自：
> 1. 本地参考项目源码（`MihoyoBBSTools-master`、`workbuddy-checkin-main`）
> 2. Greasyfork 公开脚本（538825，v1.3.2，已随仓库保存在 `assets/userscripts/`）
> 3. 公开接口行为验证
>
> 本项目不连接任何第三方服务器，所有登录态仅保存在本机。

---

## 1. Microsoft Bing Rewards（WebView + 油猴脚本）

### 1.1 脚本结构（greasyfork 538825 v1.3.2，74KB）

| 要素 | 内容 |
|------|------|
| 匹配 | `*://*.bing.com/*`，`@run-at document-end`，`@grant none` |
| 启动方式 | `window load` 后创建浮动 UI 面板，等待用户点 **「开始自动搜索」** 按钮 |
| 搜索词来源 | 优先主文档（`.b_vList.b_divsec`、`.rslist`、`.richrsrailsugwrapper`）→ Rewards 侧栏 iframe（`.ss_items_wrapper`）→ 保底词表（iPhone/Tesla/NVIDIA... 15 个） |
| 进度检查 | 打开 Rewards 侧栏（`.points-container`），从 iframe 读 `.daily_search_row` 进度；失败则按 `fallbackSearchCount=20` 次计数 |
| 仿真行为 | 搜索间隔 `5~10s` 随机；搜索后随机滚动 `10s`（100~400px/秒，70% 向下 30% 向上）；连续 3 次无进度休息 5 分钟；保底模式下给词加 2~4 位随机后缀 |
| 提交方式 | 填 `#sb_form_q`，`#sb_form.submit()`（真实表单提交，非 fetch） |

### 1.2 App 内改造要点

1. **自动启动**：原脚本必须手动点按钮。App 注入 `autoStartPatch()`：每 500ms 扫描
   `textContent === '开始自动搜索'` 的元素并 `dispatchEvent(new MouseEvent('click'))`。
   这是脚本自己创建的按钮，其 onclick 不校验 `event.isTrusted`，模拟点击有效。
2. **GM_* polyfill**：脚本 `@grant none`，但为兼容用户自带脚本，引擎注入
   `GM_getValue/GM_setValue`（localStorage 模拟）、`GM_addStyle`、`GM_xmlhttpRequest`（fetch 实现）、`unsafeWindow`。
3. **兜底搜索器**：若 20 秒内检测不到脚本 UI（脚本改版/被 Bing 改版破坏），启用
   Dart 侧 `BingAutoSearcher`：本地词库 + 2~4 位随机后缀 + `bing.minDelay~maxDelay`
   随机间隔 + 表单提交 + 随机滚动。
4. **必须非隐身模式**：Bing 登录态（cookie）存在 WebView 常规存储里。
5. **UA 策略**：macOS WKWebView / Android WebView 用系统默认 UA（本身就是真实浏览器
   指纹），**不要伪装成桌面 Chrome** —— Microsoft Rewards 对 mobile 分数独立计数，
   想刷 mobile 分换 UA 即可。

### 1.3 防检测要点（降低封号概率）

- 保持随机延迟（本 App 默认 12~28s，比脚本默认 5~10s 更保守，可自行调）。
- 保留随机滚动与休息逻辑（脚本自带）。
- 每次搜索词尽量不重复（脚本已用去重列表 + 保底模式随机后缀）。
- 不要 24 小时挂机；每天完成 90 分所需次数即可（约 30+ 次 PC 搜索）。
- Rewards 的反作弊核心是「搜索节奏 + 词多样性 + 设备指纹」，WebView 方案与真人
  使用同一浏览器引擎，风险显著低于 HTTP 直接刷。

---

## 2. 米游社（miyoushe / 米游币）

> 逆向来源：`MihoyoBBSTools-master`（tools.py / setting.py / login.py / mihoyobbs.py）

### 2.1 域名与关键接口

| 接口 | 方法 | 用途 |
|------|------|------|
| `bbs-api.miyoushe.com/apihub/wapi/getUserMissionsState?point_sn=myb` | GET | 任务状态（58=签到 59=看帖 60=点赞 61=分享） |
| `bbs-api.miyoushe.com/apihub/app/api/signIn` | POST | 讨论区签到，body `{"gids":"1"}` |
| `bbs-api.miyoushe.com/post/api/getForumPostList` | GET | 帖子列表（`forum_id/page_size=20/sort_type=1`） |
| `bbs-api.miyoushe.com/post/api/getPostFull` | GET | 看帖（计数） |
| `bbs-api.miyoushe.com/apihub/sapi/upvotePost` | POST | 点赞/取消，body `{"post_id":"...","is_cancel":false}` |
| `bbs-api.miyoushe.com/apihub/api/getShareConf` | GET | 分享（计数），`entity_id&entity_type=1` |
| `passport-api.mihoyo.com/account/ma-cn-session/app/getTokenBySToken` | POST | stoken 验证/换取 |
| `api-takumi.mihoyo.com/auth/api/getMultiTokenByLoginTicket` | GET | login_ticket → stoken(v1) |
| `api-takumi.mihoyo.com/binding/api/getUserGameRolesByCookie` | GET | cookie 活体验证 |
| `bbs-api.miyoushe.com/misc/api/createVerification?is_high=true` | GET | 极验 challenge（1034 时） |
| `bbs-api.miyoushe.com/misc/api/verifyVerification` | POST | 极验 verify |

### 2.2 DS 签名算法（Dart 实现在 `lib/services/mihoyobbs/ds_sign.dart`）

**DS1**（GET，Android salt K2）：

```
t = unix 秒
r = random.sample(ascii_lowercase+digits, 6)   # 不重复取样
c = md5("salt={K2}&t={t}&r={r}")
DS = "{t},{r},{c}"          K2 = 47f15f1b66bee46b816115d8e8e6ebb6
```

**DS2**（POST JSON，X6 salt）：

```
t = unix 秒
r = randint(100001, 200000)
c = md5("salt={X6}&t={t}&r={r}&b={body}&q={query}")
DS = "{t},{r},{c}"          X6 = t0qEgfub6cvueAPgR5m9aQWWVciEer7v
```

关键点：
- `b` = **与服务端收到的字节严格一致的 body 字符串**。Python 侧 `json.dumps({"gids": "1"})`
  产出 `{"gids": "1"}`（冒号后有空格），Dart `jsonEncode` 产出 `{"gids":"1"}`（无空格）。
  只要签名与实际发送的 body 一致即可，两种都能通过（服务端按收到的字节重算）。
- `q` = URL query 原文（`?` 之后），无 query 时空串。
- salt 与 `x-rpc-app_version` 对应（2.109.0）。**失效特征**：接口返回 retcode 与 DS
  相关的错误（如 -10001 附近），需抓新版本 App 更新 salt。

### 2.3 请求头（App 通道，等价 okhttp 客户端）

```
DS: <上述签名>
Cookie: stuid={stuid};stoken={stoken};mid={mid}     # v2 stoken 必须带 mid
x-rpc-client_type: 2            # 1=iOS 2=Android
x-rpc-app_version: 2.109.0
x-rpc-sys_version: 12
x-rpc-channel: miyousheluodi
x-rpc-device_id: uuid3(cookie)  # MD5 命名空间 UUID，Dart: UuidV3.fromString
x-rpc-device_name / x-rpc-device_model / x-rpc-device_fp
x-rpc-verify_key: bll8iq97cem8
x-rpc-csm_source: discussion
Referer: https://app.mihoyo.com
User-Agent: okhttp/4.9.3
Content-Type: application/json; charset=UTF-8
```

Web 通道（任务查询 getUserMissionsState 用 cookie 即可）：

```
Cookie: <完整网页 cookie>
x-rpc-client_type: 5
User-Agent: ...Mobile Safari/537.36 miHoYoBBS/2.109.0
Origin/Referer: https://webstatic.mihoyo.com
X-Requested-With: com.mihoyo.hyperion
```

### 2.4 登录态

| 类型 | 获取方式 | 有效期 | 能力 |
|------|---------|--------|------|
| stoken v2 (`v2_...`) | 抓包 App 请求（推荐）| 长期 | 全部 App 接口（签到/点赞/分享） |
| stoken v1 | login_ticket 兑换 | login_ticket 30 分钟 | 同上（需 stuid） |
| cookie_token | 网页抓包 | 较短 | 仅 web 通道（任务查询） |

retcode 速查：`0` 成功；`1034` 触发极验（需要过码，本项目跳过该帖/分区）；
`-100` 登录态过期。

### 2.5 防检测

- 全程随机 2~8s 间隔；看帖 3 次、点赞 5 次为任务上限，不要超出。
- 点赞后按配置取消（`cancel_like`），把对社区的影响降到最低（原项目同款策略）。
- device_id 用 uuid3(登录态) 保证稳定——同一登录态永远同一"设备"，避免频繁换设备触发风控。

---

## 3. WorkBuddy（原 CodeBuddy）

> 逆向来源：`workbuddy-checkin-main`（README / SKILL.md / checkin.sh / decrypt-token.js）

### 3.1 接口

| 接口 | 方法 | 说明 |
|------|------|------|
| `https://copilot.tencent.com/billing/meter/checkin-status` | POST | 查询状态，body `{}` |
| `https://copilot.tencent.com/billing/meter/daily-checkin` | POST | 签到，body `{}` |

鉴权：**只需** `Authorization: Bearer {accessToken}`，无签名、无时间戳、无设备指纹。

响应结构：

```jsonc
// 成功
{ "code": 0, "data": { "credit": 100, "streak_days": 5 } }   // 第 7 天 1000 分
// 已签到：HTTP 400 + code=10001（幂等拒绝，App 视为成功）
// token 失效：HTTP 401/403
```

注意：`checkin-status` 的 `data.today_checked_in` 在 v5.3.8 实测不可靠（签到成功后
仍可能为 false），只能做快速短路，幂等兜底必须靠 daily-checkin 的 10001。

### 3.2 本地登录态文件（token 结构）

**新版明文（WorkBuddy v5.3.8+，主路径）**：

| 平台 | 路径 |
|------|------|
| macOS | `~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` |
| Windows | `%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info`（APPDATA 为回退） |
| Linux | `~/.config/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` |

JSON 结构（脱敏示例）：

```jsonc
{
  "auth": { "accessToken": "eyJ...", "domain": "..." },
  "account": { "uid": 123456, "enterpriseId": "..." }
  // ...
}
```

**旧版（v5.3.8 之前）**：`{WorkBuddy,CodeBuddy}/User/globalStorage/state.vscdb`
（SQLite，key = `secret://{"extensionId":"tencent-cloud.coding-copilot","key":"planning-genie.new.accessTokencn"}`），
value 是 Electron `safeStorage` 加密的 Buffer，需要钥匙串授权解密。
**App 内不实现该分支**（需要在桌面端钥匙串授权），旧版用户请打开 WorkBuddy
刷新一次登录态让它迁移到明文文件。

### 3.3 macOS / Android 平台差异

- **macOS**：App 默认关闭沙盒（见 `macos/Runner/*.entitlements`），可直接读上述路径。
  首次使用点「从本机读取」即可；读到的 token 存入本机 SharedPreferences（`sec.wb.token`）。
- **Android**：不存在 WorkBuddy 桌面端，无本地文件可读。从桌面端复制 accessToken
  粘贴到「账号」页即可（token 等同账号密码，仅存本机）。

### 3.4 安全设计（与原项目对齐）

- token 只存本机 `sec.*` 命名空间；日志层有正则兜底，`Bearer/accessToken/stoken` 后跟
  内容一律打码。
- 仅访问 `copilot.tencent.com` 官方域名，无任何第三方上报。

---

## 4. 风险与合规

| 目标 | 风险 | 缓解 |
|------|------|------|
| Bing Rewards | 违反 ToS 可能被取消资格 | 随机延迟+滚动+词多样性；只用 WebView 真实环境；不刷超额次数 |
| 米游社 | 1034 验证码/风控 | 遇 1034 即跳过不硬闯；随机延迟；设备 id 固定 |
| WorkBuddy | 积分取消 | 幂等设计（10001 跳过），每天一次 |
| 通用 | 账号封禁 | 所有行为等价手动操作频率；**勿用于他人账号/批量账号** |

# API Reference — mihomo-widget

> 供开发者/Agent 快速定位，避免反复 grep 大文件。**行号可能漂移，以签名为准。**
> 维护约定：增删符号 / 改签名 / 加 conf 键 / 新端点时，`cd app && zig build docs-gen`（重写生成的
> 列、给新公开符号补行）+ `zig build docs-check`（校验，也是 `build_release.bat` 的前置闸门，
> 两者都是 `app\tools\docsgen.zig`，事实来自 `std.zig.Ast` 解析 `app/src`）。
> **§1 的「定位」列与 §3 的「类型/默认」列是生成的，别手改**（下次生成会覆盖）；
> 其余（说明/用途等散文）手写；被删符号的行由校验指名、人来删（生成器不删行，免得连散文一起丢）。

## 1. app/src 模块公共符号

### main.zig — 窗口 / worker / 绘制调度（约 1230 行；行号为 2026-09-14 复核值）
| 符号 | 定位 | 说明 |
| --- | --- | --- |
| `Config`（`struct`）+ `pub fn load(exe_dir)` | ~146–252 | 解析 `mihomo-widget.conf`；字段见 §3 |
| `g_cfg` / `g_state` / `g_ui` / `g_poll` / `g_poll_lock` / `g_meter` / `g_job` / `g_busy` / `g_quitting` / `g_worker_thread` / `g_job_ev` / `g_core_spawned` / `g_core_pid` | 全局单例 | 配置 / 运行状态 / UI 缓存 / 后台轮询槽 + 锁 / 网卡计量 / 任务盒 + 忙标志 / 退出标志 / worker 句柄 / 事件 / 核心启动+pid |
| `workerTun()` / `workerTunSet(want)` | ~523/537 | 切换 TUN / 强制目标状态；返回 `0=enabled,1=disabled,2=needs admin,3=failed` |
| `enqueueJob(kind)` | ~467 | 提交后台任务（`JobKind` 全集：`latency/tun/stop/update_core/update_geo/heal`）；已在跑则忽略 |
| `handleJobDone(kind, result)` | ~808 | 任务收尾：提示 / 关窗 |
| `flashMsg(text)` | ~339 | 底部短暂提示（5 个 tick） |
| `main()` | ~1315 | 入口：DPI → 定位 yaml → parse api_info → 建窗 → worker → 消息循环 |

#### main.zig 内部可改锚点（Agent 高频改动点）
> 只列**确切符号名** + 归属区域，行号近似、会漂移——改前用 grep 按符号名复核当前行。
> 用法：改"某个功能/菜单/任务"时，先在此查到符号名，再 grep 定位，避免整文件阅读。

| 区域 | 符号 / 值 | 说明 |
| --- | --- | --- |
| 菜单 ID 基址 | `MENU_BASE_ID=1` / `MAX_NODES=40` / `FUNC_BASE = MENU_BASE_ID + MAX_NODES` | 节点项 ID = `MENU_BASE_ID+i`；功能项 = `FUNC_BASE+n` |
| 功能菜单项 | `FUNC_SYSPROXY(0) / FUNC_TUN(1) / FUNC_TESTLAT(2) / FUNC_UPDATE_CORE(3) / FUNC_EXIT_STOP(4) / FUNC_AUTOSTART(5) / FUNC_UPDATE_GEO(6)` | `FUNC_BASE+n`，见 `menuForGroup` |
| 菜单构建 | `menuAdd()` / `nodeMenuTitle(buf, group)` / `menuForGroup(hwnd, at)` | 追加菜单项（宽字符，非 ASCII 返 `?`）/ 生成节点子菜单标题（`Nodes (<组名>)`，组名非 ASCII 时退回 `Nodes`）/ 构建 + `TrackPopupMenu` + 各功能分支。**菜单不依赖核心在线**：`core_up = online && nodes_n>0` 为假时只把依赖项置 `MF_DISABLED\|MF_GRAYED`（Test All Latency / TUN / Manual Update Core / Manual Update Geo）并省略节点子菜单，System Proxy / Auto Start / Network Interface / Exit & Stop Core 始终可用（Exit 是唯一退出入口，绝不能早退）。**节点列表在二级菜单 `nodes_sub` 里**（避免大节点池把功能项挤出屏幕），默认项也要对 `nodes_sub` 设；两个子菜单句柄都在函数作用域创建 + 由函数作用域的 `defer` 释放（`defer` 绑定块作用域，写进内层 `if` 会在 `TrackPopupMenu` 之前执行） |
| 后台任务枚举 | `JobKind` = `none\|latency\|tun\|stop\|update_core\|update_geo\|heal` | 新增后台任务需扩此枚举 |
| 任务盒（单槽） | `JobBox`（`kind` / `nodes` / `nodes_n` / `nodes_quic`） | `enqueueJob` 提交，worker 单槽消费 |
| 任务提交/回传 | `enqueueJob(kind)` / `WM_APP_DONE`（`0x8001`） | UI 线程提交；worker 用 `PostMessageW(WM_APP_DONE, kind, result)` 回传 |
| worker 分发 | `workerMain()` 内 `switch(kind)` | 分发到各 worker；新增任务须在此加分支 |
| 任务实现 | `workerLatency` / `workerTun` / `workerTunSet(want)` / `workerStop` / `workerTrigger(kind)` / `workerHeal(nodes, quic, nn)` | 每个后台任务一个函数，返回 `isize` 结果码。**`workerStop`：先 `setTun(false)` 并等它拆完（最多 2s）再 `taskkill`**——硬杀不走核心的清理路径，会留下死网卡 + 默认路由；杀完用 `GET /version` 校验，还答得上话＝没杀掉 → 返回 `3`，由 `handleJobDone` 记日志后照样关窗。`workerTrigger` 按 kind 分派 `upgradeCore`/`updateGeo`（此前是两份逐字克隆）。`workerTunSet` 会轮询校验真实状态，PATCH 静默不生效时自动补一轮 off→on 重建网卡；`workerLatency` 优先逐个 `/proxies/{name}/delay`，仅当配置里真有 provider 时才回退读 health-check。`workerHeal` 见下表 |
| 任务收尾 | `handleJobDone(kind, result)` | flashMsg / `saveConfState`（只写 sysproxy 与 nic_ifindex）/ 关窗 |
| 调度/工具 | `clientFor(arena)` / `flashMsg(text)` / `readTunLive()`（`TunLive{enable, has_device}`）/ `tunEffectivelyOn()` / `waitTun(want, budget_ms)` | 构造 client / 底部提示 / 读 live `tun`（开关 + 网卡是否建好）/ TUN 是否真可用（菜单标题与切换判断都用它）/ 轮询等目标状态。TUN 入口一律走 `enqueueJob(.tun)` |
| 日志/内存 | `logWrite(fmt, args)` / `memStat()`（`MemStat{ws, priv}`） | 写 `mihomo-widget.log` / 进程内存（psapi；`ws`=working_set，`priv`=pagefile_usage=私有提交） |
| 置顶守护 | `isTopmostWindow(hwnd)` / `reassertTopmost(hwnd, reason, cover)` / `topmostGuard(hwnd)` | Windows 在解锁 / 显示变更 / DWM 重建 Z-order 后会把窗口挤出 topmost 带；按 `topmost_guard_ms` 巡检并用 `SetWindowPos(HWND_TOPMOST, SWP_NOACTIVATE)` 静默修回 + 记日志。`wndproc` 的 `WM_DISPLAYCHANGE` 立即修一次 |
| 全屏自动隐藏 | `fgFullscreen()` / `g_fullscreen_demoted` / `g_menu_open` / conf `autohide_fullscreen` | `POLL_TIMER` 里判前台窗口矩形是否覆盖整个主屏（`GetForegroundWindow` + `GetWindowRect` + `GetSystemMetrics`，8px 容差，最小化与 shell 桌面窗口不算；**不要改用 shell 的用户通知状态 API**，见 §5）→ 覆盖则降到普通带（`HWND_NOTOPMOST`，不隐藏）+ 停 topmostGuard；退出全屏升回 `HWND_TOPMOST`。`g_menu_open`（`menuForGroup` 置位）期间不降级，防止菜单中途窗口层级变动 |
| 网速文本 | `fmtRate(buf, bytes_per_s, auto)` | 单位换算 + 换挡（规则见 §3 `speed_unit_auto`） |
| QUIC 自环自愈 | `workerHeal(nodes, quic, nn)` / `nodeIsQuic(quic_names, name)` / `g_heal_armed_at` / `g_heal_tun_prev` / `HEAL_DELAY_MS` / `HEAL_PROBE_MS` / `nodes_quic` / `tun_on` | TUN 每次"就位"（off→on，或核心刚起来就带 TUN）后布防、`HEAL_DELAY_MS` 到点探一次：QUIC 类节点（`/proxies` 的 `type`，见 `isQuicType`）有探不通、而 TCP 类至少一个通 = 自环 → `PUT /configs {}` 就地重载（重建 outbound → 重拨）+ 复查 + 按需重选节点。**前置条件**：核心那份配置的 `tun.enable` 必须已等于实时状态（`proc.patchTunEnable` 比对，不一致就跳过），否则重载会按文件把隧道刷掉；事后仍 `waitTun` 复查、丢了就 `workerTunSet` 补回。每次 TUN 就位只做一次 |

### ui_draw.zig — GDI 绘制
| 符号 | 定位 | 说明 |
| --- | --- | --- |
| `DrawFonts` / `DrawCtx`（`struct`） | ~9/15 | 字体集 / 绘制上下文（scale / win_w / bg / fonts） |
| `scaled(v, scale)` | ~24 | 逻辑 px → 物理 px（`round(v*scale)`）；`main.zig` 的 `scal()` 委托到这里，布局与绘制不会各算一份 |
| `fill_rect(hdc, x, y, w, h, brush)` | ~28 | 填充矩形 |
| `text_at(hdc, x, y, s, color, ctx)` | ~69 | 绘制文本（ASCII→宽字符） |
| `drawSpeedAt(hdc, x0, y0, up, dn, color, ctx)` | ~122 | 网速列：箭头 + Segoe 数字；单位随 `speed_unit_auto`（1→KB/MB/GB，0→固定 `MB/s`）。文本由 `main.zig` 的 `fmtRate()`（~300）生成 |

### proc.zig — 文件 / 路径 / 子进程 / 核心启动
| 符号 | 定位 | 说明 |
| --- | --- | --- |
| `readFileBytes(heap, path, max)` | ~19 | ASCII 路径读文件（heap 分配） |
| `writeFileBytes(path, data)` | ~45 | 写文件（替换） |
| `confPath(exe_dir, out)` | ~173 | conf 路径：优先 `{exe_dir}\..\cfg`（dev 在 app/cfg），回退 exe 同级（release） |
| `saveWindowPos(hwnd, exe_dir)` | ~184 | 存 `window_x/y`（读-改-写；遇到注释掉的键 `#window_x=..` 会去掉 `#` 就地更新，其余行保留） |
| `saveConfState(exe_dir, sysproxy, nic_ifindex)` | ~254 | 存 `sysproxy`/`nic_ifindex` 键（读-改-写；注释掉的键同样去 `#` 就地更新，避免重复行）。**不写 TUN**——TUN 的开机状态只有 `config.yaml` 的 `tun.enable` 一个来源 |
| `normalizePath(dst, src)` | ~320 | 消除 `.` / `..` 段。必项：mihomo(Go) 不归一化 `-d/-f` 里的 `..`，且找不到配置时会**静默写一份默认配置**跑在 7890（表现为“controller unreachable”） |
| `findYaml(exe_dir, out)` | ~361 | 找主配置：候选目录 × `config.yaml` → `mihomo_client.yaml`（旧布局兼容），命中后**归一化**返回绝对路径。顺序：`..\..\cfg`（dev）→ `mihomo\`（发布新布局，排在平铺之前：半迁移时它的目录才放着 `direct.yaml`/geodata）→ exe 同级（旧平铺）→ `..` / `..\..` / `mihomo-widget` |
| `dirOf(path)` | ~392 | 取路径的目录部分（给核心定 `-d` 用） |
| `pathExists(p)` | ~397 | 判断文件存在 |
| `asciiToWide(ascii, buf)` | ~404 | ASCII → UTF-16 |
| `spawnCmd(core_pid, app, cmd, log)` | ~415 | 启动进程（`CREATE_NO_WINDOW`） |
| `spawnCoreIfNeeded(exe_dir, yaml, spawned, pid)` | ~498 | 惰性启动 mihomo：核心查找顺序 = 仓库上溯 3 级的 `.tools\mihomo\mihomo.exe`（dev）→ `<exe_dir>\mihomo\mihomo.exe`（发布）→ `<exe_dir>\mihomo.exe`（旧平铺）；`-f <主配置>`（就是 `findYaml` 命中的那份，控件不改写它），**`-d` = 主配置所在目录**（`direct.yaml` / geodata / 核心自己写的运行文件都跟 `config.yaml` 同目录；指错目录时 mihomo 只在启动日志里记一条 provider 报错，规则集静默失效） |
| `pathUp(p0, levels)` | ~556 | 目录上溯 N 级 |
| `patchTunEnable(src, want, out)` | ~81 | 把顶层 `tun:` 块的 `enable` 标量强制成 `want`：已有键就原地换值（缩进 / 行尾注释 / CRLF 都保留，`enable :` 这种带空格的也认），缺键就在 `tun:` 行后插一行（用块内缩进）。没有 `tun:` 块、`tun:` 写成 flow map、或值本身是 flow 集合 → `null`（宁可退回用户那份配置，也不臆造 tun 段）。返回写进 `out` 的长度；无变化时与 `src` 逐字节相同（自愈据此确认核心那份配置的 `tun.enable` 已等于实时状态） |
| `spawnWaitHidden(app_ascii, cmd_ascii, exit_code)` | ~462 | 启动隐藏控制台子进程并等它退出（2s 上限，超时不杀），把退出码写进 `exit_code`；`CreateProcessW` 失败 / 超时 / 等待失败返回 `false`。目前只供 schtasks 自启用。`app_ascii` 是裸 exe 名时自动加 **System32 绝对路径**——`CreateProcessW` 的应用名参数不走搜索路径，裸名只按 CWD 解析（双击启动时 CWD = exe 目录 → 找不到，表现为 `Auto start failed`） |

### system_win.zig — 注册表（系统代理）+ 计划任务（自启，无需 controller）
| 符号 | 定位 | 说明 |
| --- | --- | --- |
| `sysProxyEnabled()` | ~17 | 读 `ProxyEnable` |
| `setSysProxy(mixed_port, on)` | ~35 | 写 `ProxyEnable`/`ProxyServer` + `InternetSetOptionW` 刷新 |
| `autoStartEnabled()` | ~67 | `schtasks /query` 查 `mihomo-widget-autostart` 任务（退出码 0 = 存在）；spawn 失败按不存在算 |
| `setAutoStart(self_abs, on)` | ~72 | 开 = `schtasks /create /SC ONLOGON /RL HIGHEST /F`（`/TR` 为带引号的 exe 绝对路径，非 ASCII 折成 `?`）；关 = 任务不存在即幂等成功，存在才 `/delete /F`。用计划任务是因为提权 exe 挂 HKCU `Run` 键时登录启动会被静默跳过 |
| `removeLegacyRunEntry` | ~101 | 一次性删旧 `Run` 键条目 `mihomo-widget`（迁移清理，错误忽略）；main 启动时调用 |
| `isAdmin` | ~116 | `IsUserAnAdmin`；菜单自启项据此决定是操作还是提示需要管理员 |

### config.zig — mihomo yaml 轻解析
| 符号 | 定位 | 说明 |
| --- | --- | --- |
| `ApiInfo`（`struct`） | ~5 | `host / port / secret / mixed_port` |
| `parseMihomoYaml(arena, text)` | ~15 | 解析 `external-controller` / `secret` / `mixed-port` |

### mihomo.zig — mihomo controller 客户端
| 符号 | 定位 | 说明 |
| --- | --- | --- |
| `ProxyKind` / `Group` / `Snapshot` / `isQuicType(t)` | ~7/19/26/36 | 类型（isGroup / 组 / 快照 `{groups, nodes, quic_nodes}`）/ 判断代理类型是否长驻 QUIC 出站（`Hysteria2` / `Hysteria` / `Tuic`；自环自愈的判据用它把节点分成"会被建 TUN 绑错地址"与"不受影响"两类，见 AGENTS.md） |
| `Client.init(arena, host, port, secret)` | ~40/46 | 构造 |
| `version / snapshot / groupDetail / select / delayOf / setTun / configsRaw / proxyProviders / providerLatency / reloadConfig / reloadConfigInPlace / upgradeCore / updateGeo / shutdown` | ~61–231 | 见 §2 |

### httpw.zig — WinHTTP 封装
| 符号 | 定位 | 说明 |
| --- | --- | --- |
| `Result` | ~8 | `{ status, body }` |
| `request(arena, host, port, method, object, extra_header, body, timeout_ms)` | ~32 | WinHTTP 请求；`timeout_ms` 施加到 resolve/connect/send/receive（轮询 2000，升级 120000） |
| `toWideZ(arena, s)` | ~17 | ASCII → `[:0]u16`（逐字节扩宽 + 补齐 NUL；>0x7f 直接报错 `NonAscii`） |

### traffic.zig — 整机网卡字节计量（zigwin32 `GetIfTable2`）
| 符号 | 定位 | 说明 |
| --- | --- | --- |
| `Rate { up, down }` | ~7 | 距上次采样的字节增量 |
| `Meter.tick()` | ~92/102 | 按 `Meter.sel` 统计：`sel=0`→汇总全部**物理**网卡；否则只统计该接口增量（`isCandidate` 排除回环 / TUN / 无 MAC 虚拟口 / NDIS filter 镜像） |
| `Nic { ifindex, name }` / `listNics(cands)` / `isCandidate(r)` | ~14/74/65 | 网卡选择：候选网卡枚举（供菜单）与判断（type+MAC+非 filter/virtual） |
| `slice` | ~19 | 取网卡名（菜单显示用） |

### dev_probe.zig
| 符号 | 定位 | 说明 |
| --- | --- | --- |
| `main()` | ~6 | 调试探针 |

## 2. mihomo controller REST 端点（widget 使用）
> base = `http://{host}:{port}`；secret → header `Authorization: Bearer <secret>`；WinHTTP 常规请求超时 2s（`/upgrade*` 长超时 120s）。
| Client 方法 | Method | Path | 用途 |
| --- | --- | --- | --- |
| `version` | GET | `/version` | 版本字符串（判 online） |
| `snapshot` | GET | `/proxies` | 分组 + 节点 |
| `groupDetail` | GET | `/proxies/{name}` | 组 `now` / `all` |
| `select` | PUT | `/proxies/{group}` | 选节点（body `{"name":node}`） |
| `proxyProviders` | GET | `/providers/proxies` | 列出真实 provider 名字（排除 mihomo 由分组合成的 `vehicleType=Compatible` 伪项）。本项目用静态 `proxies:`，通常返回空。provider 级 `PUT /providers/proxies/{name}` 只重读文件（本项目不用，节点是静态声明）；批量 `PUT /providers/proxies`（无名字）不存在（405） |
| `providerLatency` | GET | `/providers/proxies/{name}` | 取池内每个节点最近一次 health-check 结果（`proxies[].history[-1].delay`，0=不可达）→ `Client.ProvLat{name,ms}`（仅在配置真用了 provider 时才作为兜底数据源） |
| `delayOf` | GET | `/proxies/{name}/delay?url=..&timeout=..` | 单节点测延迟 |
| `setTun` | PATCH | `/configs` | 开/关 TUN（body `{"tun":{"enable":x}}`） |
| `reloadConfig` | PUT | `/configs` | body `{"path":"<绝对路径，反斜杠要转义成 \\\\>"}` 重载指定文件。**没有调用者**（自愈走下面那个）：实测会把运行时状态按文件重置（TUN 开着时按文件里 `tun.enable` 的值走，false 就掉隧道）。保留作警示；`path` 受 home / `SAFE_PATHS` 校验，越界返 400（错误体回显 allowed paths，可反推核心真正的 `-d`） |
| `reloadConfigInPlace` | PUT | `/configs` | body `{}`（**空对象必须有**，空 body 会被 `DecodeJSON` 判 400）→ 核心按**自己启动时那份配置**（`C.Path.Config()`）重载。唯一调用者 = `workerHeal` 的自环自愈：`ApplyConfig` 重建全部 outbound（hysteria2 丢掉坏 QUIC 连接、重拨），而 `ReCreateTun` 在文件 `tun` conf 与 `LastTunConf` 相等时只调 `OnReload()`（重设 routing mark / interface finder，**不碰网卡与路由**）——所以自愈不炸隧道的前提就是那份文件的 `tun.enable` 已等于实时状态（调用方先比对，见 §1 自愈行） |
| `configsRaw` | GET | `/configs` | 读 live `tun.enable` / `mode` / `mixed-port` |
| `upgradeCore` | POST | `/upgrade` | 升级 mihomo 自身二进制并重启（120s 超时） |
| `updateGeo` | POST | `/upgrade/geo` | 下载最新 GeoIP/GeoSite/ASN/MMDB（120s 超时） |
| `shutdown` | GET | `/shutdown` | 请求核心优雅退出（best effort） |

## 3. mihomo-widget.conf 键
| 键 | 类型 | 默认 | 用途 |
| --- | --- | --- | --- |
| `font_face` | ASCII | Microsoft YaHei UI | 字体 |
| `font_size` | u8 | 15 | 逻辑字号 |
| `alpha` | u8 | 200 | 窗口不透明度 |
| `width` / `width_hover` | i32 | 220 | 收起 / 展开宽（默认相同 → 悬停只变高不变宽；`width_hover` 会被 `@max(width, width_hover)` 兜住，不会比收起态窄） |
| `height` / `height_hover` | i32 | 26 / 76 | 收起 / 展开高 |
| `speed_top` | i32 | 3 | 网速行 top offset（收起与悬停**共用一个值**；旧的 `speed_top_hover` 键已删，留着的行会被忽略） |
| `speed_refresh_ms` | u32 | 1000 | 网速采样/刷新间隔（ms，100–3000）；也是流量归一化基准 |
| `speed_unit_auto` | 0/1 | 1 | 网速单位：1=按量级自动选 KB/MB/GB（换挡点=显示值满 1000，故整数部分最多 4 位：`999.9 KB/s` / `999.9 MB/s`，避免 `1000.5 KB/s` 这种超宽串），0=固定 `MB/s` |
| `nic_ifindex` | u32 | 0 | 统计哪张网卡（interface index，来自菜单选择）；0=自动汇总所有物理网卡 |
| `topmost_guard_ms` | u32 | 5000 | 置顶巡检间隔（ms，1000–60000）；0=关闭。修回被 Windows 挤出 topmost 带的窗口（解锁 / 分辨率变更 / DWM 重建） |
| `window_x` / `window_y` | i32 | — | 上次窗口位置（physical px） |
| `color_bg` / `color_speed` / `color_text` / `color_dim` / `color_warn` | hex | 见 `Config` | 配色 |
| `sysproxy` | 0/1 | 0 | 上次系统代理状态 |
| `autohide_fullscreen` | 0/1 | 1 | 前台窗口矩形覆盖整个主屏（全屏游戏 / 演示）时控件自动降到普通窗口层级（不隐藏，被全屏窗口盖住），退出全屏静默升回 topmost；0=关闭。解决常驻 layered 窗口干扰全屏 DWM 合成导致的游戏卡顿（检测细节与已否决方案见 §5） |

> **没有 `tun` 键**（2026-09-18 起，别再找）：TUN 的开机状态只有一个来源——`config.yaml` 的
> `tun.enable`，核心启动时自己读（那条路径天然安全，见 AGENTS.md 关键决策）。菜单里的
> `TUN Mode` 只作用于本次运行（`PATCH /configs`），既不落盘也不在下次启动被恢复；由此产生的
> "运行中建网卡"自环由 `workerHeal` 自愈兜住。旧 conf 里残留的 `tun = …` 行会被忽略。

## 4. win32.zig extern 分组（手写互操作层，不依赖 zigwin32）
> 共 **77** 个 extern（`grep -c '^pub extern' app/src/win32.zig` 复查）：`user32` 34 / `kernel32` 21 / `gdi32` 15 / `advapi32` 5 / `wininet` 1 / `psapi` 1。完整名单直接 grep，别照抄下表。
| DLL | 主要函数 |
| --- | --- |
| `user32` | 窗口/消息/菜单：`RegisterClassExW / TrackMouseEvent / CreateWindowExW / SetWindowPos / ShowWindow / SetLayeredWindowAttributes / BeginPaint / EndPaint / InvalidateRect / SetTimer / GetMessageW / TranslateMessage / DispatchMessageW / DefWindowProcW / SendMessageW / PostMessageW / PostQuitMessage / DestroyWindow / CreatePopupMenu / AppendMenuW / DestroyMenu / TrackPopupMenu / SetMenuDefaultItem / CheckMenuItem / GetCursorPos / GetWindowRect / ClientToScreen / WindowFromPoint / GetWindowLongPtrW / SetForegroundWindow / LoadCursorW / ReleaseCapture / GetDpiForSystem / SetProcessDpiAwarenessContext` |
| `gdi32` | 绘制：`CreateCompatibleDC / CreateCompatibleBitmap / SelectObject / DeleteObject / DeleteDC / BitBlt / CreateSolidBrush / FillRect / CreateFontW / TextOutW / SetBkColor / GetTextExtentPoint32W / GetTextMetricsW / SetBkMode / SetTextColor` |
| `kernel32` | 文件/进程/同步：`CreateFileW / ReadFile / WriteFile / CloseHandle / GetFileSizeEx / GetModuleFileNameW / CreateProcessW / OpenProcess / TerminateProcess / GetExitCodeProcess / Sleep / CreateEventW / SetEvent / ResetEvent / WaitForSingleObject / AcquireSRWLockExclusive / ReleaseSRWLockExclusive / GetModuleHandleW / GetTickCount64 / GetLastError / GetCurrentProcess` |
| `advapi32` | 注册表：`RegOpenKeyExW / RegQueryValueExW / RegSetValueExW / RegDeleteValueW / RegCloseKey` |
| `wininet` | `InternetSetOptionW` |
| `psapi` | `GetProcessMemoryInfo`（内存诊断日志） |
> 类型别名：`HWND/HDC/LRESULT/LPARAM = isize`、`WPARAM = usize`、`BOOL = i32`、`HINSTANCE/HBRUSH/HBITMAP/HFONT/HMENU = ?*anyopaque`、`SIZE_T`、`WNDPROC`；
> `extern struct`：`RECT/POINT/PAINTSTRUCT/MSG/WNDCLASSEXW/STARTUPINFOW/PROCESS_INFORMATION/PROCESS_MEMORY_COUNTERS/TRACKMOUSEEVENT/SRWLOCK/TEXTMETRICW/EXTENT`。

## 5. 备注
> 本文只放**符号 / 端点 / conf 键 / API 层语义**；项目决策与踩坑（含实测数据）统一写在根 `AGENTS.md` 的「已确立的关键决策」与「验证流程」，此处只留一句指针，不再重复。
- **`main.zig` 是单例汇聚**（`g_cfg/g_state/g_ui/g_poll` 全局），内部函数不对外，§1 只列关键调度符号。
- **WinHTTP 超时**：`httpw.request` 的 `timeout_ms` 作用于 resolve/connect/send/receive——常规请求/轮询 2s（controller 未就绪时快速返回，防 UI 挂起），`/upgrade`、`/upgrade/geo` 120s（下载二进制 / geo）。
- **运行时配置位置**：`app/cfg` = `config.yaml`（单文件主配置，`proxies:` 段在末尾）+ `mihomo-widget.conf`（控件偏好）+ `direct.yaml` + geodata。开发版 exe 在 `app\zig-out\bin`，向上两级找 `..\..\cfg`（`..\cfg` 会错指到 `app\zig-out\cfg`）；发布包配置与 exe 同目录（`confPath` / `findYaml` 两种布局都兼容）。找不到 `config.yaml` 时回退旧名 `mihomo_client.yaml`。
- **provider / rule-provider 的相对 `path` 以核心 home（`-d`）为基准**，不是以配置文件为基准（放错位置时组内成员为 0）；跳出 home 报 `path is not subpath of home directory or SAFE_PATHS`（可用 `SAFE_PATHS` 放行，本项目靠把 `-d` 对齐配置目录规避）。**推论：改 `direct.yaml` 要改核心真正读的那份**——跑着的实例是本机那个部署目录，不是仓库 `app\cfg`。
- **`PUT /providers/rules/{name}` 可热更新规则内容**（不重启核心、不掉 TUN）。⚠ **不要用 `GET /providers/rules` 的 `ruleCount` 判断是否生效**：2026-09-14 实测文件已 46→45 条、行为已变，该计数（以及 `updatedAt`）仍显示旧值；要看**实际命中哪条规则**（见 AGENTS.md 验证流程）。provider 级 `PUT /providers/proxies/{name}` 同样只重读文件、**不重跑测速**（`updatedAt` 变但各节点 `history` 时间戳不动）；批量 `PUT /providers/proxies`（无名字）不存在（405）。
- ⚠ **`PUT /configs` 只有一个合法调用者：`workerHeal` 的自环自愈**。实测（admin 发布包）：重载会按文件重置运行时状态——TUN 开着（`tun.enable=True`、device `Meta`）时，若文件里是 `false`，一发就变 `False`、隧道掉线，且事后单次 `PATCH {"tun":{"enable":true}}` 返 204 但 `device` 仍为空、开不回来，必须先 false→true 走一轮。所以自愈在发之前**必须**确认那份文件的 `tun.enable` 已等于实时状态（用 `proc.patchTunEnable` 比对原文，不一致就放弃自愈），并在事后 `waitTun` 复查、丢了就 `workerTunSet` 补回。其余任何地方改 TUN 一律 `PATCH /configs`（`workerTunSet` 会校验 `enable` + `device`）。`path` 也受 home / `SAFE_PATHS` 校验，越界返 400（错误体回显 allowed paths，可反推核心真正的 `-d`）。
- **`mihomo -t` 不校验 provider**：provider 文件缺失 / 内容非法时 `-t` 仍报 successful（运行时才打 `initial ... provider error`，白名单规则会静默丢失，甚至变成“零节点”），所以改完配置要实际拉起核心查 `GET /proxies/{group}` + `GET /providers/proxies`。
- **`Test All Latency` 的可行路径**：① 静态节点逐个 `GET /proxies/{name}/delay?url=..&timeout=1200`（本项目在用：即时、精确，超时/不通返 504/503）；② provider 节点只能读 `GET /providers/proxies/{name}` 的 `proxies[].history[-1].delay`（0=不可达，新鲜度受 interval 限制）；③ 借分组即时测会真的切出口，未采用。一轮 9 节点全量测速约 2-3s。
- **节点必须静态 `proxies:` 声明，别用 `proxy-providers`**（provider 成员不注册进控制器，逐节点即时测速失效）——实测数据见 AGENTS.md 关键决策。**节点/组名只能用 ASCII 且不含空格/竖线/emoji**：`groupDetail` / `delayOf` / `proxyProviders` 把名字原样拼进 REST 路径且未做 percent-encode（否则面板拿不到 `now`、延迟测试报错）；单池 ≤ 40（`MAX_NODES`）。provider 侧遗留实测（万一以后要用）：`type: file` + `format: yaml` 可用（anchors / `<<:` 合并键正常），组里 `use: [provider]` 能展开成员，顶层必须保留 `proxies:`；`!include` / `!ref` / `!path` 在 v1.19.30 不存在（`-t` 直接报错）。
- **诊断日志**：`mihomo-widget.log`（exe 同级，保留最近约 1MB）：boot（conf 关键值 + 基线内存）/ 每 10s poll 摘要（`mem=<工作集>/<私有提交>MB`，psapi `GetProcessMemoryInfo`）/ poll 失败 / 后台任务 start-done / 窗口销毁。`logWrite()`（main.zig）线程安全。
- **`main()` 解析主配置的 arena 必须活过 `g_state` 拷贝**：`config.parseMihomoYaml` 返回的 `host` / `secret` 是 arena 切片，曾把 `arena.deinit()` 放内层 `if`（出块即释放）→ 拷贝时读已 unmap 的页，**启动直接 `0xC0000005`**（窗口都建不出来）。触发条件挑：`external-controller` 写**具体主机**（非 `0.0.0.0` 通配）或 `secret` **非空**（只有这两种才指向 arena 里的字符串）。
- **网卡计量（`traffic.zig`）用 zigwin32**（`win32.iphlpapi` / `network_management.ip_helper`），**不是**项目 `win32.zig`：`isRealNic` 排除回环 / TUN / 无 MAC 虚拟口，`isCandidate` 再排除 NDIS filter 镜像与虚拟适配器（否则同一物理网卡的 filter 绑定会让计数翻倍）。**`GetIfTable2` 返回的表必须 `FreeMibTable`**（漏释放每秒泄漏一份，长跑涨到 GB 级并拖垮 GUI）。网卡可在右键菜单 "Network Interface" 子菜单手动选择，接口索引存 `nic_ifindex`。
- **置顶（topmost）语义**：建窗一次性给 `WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW`，代码里**从不**清该样式位（`applyHover` 的 `SetWindowPos` 带 `SWP_NOZORDER`，`hwndInsertAfter` 被忽略；全屏"让位"的 `HWND_NOTOPMOST` 是唯一例外，见下一条）；Windows 在解锁 / 显示模式变更 / DWM 重建 Z-order / 另一个 topmost 程序退出后会把它摆到普通窗口之下，由 `topmostGuard` 巡检静默修回（`SWP_NOACTIVATE`，不抢焦点；命中 topmost 窗口则不争）。间隔 = conf `topmost_guard_ms`（0=关闭；全屏让位期间巡检暂停，恢复后才继续）。
- **全屏自动隐藏（`autohide_fullscreen`，默认开；实为"让位"）**：前台窗口矩形覆盖整个主屏（四边盖过屏幕边缘，8px 容差；`GetForegroundWindow` + `GetWindowRect` + `GetSystemMetrics`，最小化不算、shell 桌面窗口 `Progman`/`WorkerW` 不算）时，`POLL_TIMER` 里**每 tick** 把窗口压到 Z 序最底（`HWND_BOTTOM`）并清 topmost 位（`HWND_NOTOPMOST`，**不隐藏**）、停 `topmostGuard`（否则 guard 会修回去）——游戏必然盖住控件，DWM 把它当被遮挡窗口处理，不再干扰合成路径（实测表现为全屏游戏卡顿）；每 tick 压底是因为游戏切场景/重建窗口时会插到控件前面，一次性的降级挡不住。退出全屏 `HWND_TOPMOST` 静默升回（不抢焦点）。悬停检测与重绘照常跑（被盖住时是廉价 no-op）。菜单打开期间（`g_menu_open`）不让位。菜单 "Yield to Fullscreen" 开关只作用于本次运行，不落盘。⚠ **已否决方案别再捡回来**：① shell 的用户通知状态 API（`SHQuery…NotificationState`）——实测（2026-09-30，4K/250%）zen 浏览器仅最大化（rect 3872x2072，高比屏幕小 120px）就让 shell 持续返回"全屏中"；② `SW_HIDE` 硬藏——点桌面时前台是 shell 桌面窗口本身（矩形铺满整屏），控件跟着消失；③ **只降级一次不清 Z 序**——实测控件降到普通带后仍悬在游戏之上（Z 序相对位置没变），且全屏分支跳过 `hoverCheck`/`InvalidateRect` 导致悬停展开后冻结、网速停更；必须每 tick 压底 + 分支内继续跑 UI 维护。Chrome 系最大化 rect（四边各超 16px 但高度差 120px）不会误判；真 F11 全屏（rect 覆盖整屏）会命中。
- **自签证书 pinning、IPv6 路由策略、节点 / provider 的历史结论与实测**：见根 `AGENTS.md`「已确立的关键决策」，本文不再重复。
- **校验器只认真实标识符**（标识符 token 与字符串字面量里的词，如 conf 键 / 注册表值名）：注释里提到某个名字不算「存在」；噪声词（参数名、关键字、散文里的文件名）集中在 `app\tools\docsgen.zig` 的 `STOP` 数组。

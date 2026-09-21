# Changelog

> mihomo-widget — Zig + Win32 轻量 mihomo 悬浮代理控件。
> 每个版本只写用户可感知的变更，内部重构简略带过。

## v0.2.7 (2026-09-18)
- **面板默认宽度 210 → 220**（`width` 的默认值；`width_hover` 仍是 220，所以默认状态下**悬停只变高、不变宽**）。conf 文件里没写 `width` 的话，收起态直接就和你平时看到的宽度一致了；显式写过 `width = 210` 的实例不受影响。
- **删掉 `speed_top_hover` 键**：网速行上边距收起/悬停**共用一个 `speed_top`**（模板里那行也删了）。旧 conf 里残留的 `speed_top_hover = …` 会被直接忽略——它本来也是同一个值（3），所以视觉上没有任何变化。

## v0.2.6 (2026-09-18)
- **TUN 只剩一个开关：`config.yaml` 里的 `tun.enable`**。控件不再记 TUN 偏好——`mihomo-widget.conf` 的 `tun` / `tun_start_delay_ms` 两个键**已删除**（旧文件里残留的行会被忽略），v0.2.4 那套"按 conf 派生出 `mihomo-widget.runtime.yaml` 喂给核心"的做法连同派生副本一起删除：安装目录不再多一个文件，也不再有"conf 与 yaml 两份真相"。控件启动时**一个 TUN 请求都不发**，核心自己读配置建网卡（`updateTun` 早于它自己的首拨/组测速，那条路天然安全）——于是"开机卡壳"这条路径彻底消失，只剩**运行中切换**（菜单 `TUN Mode`、或脚本 PATCH）可能卡住 hy，而那正好是 v0.2.5 自愈覆盖的场景。
  - 行为变化：菜单里的 `TUN Mode` **只作用于本次运行**，重启控件/核心后仍以 `config.yaml` 为准。想让 TUN 开机就开，就把 `tun.enable` 写成 `true`（这是唯一的开关；`config.yaml.example` 的说明已按新语义重写）。`Exit & Stop Core` 依旧先关 TUN 再杀核心（避免留下死网卡与默认路由），所以下次启动＝重新按配置建网卡。
  - 边角情况说清楚：若核心是**别处启动**的、而它的实时 TUN 状态与 `tun.enable` 不一致（例如上次控件退出时把它关了），控件**不会**再"替你恢复"——菜单里点一下即可，那一次运行中切换由自愈看着。
  - 内部：删掉 `deriveRuntimeCfg` / `RUNTIME_CFG_NAME` / `tun_on` job / `g_tun_restored` / `g_tun_wait_since`；`saveConfState` 只管 `sysproxy` / `nic_ifindex`（不再写 tun）；`proc.patchTunEnable` 保留——自愈用它校验"核心那份配置的 `tun.enable` 已等于实时状态"。

## v0.2.5 (2026-09-18)
- **新增「QUIC 自环」自动自愈：hy 节点被"建 TUN 那一瞬"卡住时，控件几秒内自己救回来**。v0.2.4 让 TUN 在核心启动阶段就位之后，主路径不再产生自环，但**菜单里手动开 TUN**（热流量下 off→on）、配置里没有顶层 `tun:` 段只能走 PATCH、派生配置写失败这几条路仍会中招：建网卡的那一瞬间把正在建立的 hysteria2（QUIC/UDP）连接绑到 TUN 地址上 → 自环 → 该节点要等 QUIC 超时重拨（~70–90s）才恢复。现在后台 worker 会在 **TUN 每次"就位"**（off→on，或核心刚起来就带 TUN）后 10s 探一次，**判据**是"有 QUIC 类节点（`type` 为 Hysteria2 / Hysteria / Tuic）探不通、而 TCP 类节点至少一个通"——用 TCP 类做对照，才不会把"节点/网络整体挂了"误判成自环；**命中就发一次 `PUT /configs {}` 就地重载**（`ApplyConfig` 重建全部 outbound → hy 丢掉坏 QUIC 连接，下次用时重拨），把等待从 ~70–90s 压到十几秒，面板提示 `QUIC reset (TUN self-loop)`，日志里是 `heal: self-loop (quic dead=…, tcp alive=…) -> reload cfg in place` 与随后的 `heal: quic nodes back N/M after reload`。
  - **每次 TUN 就位只做一次**，不会周期性打断连接；节点健康时**绝不动作**（日志只留一条 `heal: no self-loop signature (quic dead=0 alive=…, tcp alive=…)`）。
  - 代价说清楚：这次重载会断开所有连接约 1–2 秒，比坐等 ~1 分钟划算，但确实是自愈本身的价格。
  - 安全性：重载只在**核心那份配置的 `tun.enable` 已等于实时状态**时才发（否则会按文件把隧道刷掉——这正是 v0.2.0 里"控件绝不发 `PUT /configs`"那条禁令的来历，现在它只对自愈这一个调用者开口）；发完还会复查 TUN，万一被刷掉立刻补回来，必要时把用户当前选中的节点重新选回去。
  - 内部：`/proxies` 快照多解一份 `quic_nodes`（按代理 `type` 分类），轮询顺带带回实时 TUN 状态，自愈布防不再需要 UI 线程另发一次 `/configs`。

## v0.2.4 (2026-09-18)
- **TUN 的开机状态改回"控件派生运行时配置"**（v0.2.3 那次改的延迟 PATCH 就此降级为兜底）：控件按 `mihomo-widget.conf` 的 `tun` 偏好，把你那份 `config.yaml` 的 `tun.enable` **强制成对应值**、在**同目录**派生一份 `mihomo-widget.runtime.yaml` 交给核心（只改这一个标量，其余字节原样复制，**你的 config.yaml 绝不写入**）。于是 TUN 在核心启动阶段就建好（`updateTun` 早于 `OnRunning()` 的首拨/组测速），从结构上避开"运行中建网卡会把正在建立的 hysteria2 连接卡死约 1 分钟"那个窗口；**两个方向都管**——`tun = 0` 就派生出 `false`，核心干脆不带 TUN 起，不再有"关掉又打开"的空窗（那正是"关一下控件再开，hy 全部不可达"的成因）。
  - 只在派生结果与你文件不同时才落地这个文件：**你已经手写 `enable: true` 时根本不会生成**（内容一致 → 直接用你那份）；`mihomo-widget.conf` 里**没写过** `tun` 键时完全不派生，你的文件说了算。
  - 附带好处：核心 reload（`PUT /configs`）读到的就是这份副本，`tun.enable` 与运行状态一致 → `ReCreateTun` 判定相等、**网卡一动不动**——这是将来做"自环后重置 QUIC"（reload 重建 outbound，hy 重拨）自愈的前提（自愈本身未实现）。
  - `tun_start_delay_ms` 自此只在**兜底路径**上有意义：配置里没有顶层 `tun:` 段时（控件不臆造 tun 段）才走 PATCH，那时仍等这么久再开。

## v0.2.3 (2026-09-18)
- **`Exit & Stop Core` 现在先关 TUN 再杀核心，并且不再"假装成功"**：TUN 是核心创建并持有的虚拟网卡 + 默认路由，`taskkill /F` 是硬杀、不走核心自己的清理路径，可能在机器上留下一张死网卡和它的 `0.0.0.0/1` 路由把整机流量黑洞掉；现在退出前先 `PATCH tun off`（并等它真的拆完，最多 2s）再杀。杀完还会**校验**：控制器仍答得上话＝没杀掉（例如非提权运行时杀不动提权核心），此时日志写 `stop: core still answering after taskkill (needs admin?)` 与 `job done stop result=3`，而不是像以前那样无条件报成功——以前那种"日志说停了、核心还活着"的假象就此消失。
- **`config.yaml.example` 的 TUN 段改成明确的三步指引**：① 先换成真实节点并确认能上网 → ② 想让 TUN 开机就开，把 `tun.enable` 改成 `true` → ③ 重启控件生效。模板默认仍是 `false`（包内是占位节点 `1.2.3.4`，TUN 一开就是整机黑洞，这正是 v0.0.13 那条要避免的）。同时写清：**"核心启动时就建 TUN"是结构性安全的**（`updateTun` 早于 `OnRunning()` 的首拨/组测速），而"运行中开 TUN"可能把正在建立的 hysteria2 连接卡死约 1 分钟；菜单里的 TUN 开关只对本次运行有效，开机状态以配置文件为准。另外记下一条**已证伪**的方案：在同一 PATCH 里先 `interface-name` 钉物理网卡再建 TUN，实测照样自环（绑定钉的是出口网卡，源地址仍由路由决定），别再走这条路。
- 内部：`workerStop` 返回 `isize`（0=已停/3=核心仍在跑）并接到 `handleJobDone`，`stop` 结果不再被丢弃。

## v0.2.2 (2026-09-18)
- **发布包改成两层结构，根目录只剩控件的东西**：以前所有文件平铺在 exe 同级，现在核心相关的一律进 `mihomo\` 子目录——`mihomo.exe`、`config.yaml.example`、`direct.yaml`、`GeoIP.dat`、`GeoSite.dat`（运行时再生成 `config.yaml`、`cache.db`、`meta-backup\` 也都在这里）；根目录只留 `mihomo-widget.exe`、`mihomo-widget.conf` 和运行时的 `mihomo-widget.log`。
  - **升级怎么迁**：老布局（`config.yaml` 直接放在 exe 同级）**仍能跑**——控件找主配置时保留旧的候选目录；但那样 `-d` 仍是 exe 同级，所以 `direct.yaml` / geodata 也得继续留在那里。想用新布局就把 `config.yaml`（以及自己那份 `direct.yaml`）挪进 `mihomo\`，把新包里的核心文件复制到同一个 `mihomo\` 里即可。
  - ⚠ **别整目录替换**：新包里没有你的 `config.yaml`（只有 `.example`），整目录删了重建会丢掉主配置、`cache.db` 以及 conf 里的运行状态（`tun` / `nic_ifindex` / 窗口位置）——覆盖 `mihomo-widget.exe` 与 `mihomo\` 里的核心/geodata/`direct.yaml` 就够。
  - `mihomo\` 是核心 home（`-d` = 主配置所在目录）：`direct.yaml` / geodata / `cache.db` / `meta-backup` 全按它解析，所以这些必须和 `config.yaml` 同目录；主配置指错目录时 mihomo 只记一条 `initial ... provider error`，白名单规则静默失效。

## v0.2.1 (2026-09-18)
- **修复“开机按上次状态恢复 TUN 时，hysteria2 节点约 1 分钟不可达”**：控件原来是在核心一起来就 PATCH 开 TUN，而建虚拟网卡/装路由的那一瞬间会把此期间新拨的 hysteria2（QUIC/UDP）连接绑到 TUN 的地址上——核心自己的报文进了自己的 TUN、再命中 `MATCH,Proxy` 变成自环（核心日志：`[UDP] 198.18.0.1:xxxxx --> <节点 IP>:3001 match Match using Proxy[hy-x]`）。表现就是**全部 hy 节点测延迟失败、YouTube 等也连不上，TCP 节点（anytls/mieru）却正常**，实测要 ~70–90s（QUIC 连接超时重拨）才自己恢复，用户手动切一次 TUN 也救不回来。现在**把开机那次开 TUN 推迟到核心首拨过去之后**：核心确认 online 后再等 `tun_start_delay_ms`（新 conf 键，默认 **3000** ms，0 = 立刻开，上限 60s）才 PATCH。核心刚起来那几秒正是首拨/组测速最密的时候，让过去之后再建网卡就撞不上那个窗口（实测：延迟后的 PATCH 与“手动在菜单里开 TUN”同属安全场景，hy 全程正常）。
  - **语义（重要）**：控件启动时只负责**开**，不负责关。想让 TUN 常开，最干净的是在 `config.yaml` 里写 `tun.enable: true`（核心启动即带 TUN，控件连 PATCH 都不发）；用控件开关就写 `tun = 1`。`tun = 0` 时控件不碰 TUN，`config.yaml` 说什么就是什么——要关就在菜单里切（运行时 PATCH），下次启动仍以配置文件为准。
  - **已知残留**：延迟是避开时间窗，不是结构性保证。若开 TUN 的那一刻恰好有 hysteria2 连接正在建立（节点刚掉线重连、核心刚重启不久），仍会中招（该节点 ~1 分钟自愈）；要彻底消掉得把核心的拨号网卡钉死在物理网卡上（`interface-name`），未采用。
  - 不做的事：不再生成任何派生配置文件（安装目录里只会有 `config.yaml` 这一份主配置）；`mihomo-widget.runtime.yaml` 这版起不再出现。

## v0.2.0 (2026-09-18)
- **修复菜单项 `Exit & Stop Core` 显示成 `Exit  Stop Core`**：Win32 菜单把单个 `&` 当助记符前缀——既吃掉字符又不显示；标签里要写 `&&` 才会原样渲染出一个 `&`。功能、菜单 ID、点击行为都没变，只是文字。
- **删掉 99 行死代码与重复实现**（内部重构，行为不变）：`main.zig`（1227→1168）删掉写了从不读的版本快照字段（`g_state.ver`/`PollBox.ver` 及其两段拷贝）、15 个未使用的 Win32/几何常量、`g_sep_brush` 与 5 个 file-IO 残留常量、`exit_after` 投机参数、`readTunEnableLive` 单调用包装；`workerUpdateCore`/`workerUpdateGeo` 两份逐字克隆合并为 `workerTrigger(kind)`；exe 目录改用既有 `proc.dirOf`，窗口几何只算一次。`ui_draw.zig`（131→129）的 `putSeg` 不再白测一遍宽度（每帧省 4 次 `GetTextExtentPoint32W`），`scaled` 与 `main.scal()` 合并为一处实现。`docsgen.zig`（1166→1128）用手写换行计数、字符串拼接、O(n²) 去重、逐声明全文重扫换成 `std`（`Ast.tokenLocation` / `std.mem.join` / `array_hash_map.String` / 预计算词集），并让生成器与校验器共用同一份"§1 待补符号"与"§3 已列键"判据（此前两边各写一份，§3 两边的行过滤条件甚至不同）。验收：`docs-gen` 对已是最新的文档报 `updated 0` 且文件哈希不变；`docs-check` 331 项全过；四类注入漂移（幽灵符号 / 手改生成列 / 空说明 / 键改名）全部非零退出。
- **文档修正**（开发侧）：`docs/API-REFERENCE.md` §4 的 extern 分组补上漏掉的 `gdi32` 15 个（原写"共 77"却只列 62，并把 3 个 GDI 函数错记在 `user32` 行），§1 的 `DrawCtx` 字段说明 `h` 改为实际的 `bg`。`AGENTS.md` 新增 `std.Io` 分界线（0.16 把 fs / process / net / http / 同步都挪到显式 `Io` 之下，本控件不实例化 `Io`，故这批标准库一律不可用——`std.Thread.Mutex`/`Condition` 的替代品 `std.Io.Mutex` 也在此列，裸 `SRWLOCK` 是正解）；GUI 冒烟流程补"窗口要按 PID 认（同名窗口类会命中用户正在跑的实例）""确定性 offline 靠死端口 + 空壳 `mihomo.exe`"；文档工具补"改过检查路径后必须跑一次变异测试"。

## v0.1.8 (2026-09-16)
- **文档流水线合并成一个 Zig 工具，去掉 PowerShell**（开发侧）：`docs\API-REFERENCE.md` 里可机械推导的单元格（§1 定位列、§3 类型/默认列）与全篇校验，原来由 `scripts\gen_api_ref.ps1` / `check_docs.ps1` 用正则扫 `app/src` 推导——定位行靠"优先 `pub fn` + 缩进 0–4 空格"的猜测，`Config.load` 分支靠"拿下一个 `std.mem.eql` 当界 + 300 字符窗口"推目标字段，结构体默认值靠行正则，REST 路径靠子串匹配。现在合并为 `app\tools\docsgen.zig`：事实全部来自工具链自带的 `std.zig.Ast` 对 `app/src` 的真解析（声明 + 定义行号、标识符、字符串字面量、conf 键 → `Config` 字段 schema），命令是 `cd app && zig build docs-gen`（写回）与 `zig build docs-check`（校验，`build_release.bat` 的前置闸门），两个 PS 脚本与中间 JSON 交付物一并删除。三项实际收益：① **注释 / 字符串里的名字不再能冒充"符号存在"**——迁移时一次性暴露 34 处此类假阳性；② REST 路径改精确匹配，此前 `/version` 会在源码文本里被子串命中，路径写错也查不出来（实测改字面量后旧检查仍报 OK）；③ 生成与校验共用同一份事实，不必再维护"两侧要保持同步"的正则和一张中间 JSON；④ **`docs-check` 现在连生成列本身也校验**（手改的 §1 定位 / §3 类型默认会作为漂移报出来）——旧闸门只看符号/端点/键是否存在，这类改写要等下一次 `gen` 才被静默修回去。迁移后与原流程逐字节等价：`docs-gen` 在干净树上输出 `updated 0, appended 0, skipped 0`（CRLF 逐字节保留），四个负例（新增公开符号 → 补行 + 空说明报错 / 改 conf 键名 / 改名符号 / 改 REST 路径字面量）都能抓到。

## v0.1.7 (2026-09-14)
- **与 AI 编码工具解耦**（流程/文档，开发侧）：`AGENTS.md` 不再要求 commit trailer（历史里的 `Made-with: Proma` 不再沿用，新提交只写项目内容）、不再要求同步任何外部 workspace 规则文件；`docs/zig-0.16-guide.md` 去掉工具专属的 skill front-matter（`compatibility: [opencode, claude-code]`）并把"skill"措辞改成"guide"。仓库文档现在不含任何特定工具依赖，人和任何 agent 都能直接读。

## v0.1.6 (2026-09-14)
- **文档同步半自动化**（开发侧）：新增 `scripts\gen_api_ref.ps1`（从 `app/src` 重算 `docs\API-REFERENCE.md` 里可机械推导的单元格：§1 模块符号定位、§3 conf 键类型/默认，并给未记录的公开符号补行）与 `scripts\check_docs.ps1`（校验符号 / 端点 / conf 键 / 空说明行，非零退出）。校验已挂进 `build_release.bat` 作发布前置闸门——2026-09-14 手工审计抓到过"已删方法仍在文档、extern 表少 17 个函数、行号过期几十处"这类漂移，此举让它在提交前就暴露。
- **不再把所有 IPv6 目标强制直连（whitelist 去掉 `::/0`）**：v0.1.3 为绕开"v6 目标交给代理会拨号超时"给 whitelist 末尾放了 `::/0`（→ `IP-CIDR6,::/0,no-resolve` → `RULE-SET,direct,DIRECT`），让**所有** v6 目标走本机直连。今天复测发现节点池并非都没 v6：**9 个节点里 3 个 NL 节点能到 v6 目标（253–304 ms），其余 6 个（v4-only）504 超时**；`hy-nl` 也确实能把流量送到 v6-only 的主机（实测拿到 SSH banner）。于是去掉这条兜底：**v6 目标改按规则表走**，与域名行为一致——由当前选中的节点决定。影响：① 用**域名**访问的行为不变（本来就是 `MATCH,Proxy`）；② 直接写 **v6 字面量**访问时，选到 NL 节点能通、选到 v4-only 节点会 5s 超时后被 TUN 掐断（要稳就用域名，或把出口切到 NL 节点）；③ **局域网内 v6 不受影响**（同 /64 走 on-link 路由，根本不进 TUN）。想恢复"v6 一律直连"：whitelist 末尾加回 `::/0` → `convert_whitelist` → `PUT /providers/rules/direct`（不必重启核心）。

## v0.1.5 (2026-09-13)
- **网速不再出现 `1000.5 KB/s` 这种超宽数值**：自动单位（`speed_unit_auto=1`，默认）原来按“满 1024 换挡”，于是 1000.0–1023.9 KB/s 会整秒显示成 **5 位数** `1000.5 KB/s`，把本来就很窄的网速行撑长。现在换挡点改为“**显示值四舍五入后满 1000 就换下一档**”：同一区间直接显示 `1.0 MB/s`，`KB/s` 与 `MB/s` 都最多 4 位整数（999.9），两种单位显示宽度一致；MB→GB 同理（1024.0 MB/s → `1.00 GB/s`）。判定用了 999.95 的边界，避免 `999.96` 被四舍五入成 `1000.0` 又冒出 4 位数。单位换算本身仍是 1024（KiB/MiB），数值不变，只是换挡更早；固定 `MB/s` 模式（`speed_unit_auto=0`，需手动开启）不受影响。

## v0.1.4 (2026-09-13)
- **修复“核心起不来时控件关不掉”**：右键菜单是控件唯一的退出入口，但 `menuForGroup` 在核心离线（配置写错导致 mihomo 启动即退出、控制器端口不通、首次启动还没拉起）时会直接早退不弹菜单——表现为一个既不能操作、也关不掉的悬浮窗，只能去任务管理器结束进程。现在菜单在任何状态下都会弹出：依赖核心的项（**Test All Latency / TUN Mode / Manual Update Core / Manual Update Geo** 以及节点列表子菜单）自动置灰或省略，**System Proxy / Auto Start / Network Interface / Exit & Stop Core** 照常可用；离线时展开面板的提示改为 `core offline | right-click menu`，让“还能右键”这件事一眼可见。
- **修复特定配置下启动即崩溃（退出码 0xC0000005）**：主配置里 `external-controller` 写成**具体主机**（如 `127.0.0.1:9090`，非 `0.0.0.0` 通配）或 `secret` **非空**时，控件在启动读配置阶段就会访问已释放内存而崩溃——窗口建不出来，双击 exe 表现为“什么都没出现”。原因是解析主配置的 arena 在内层作用域里就释放了，而解析结果里的 `host` / `secret` 切片仍指向它。现在解析与拷贝共用同一作用域，arena 活到拷进运行时状态之后。（只写通配主机且 `secret` 为空时不会触发，所以之前的配置一直没暴露这个问题。）

## v0.1.3 (2026-09-13)
- **所有 IPv6 目的地改为直连（修复“TUN 开着时连 IPv6 字面量目标必定失败”）**：`scripts\whitelist` 新增 `::/0`，converter 生成 `IP-CIDR6,::/0,no-resolve` 写进 `direct.yaml`，由 `RULE-SET,direct,DIRECT` 直连；同时 `convert_whitelist.ps1` 支持 IPv6 字面量 / CIDR（`IP-CIDR6`，裸地址补 `/128`）与 `#` 注释行（不要在 whitelist 里写具体 IPv6 地址——那是私人信息，会随仓库与发布包扩散）。成因：节点池**没有一个有 IPv6 出口**（9 个节点用 IPv6 URL 测速全部 Timeout/error，IPv4 全通），于是 IPv6 目的地落到 `MATCH,Proxy` 被交给节点，节点侧拨号 5s 超时（mihomo 默认 dial 超时）后 TUN 直接关掉本地连接——SSH 表现为 `kex_exchange_identification: Connection closed by remote host`（`ssh -vvv` 连 `Remote protocol version` 都看不到），而 `ping <v6>` 照常通（mihomo 的 ICMP 恒走 DIRECT，不经过节点，所以“ping 通”不代表 TCP 通）。DNS 无关：IPv6 字面量在 `getaddrinfo` 走 `AI_NUMERICHOST`，不发任何 DNS 查询。改完 `direct.yaml` 用 `PUT /providers/rules/direct` 热更新即可生效（实测 46 条、核心不重启、TUN 不断流）。若用户自己的节点有 v6 出口，可在 `config.yaml` 的 `RULE-SET,direct,DIRECT` **之前**加具体 `IP-CIDR6,<prefix>,Proxy` 覆盖。
- **自签证书改用指纹 pinning（替代 `skip-cert-verify`）**：`config.yaml` 里 anytls / hysteria2 节点原来一律 `skip-cert-verify: true`，等于**完全不校验服务端证书**——这些协议的口令在 TLS 之内，中间人可原样截获。现在改为 `fingerprint: "<叶子证书 SHA-256>"`（sj / dc / hk 三台各填自己的值）。mihomo 的 `fingerprint` 命中服务端证书链**第 0 张（叶子）即放行且不再做任何额外校验**（`component/ca/fingerprint.go`：`i == 0` 直接 `return nil`），所以自签证书、无 SAN、CN 与域名不符都不影响；**注意 `certificate`/`private-key` 是 mTLS 的客户端证书，不能用来信任服务端证书**。换服务端证书后必须同步客户端：`ssh root@<host> openssl x509 -noout -fingerprint -sha256 -in /etc/mihomo/server.crt`。实测：pinning 与 `skip-cert-verify` 行为一致（sj 三协议 200/347-583ms），故意写错指纹则握手失败（负例通过）。

## v0.1.2 (2026-09-12)
- **白名单直连新增域名**：`aliyun.com`、`qianwen.com`、`qianwenai.com` 加入 `scripts\whitelist`，经 `rule-providers` + `RULE-SET,direct,DIRECT` 强制直连（不占用代理流量）。改动随下次打包生效（`build_release.bat` 会重新生成 `direct.yaml`，共 45 条规则）；核心需重启才应用新规则。

## v0.1.1 (2026-09-12)
- **发布包目录与 zip 名带版本号与架构**：产物从固定的 `release\mihomo-widget\` / `mihomo-widget.zip` 改为 `release\mihomo-widget-v0.1.1-x86_64\` / `mihomo-widget-v0.1.1-x86_64.zip`。版本号由 `build_release.bat` 从 `docs\CHANGELOG.md` 最新 `## vX.Y.Z` 标题读取（单一来源，只改 changelog 即可，找不到版本会报错退出），架构标签因工具链固定为 x86_64 而写死。zip 现在把版本化目录本身作为根（解压得到一个带版本名的文件夹），不再把包内文件散落到解压目录，因此新旧版本可共存不互相覆盖。打包时会比对最新 git tag，若 changelog 标题与 tag 同名且 tag 之后仍有提交则提示“版本未递增”。旧的无版本目录/zip 不再生成，可自行删除。

## v0.0.13 (2026-09-11)
- **发布包脱敏模板改为原名 `config.yaml.example` 进包**（接续 v0.0.11）：不再重命名为 `config.yaml`——包内没有可直接运行的主配置，用户首次使用前必须自己复制成 `config.yaml` 并填入真实节点，避免控件直接跑在 `1.2.3.4` 占位节点上“看似正常、全部拨号失败”的迷惑状态。

## v0.0.12 (2026-09-11)
- **节点名单不再双份维护（`include-all`）**：`Proxy`（select）与 `Auto-Select`（url-test）改用 mihomo Meta 扩展 `include-all: true` 全量自动收录静态节点（随包核心 v1.19.30 实测：select 组显式成员排前、节点自动追加在后，子组 `Auto-Select` 保留；url-test 自动测全池）。以后**新增节点只改 `proxies:` 段一处**，不必再同步组成员列表；模板与本机配置已同步改好（本机旧配置备份 `app\cfg\config.yaml.bak-20260911`）。菜单 40 节点上限、ASCII 命名约定不变；需重启核心生效，重启后确认菜单打勾态与 Test All Latency。

## v0.0.11 (2026-09-11)
- **发布包不再打进私密配置**（修复隐私泄露）：`build_release.bat` 原来把 `app\cfg\config.yaml`（含真实节点地址/密码）直接复制进发布包并打进 zip。现在改为把脱敏模板 `app\cfg\config.yaml.example`（占位 `1.2.3.4` / `change_me`）以 `config.yaml` 名字打进包，用户首次安装时替换成自己的节点；模板缺失时打包直接报错退出，绝不回退到真实配置。已重新生成现有 `release\mihomo-widget\` 与 zip 并逐字节核验（`release/` 已 gitignore，私密配置未进过 git 历史）。

## v0.0.10 (2026-09-10)
- **置顶守护（修复偶发“GUI 不在前台”）**：窗口创建时就是 `WS_EX_TOPMOST`，但 Windows 会在工作站解锁、分辨率/显示器变更、DWM 重建 Z-order 后把面板挤到普通窗口之下（只能靠点一下面板唤回）。现在控件会自检（默认每 5s，新 conf 键 `topmost_guard_ms`，0=关闭）并在发现被普通窗口遮挡、或置顶样式位丢失时，用不抢焦点的方式（`SWP_NOACTIVATE`）重新置顶；`WM_DISPLAYCHANGE` 时立即修一次。每次修复写入日志 `topmost guard: re-asserted (...)`。
- **配置文件改名为 `config.yaml`，节点段挪到文件末尾**（原来是一份 `mihomo_client.yaml`，结构顺序照旧但节点埋在中间）。现在顺序是：全局设置 → dns → tun → proxy-groups → rules → geo → **proxies**，改节点只看最后一段。仓库脱敏模板相应改名为 `config.yaml.example`。
- **右键菜单：节点列表收进二级菜单** `Nodes (Proxy)`。节点多起来时平铺会把系统代理 / TUN / 更新等功能项挤出屏幕。当前节点仍打对勾并作为默认项（回车直接选中），延迟标注 `名称  (123 ms)` 与点击行为不变。
- **dev 布局与路径修正**（老问题：开发版控件其实一直找不到 `app\cfg` 的配置）：候选目录原来写的是 `..\cfg`，相对 `app\zig-outin` 实为 `app\zig-out\cfg`；而且带 `..` 的路径直接交给 mihomo——**mihomo(Go) 不做路径归一化，配置文件读不到时不报错，而是自己写一份默认配置跑在 7890**（表现为面板一直 core offline）。现在候选目录改为 `..\..\cfg`、交给核心前归一化路径，并把核心 home（`-d`）设为**配置文件所在目录**，开发版与发布包从此用同一份配置文本。
- **TUN 开关加固**：以前发完 `PATCH /configs` 只睡 600ms 再读一次 `tun.enable`，会把“没生效”当成成功。现在轮询校验**真实状态**（开关 on 且虚拟网卡 `device` 已建好），一次没生效就自动补一轮 `off→on` 逼核心重建网卡（日志 `tun: apply did not settle, retry off->on` / `tun: recovered after off->on retry`）；网卡卡住时菜单标题也显示 off，点一下就走重建路径。测完面板提示 `Latency: N/M alive`。
- 诊断日志：启动行增加 `cfg=<命中的主配置文件名>`，一眼能看出命中的是新布局还是旧 `mihomo_client.yaml`。
- 说明：本次曾试过把节点拆成 `proxies.yaml` + `proxy-providers` 挂载（可热换池、不必重启核心），实测**回退**了——provider 里的节点不会注册进控制器的 proxy 表，`GET /proxies/{节点名}/delay` 一律 404，逐节点即时测速就没了，只剩 provider health-check 的周期结果（实测设 120s 约每 240s 才一轮）。即时测速更值钱，所以节点保持静态 `proxies:` 声明。
- 旧布局兼容：若目录里没有 `config.yaml`，仍回退使用 `mihomo_client.yaml`。

## v0.0.9 (2026-09-09)
- **网卡手动选择**：右键菜单新增 **Network Interface** 二级菜单，列出可用的物理网卡，用户选择统计哪一张；选择结果存入 `mihomo-widget.conf` 的 `nic_ifindex`。
- **修复网速翻倍**：`GetIfTable2` 会把同一物理网卡的多个 NDIS filter 绑定（WFP / QoS / 802.3 / WiFi Filter 等）当作独立网卡**重复计数**，导致下载/上传虚高（曾约翻倍）。现在只统计真正的物理网卡（排除回环 / TUN / 无 MAC 虚拟口，且排除 filter 镜像与虚拟适配器）；未手动选择时自动汇总所有物理网卡。
- **conf 整理**：自动管理的键（`window_x/y`、`sysproxy`、`tun`、`nic_ifindex`）集中到文件底部"自动管理"分区注释；保存时若这些键是注释状态（`#key = value`）会去掉 `#` 就地更新，不再保留注释又追加重复行。
- **修复内存泄漏（长跑涨到 1.4GB / GUI 消失）**：`GetIfTable2` 返回的接口表原先没有 `FreeMibTable` 释放，每秒轮询都泄漏一份，内存随时间涨到 GB 级并拖垮 GUI。现已用完即释放，实测**连续挂机约 15 小时**内存完全平稳（工作集 18–19MB / 私有提交 20–21MB，任务管理器专用工作集约 4.4MB），不再随时间增长。
- 诊断日志：新增 `mihomo-widget.log`（exe 同级，保留最近约 1MB）：启动（conf 关键值 + 基线内存）、每 10s 的 poll 摘要（`online/status/nodes/mem=<工作集>/<私有提交>MB`）、轮询失败、后台任务开始/完成、窗口销毁，便于定位内存与稳定性问题。
- **置顶守护（修复偶发“GUI 不在前台”）**：窗口创建时就是 `WS_EX_TOPMOST`，但 Windows 会在工作站解锁、分辨率/显示器变更、DWM 重建 Z-order 后把面板挤到普通窗口之下（只能靠点一下面板唤回）。现在控件会自检（默认每 5s，新 conf 键 `topmost_guard_ms`，0=关闭）并在发现被普通窗口遮挡、或置顶样式位丢失时，用不抢焦点的方式（`SWP_NOACTIVATE`）重新置顶；`WM_DISPLAYCHANGE` 时立即修一次。每次修复写入日志 `topmost guard: re-asserted (...)`，便于确认原因。

## v0.0.8 (2026-09-08)
- **网速可配置**：新增 conf 键 `speed_refresh_ms`（网速刷新间隔，默认 1000ms，范围 100–3000）与 `speed_unit_auto`（1=按量级自动选 KB/MB/GB，0=固定 `MB/s`，默认自动）。
- 网速行默认按量级自动切换 KB/s / MB/s / GB/s 单位（不显示 B/s）。

## v0.0.7 (2026-09-08)
- **菜单调整**：移除右键菜单里的 `Exit (keep core)`，新增 **Manual Update Core**（手动更新 mihomo 核心二进制并重启）与 **Manual Update Geo**（手动下载最新 GeoIP/GeoSite/ASN/MMDB）。
- 升级与 geo 更新走 mihomo 的 `POST /upgrade` / `POST /upgrade/geo`，在后台 worker 执行、不阻塞 UI；核心升级完成后由 mihomo 自行重启（external-controller 会短暂离线）。

## v0.0.6 (2026-09-08)
- **网速修正**：只统计真实物理网卡（排除 mihomo TUN / Hyper-V / 无 MAC 的虚拟接口）。
  此前 TUN 开启时同一批流量会被 TUN 网卡和物理网卡各计一次，导致网速显示虚高（约翻倍）。
- 网速刷新间隔改为 0.5s（更灵敏），并按采样间隔归一化到“每秒”，半秒窗口不再使数值偏小。
- **状态记忆**：系统代理 / TUN 开关状态持久化到 `mihomo-widget.conf`；
  启动时自动恢复上次状态（TUN 在核心 online 后尽力恢复），退出时自动还原（关闭 TUN + 清除系统代理）。
- 修复 TUN 首次开启出现 `enabled → disabled` 抖动（自动恢复误切），手动操作后不再被自动恢复干扰。
- 配置统一移入 `app/cfg`（`mihomo-widget.conf` / `mihomo_client.yaml` / 模板），
  运行时代码兼容开发版（exe 在 `app\zig-out\bin`、向上找 `..\cfg`）与发布包（配置与 exe 同目录）。
- 新增 `docs/API-REFERENCE.md`（符号/端点/conf 键索引）与项目根 `AGENTS.md`（项目地图 + 操作流程，含“更新文档”步骤）。

## v0.0.5 (2026-09-07)
- **TUN 快速生效**：开启 TUN 后自动执行 `ipconfig /flushdns`，域名立即走 mihomo 的 fake-ip + TUN，首连明显加快。
- 本地配置新增 `tun` 段（`stack: mixed`、`auto-route`、`dns-hijack: any:53` 等），
  把默认的 gVisor 用户态栈换成更接近系统栈的 `mixed`，TUN 切换后更接近 gui.for.clash 的速度。
- 目录整理：构建/转换脚本与 whitelist 移入 `scripts/`；`CHANGELOG.md` 移入 `docs/`；
  新增 `docs/zig-0.16-guide.md`（Zig 0.16 API 参考）。
- `mihomo_client.yaml.example` 同步 TUN 提速段，模板开箱可复现。

## v0.0.4 (2026-09-07)
- **GUI / 后台解耦**：首次引入多线程，新增后台 worker 线程。
  - 延迟测试、TUN 切换、停止核心三个菜单任务不再阻塞 UI。
  - 每秒 mihomo 状态轮询（version/snapshot/groupDetail）也移到后台，
    UI 线程只负责消息循环 + 绘制，启动/轮询期间窗口不再卡顿。
  - 用 Win32 Event + `std.atomic` 驱动 worker，结果经 SRWLOCK 保护的快照槽回传 UI。
- WinHTTP 增设 2s 超时，controller 未就绪/较慢时请求快速失败，进一步防挂起。
- 新增脱敏模板 `mihomo_client.yaml.example`（不含节点/密钥，保留 lite geo + 白名单直连功能），
  方便 clone 后开箱即用。

## v0.0.3 (2026-09-07)
- **main.zig 模块化重构**：拆出 `win32.zig`（互操作层）、`ui_draw.zig`（GDI 绘制）、
  `proc.zig`（文件/路径/子进程）、`system_win.zig`（注册表系统代理/自启）；
  UI 配置聚合为带 `load()` 方法的 `Config` 结构体。
- 网速文本上边距可配置（`speed_top` / `speed_top_hover`，默认 3），替代旧的垂直居中。
- 精简 geo 数据源：改用 `meta-rules-dat` 的 lite 版（GeoIP/GeoSite），
  体积从约 27MB 降到约 0.4MB；打包不再携带 `Country.mmdb`。
- whitelist 直连白名单：经 `rule-providers` + `RULE-SET,direct,DIRECT` 强制白名单域名直连，
  独立于 geo 数据更新；`build_release.bat` 打包时自动把 `whitelist` 转换为 `direct.yaml`。

## v0.0.2 (2026-09-05)
- 窗口位置持久化：退出时把 `window_x`/`window_y` 写回 `mihomo-widget.conf`，下次原位置打开。
- 修复多网卡流量统计（基于 GetIfTable2 差分，逐接口汇总非回环活动网卡）。
- 新增 Windows 构建脚本 `build.bat`（开发构建）与 `build_release.bat`（发布打包 + zip），
  移除旧的 `build_release.sh`。

## v0.0.1 (2026-09-05)
- 首个版本：Zig + Win32 轻量 mihomo 悬浮代理控件（无边框、置顶、半透明、GDI 双缓冲）。
- 功能：实时网速显示（▲/▼）、当前代理群组与节点展示、左键拖动、右键菜单
  （切换节点、测试全部延迟、系统代理开关、TUN 模式、开机自启、退出）。
- 状态轮询 mihomo external controller；轻量 YAML 解析 `mihomo_client.yaml` 的控制器地址与密钥。
- 停止追踪私密配置 `mihomo_client.yaml`（用户订阅信息不进仓库）。

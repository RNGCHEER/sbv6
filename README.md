# sbv6

面向 **fscarmen/sing-box** 的独立 IPv6 / 双栈管理助手，参考 RNGCHEER/ARGOXV6 v2.1.5 的工作流。**只下载 `sbv6.sh` 一个文件即可安装使用**，程序已嵌入脚本，无需另外下载 Python 源文件或安装 pip 包。

## 安装与使用

以 root 运行一键安装：

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/RNGCHEER/sbv6/main/sbv6.sh)
```

或下载后运行：

```bash
curl -fLO https://raw.githubusercontent.com/RNGCHEER/sbv6/main/sbv6.sh
sudo bash sbv6.sh
```

**不需要预先安装上游。**首次运行时检测 [fscarmen/sing-box](https://github.com/fscarmen/sing-box)：未安装则选择「安装官方上游」「仅用 sbv6，只下载核心」或取消。选择独立模式不会执行上游脚本、不会创建 `/etc/sing-box`；核心安装在 `/etc/sbv6/bin/sing-box`。已有上游时复用其核心与可用凭据。缺少 Python、curl、openssl、iproute2 等依赖时自动通过 apt/apk/dnf/yum/zypper 安装。需要 Linux、Bash、systemd 或 OpenRC，Python 版本需 3.9+。

```bash
sudo bash sbv6.sh
# 按提示选择安装方式，完成后直接进入管理菜单；以后输入：
sudo sbv6
# 无交互指定是否安装上游（二选一）
sudo bash sbv6.sh -i --upstream install
sudo bash sbv6.sh -i --upstream skip
sudo sbv6
# 独立添加 IPv6，参考上游对应协议的凭据；没有对应协议则生成新凭据
sudo sbv6 -a --protocols bcfg -p 35000
# 双栈，显式指定公网 IPv4（适用于 NAT），IPv6 默认探测本机稳定 GUA
sudo sbv6 -b --protocols bc -p 36000 --ipv4 203.0.113.10
sudo sbv6 -l --ipv4 203.0.113.10
sudo sbv6 -f       # 切换参考/独立模式，可立即套用现有 IPv6 节点，保留端口
sudo sbv6 -s       # 探测 IPv6 并幂等同步
sudo sbv6 -d       # 本机地址、路由、监听和配置诊断（含凭据，勿公开）
sudo sbv6 -u       # 确认后卸载
```

示例中的 IPv4 为文档地址，运行时换成真实地址。`--ipv6` 可显式指定本机地址用于首次添加；后续自愈以网卡上的公网稳定地址为准。WSL 的 `::1` 只用于测试。

菜单包括：上游 `sb` 管理、IPv6 添加、双栈添加、链接订阅、编号多选删除、同步修复、地址重探、状态、卸载、安装命令、凭据模式。`--protocols a` 选择全部；字母同上游。

| 字母 | 上游协议标签 |
|---|---|
| b | xtls-reality |
| c | hysteria2 |
| d | tuic |
| e | ShadowTLS（v3 + Shadowsocks 2022，独立 detour） |
| f | shadowsocks（2022） |
| g | trojan |
| h | vmess-ws |
| i | vless-ws-tls |
| j | h2-reality |
| k | grpc-reality |
| l | anytls |
| m | naive（HTTP2 与 QUIC 客户端输出） |
| n | snell-v6 |

节点名采用上游的 `节点名 协议标签`，新增节点在节点名中加入 `IPv4` / `IPv6` 区分地址族。参考模式复用对应协议的 UUID、密码、Reality 密钥、SNI、证书；不复用端口。独立模式生成新凭据及独立自签证书。

## 架构与输出

- 上游保持自己的 sing-box 进程；sbv6 使用独立 `sbv6.service` 和 `/etc/sbv6/config.json`，不修改上游 ExecStart。
- 安装时将上游 `::` 直连监听改为 `0.0.0.0`，保留注释；不改 `127.0.0.1` / `::1` 隧道回源。配置校验失败会恢复原文件。通过菜单调用 `sb` 后重新同步。
- 双栈新增监听分别为 `0.0.0.0` 和具体 IPv6，同协议共用端口；跳过上游配置端口、已有节点端口和系统监听。
- 配置先通过真实核心 `check`，再替换；重启失败恢复原配置。配置不变不重启。独立进程故障不影响上游进程。
- systemd timer 每分钟重探 IPv6；OpenRC 使用 `/etc/periodic/1min/sbv6`（需 crond 已运行）。
- 检测到 iptables/ip6tables 时按需添加带 `sbv6` 注释的 INPUT 放行规则，删除节点和卸载时只清理自己的规则。不处理云厂商安全组；无 iptables 环境需自行开放对应端口。
- 卸载时仅在上游文件未被其他操作修改时恢复原文，避免覆盖后来配置。

输出到 `/etc/sbv6/`：

| 文件 | 用途 |
|---|---|
| nodes.txt | 节点 URI |
| subscription.txt | 全节点 URI 的 Base64 订阅内容 |
| client.json | sing-box 客户端 outbounds，嵌入 TLS 证书以校验证书 |
| clash.yaml | Mihomo/Clash 配置，采用 YAML 1.2 兼容的 JSON 格式 |
| state.json | 凭据、节点与上游恢复记录；目录仅 root 可读 |

传入 `--ipv4` 时，输出还会合并上游已安装的上述直连协议。不会猜测 NAT 公网地址。TLS 自签节点的 URI 和 Clash 输出采用跳过证书校验以兼容导入；需要严格校验时使用 `client.json`。订阅为本地文件，不自动启动 HTTP 发布服务。

## 与参考项目的边界

sing-box 没有 Xray `adi/rmi` 入站 API，因此使用独立进程和经校验的重启代替热挂载；改变已有 sbv6 配置会短暂断开 sbv6 连接。V6 协议按 sing-box 上游 b–n 共 13 种提供，WS 默认使用直接 IPv6 连接，不自动部署 Argo/CDN。ShadowTLS 分地址族生成唯一 detour，Naive 使用 200 天独立证书，Snell 使用 v6。Clash 输出按上游惯例不包含 Naive；Naive 通过 sing-box JSON / URI 导出。上游 WARP/路由规则不自动复制，sbv6 使用 direct 出站。

独立模式核心版本与参考仓库默认值一致，为 `1.15.0-alpha.13`，包含新增协议所需能力；复用旧版上游核心时，若不支持新增协议会在 `check` 阶段拒绝发布配置，可先通过上游升级核心。选择安装上游时下载并交互运行官方脚本；退出安装后检测安装结果。直接运行脚本会安装命令与守护并进入菜单，也可用 `-i` 只安装。`sbv6.sh` 支持 `bash <(curl -fsSL URL)`：程序释放到临时目录后安装到 `/usr/local/lib/sbv6`，退出清理临时文件。开发时修改 `sbv6.py` 后执行 `python3 build_installer.py` 重建单文件脚本。

## WSL 测试

已在 Windows WSL Debian 执行，核心为 sing-box 1.15.0-alpha.13：

```bash
python3 -m unittest discover -s tests -v
python3 tests/integration.py
bash -n sbv6.sh
```

16 项测试通过，包括单文件独立运行、`bash <(curl ...)` 入口、参数传递、交互输入、临时文件清理，以及未安装上游时的安装、跳过、取消分支（模拟下载与安装执行）及双栈 ShadowTLS detour 隔离。13 种协议服务端及客户端通过真实核心检查，真实 IPv6 TCP/UDP 监听通过；9 种协议（Hy2、TUIC、SS2022、Trojan、VMess WS、VLESS WS TLS、AnyTLS、Naive、Snell v6）跑通 SOCKS → IPv6 协议 → 本地 HTTP 端到端。Reality 与 ShadowTLS 尚未验证公网握手。日志见 `tests/wsl-test.log`、`tests/wsl-integration.log`。测试没有执行官方上游安装器、没有安装生产服务，也没有修改 WSL `/etc/sing-box`。systemd/OpenRC 安装卸载、实际公网 IPv6 前缀变化和 Clash 客户端导入尚未实机验证。集成测试核心在 `tests/bin/sing-box-1.15.0-alpha.13-linux-amd64/sing-box`，仅供测试。

## 来源

- https://github.com/RNGCHEER/ARGOXV6
- https://github.com/fscarmen/ArgoX
- https://github.com/fscarmen/sing-box

参考仓库均为 GPL-3.0，项目随附 GPL-3.0 许可证。

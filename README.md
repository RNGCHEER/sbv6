# sbv6 — 基于 fscarmen/sing-box 的 Bash 双栈扩展

直接以 fscarmen/sing-box 源码为基础，复用其 `sing-box_json`、`fetch_nodes_value`、`export_list` 与证书生成函数。运行时及构建均使用 **Bash + jq + Linux 工具 + systemd/OpenRC**，不需要 Python、pip 或 Node。

## 一键安装 / 更新

以 root 运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/RNGCHEER/sbv6/main/sbv6.sh)
```

以后输入 `sbv6`。缺少依赖时通过 apt/apk/dnf 安装。未安装上游时可以选择调用官方脚本安装，或只下载核心独立使用。已有旧版 sbv6 时用同一命令更新，首次启动通过 jq 迁移旧 state.json 节点，保留原文件与凭据。

```bash
sbv6 -a --protocols bc -p 35000 --ipv6 本机IPv6
sbv6 -b --protocols bc --ipv4 公网IPv4
sbv6 -l                    # 节点及合并 Base64 订阅
sbv6 -s                    # IPv6 自愈与配置同步
sbv6 -d                    # 本机 IPv6 地址和路由诊断
sbv6 --sb                  # 上游完整原版管理流程
sbv6 -u                    # 卸载 sbv6，不卸载上游
```

## IPv6 探测修复

主菜单顶部显示操作系统、内核、架构、虚拟化、IPv4/IPv6、地区/ISP，以及 sbv6、上游 sing-box、Argo、Nginx 的状态、版本和可读取的内存占用。公网双栈探测并行执行并设置超时，同次菜单会话缓存结果；菜单 7 可刷新。探测不可达时显示本机地址并明确标注，不将内网地址误称为公网地址。没有地址或服务时显示“未检测到”或“未安装”。

使用与上游相同的 `ip` 地址、路由信息，不要求 `ip -j` 或 Python 地址分类。优先出站源地址与稳定公网地址，临时地址可兜底。

选择菜单 8（添加/删除协议），再选 IPv4、IPv6 或双栈后，自动带入面板识别到的对应公网 IP；CLI 也可用 `--v4` 单独添加 IPv4，无需先配置 IPv6。`--ipv4`、`--ipv6` 可覆盖自动值。

容器/NAT 环境中，公网 IPv6 可能不在本机网卡，而网卡只有 `fd00::`。此时节点链接使用识别的公网 IPv6，本机监听使用路由源地址或可用网卡地址，避免直接绑定公网 IP 失败。手工填写同一个已识别公网 IPv6 也会按此处理。只有与本机和已识别公网地址均不匹配的输入才会拒绝。公网入站仍须由宿主机/服务商转发到对应端口；出站 IP 探测成功不代表已配置入站映射。

没有识别到公网地址时才提示手动输入。服务器确实没有 IPv6 时需先在 VPS 控制台开通并配置，脚本不能创造公网 IPv6。

菜单 5 → 选择地址族 → 上游节点管理菜单可修改服务器地址；手动指定的节点连接地址会保留，定时同步只更新本机监听，不会覆盖它。

## 协议与输出

协议字母与上游一致：b Reality、c Hysteria2、d TUIC、e ShadowTLS、f Shadowsocks 2022、g Trojan、h VMess WS、i VLESS WS TLS、j H2 Reality、k gRPC Reality、l AnyTLS、m Naive、n Snell v6；a 为全部。

选择前显示完整字母与协议名称，支持 `bc` 组合、回车全选、大小写、重复字母去重、输入错误后重试与 `0` 取消；选择后回显具体协议名。

主菜单顺序参照上游：1 节点信息、2 服务开关、3 Argo 开关、4 更换 Argo、5 修改配置、6 同步自检、7 系统状态、8 添加/删除协议、9 卸载；10 原版菜单、11 凭据模式、12 更新脚本。Argo 操作委托上游原版流程。

## TLS 实现与管理

直接复用上游 `ssl_certificate`、`sing-box_json`、`change_config` 和 `export_list`，没有另写一套 TLS 协议或默认为全部节点关闭证书校验。Reality 使用原生握手，ShadowTLS 使用其上游握手配置；普通 TLS 自签证书按上游输出 SPKI/证书指纹，Naive 使用上游 200 天证书和证书嵌入输出。

菜单 **5 → 选择 IPv4/IPv6** 直接调用上游 `change_config` 动态节点管理菜单，包含端口（连续/独立端口）、节点名称、UUID/密码/PSK、服务器地址、SNI、客户端指纹，以及已安装协议对应的带宽、拥塞控制和 Reality Vision/多路复用等节点选项。显示的项目由已配置协议决定。主机级 nginx 订阅发布、TUN/WARP 路由和端口跳跃等功能仍由菜单 10 的上游原版管理，此独立直连实例不提供这些选项。

SNI 修改按上游方式重新签发所选地址族证书、更新关联配置；完成后需重新导入节点。服务操作限定在独立 sbv6，不重载上游服务；校验或重启失败恢复该地址族证书和配置。

输出按每个节点实际引用的证书和 SNI 调用原版导出函数，避免参考模式与独立模式混用时引用错误指纹。Naive 到期续签调用原版 `ssl_certificate ... naive_only`；对上游路径使用 sbv6 自有副本续签，不覆盖原来源证书。

WSL 的 `tests/test-tls.sh` 已验证混合证书来源、真实 IPv6 Trojan 指纹握手、原版 SNI 管理、客户端指纹持久化、修改失败回滚和真实过期证书续签。记录见 `tests/wsl-tls.log`。

同一测试还验证原版节点管理的名称、服务器地址、端口模式与确认流程，确保修改实际写入配置而非只改变菜单文字。

节点名保持上游的“节点名 协议标签”，并加入 IPv4/IPv6 标识。两族使用各自配置目录；ShadowTLS 的 detour 标签按族隔离。参考模式复用上游对应协议凭据，独立模式重新生成。模式切换对后续添加生效。

节点输出直接使用上游原版函数，包含 V2rayN、ShadowRocket、Clash Mihomo、Throne 和 sing-box。多选协议会逐个校验上述客户端产物，最后明确显示“已导出数量/已选择数量”及每个协议的名称、地址族和端口；任何一个协议缺少输出都会报错，不再把不完整结果显示为成功。`/etc/sbv6/v4/`、`v6/` 中保存 list、nodes.txt、subscription.txt、clash.yaml 等；原生 sing-box 客户端配置位于各族 subscribe/sing-box。合并 URI 与 Base64 订阅在 `/etc/sbv6/nodes.txt` 和 subscription.txt。

## 隔离与限制

sbv6 使用独立 sing-box 服务与 `/etc/sbv6/config.json`，不修改上游 ExecStart。修改配置先通过核心校验，重启失败恢复上一份配置；配置未变不重启。systemd timer / OpenRC periodic 每分钟同步地址。防火墙规则仅操作带 sbv6 注释的规则；云安全组需自行放行。

WS 为直接 IPv6 连接，不自动创建 Argo/CDN。上游 WARP/分流不会复制到独立服务。当前删除流程为单编号确认；凭据模式切换在后续添加时生效。systemd/OpenRC 安装卸载与真实公网前缀变化尚未在生产 VPS 验证。

## 源码与 WSL 验证

- vendor/sing-box.sh：上游源码快照，保留 GPL-3.0 许可证与作者声明。
- sbv6-extension.sh：IPv6/双栈管理扩展。
- native-export.sh：向原生输出函数加入落盘钩子。
- build-installer.sh：构建单文件发布脚本。

```bash
bash build-installer.sh
bash tests/test-bash.sh
bash tests/test-multi-select.sh
```

WSL Debian + sing-box 1.15.0-alpha.13 实测：13 协议原生配置生成、14 入站（含 ShadowTLS 内层）及标签隔离、真实核心配置校验、IPv6 监听、原生多客户端输出、sing-box 客户端配置校验、旧版 JSON 迁移、无 IPv6 时手动输入与取消。记录见 tests/wsl-bash.log。测试不修改生产服务；核心放在 tests/bin/sing-box-1.15.0-alpha.13-linux-amd64/sing-box，不上传仓库。

来源：https://github.com/fscarmen/sing-box ，设计参考：https://github.com/RNGCHEER/ARGOXV6 。本项目按 GPL-3.0 发布。

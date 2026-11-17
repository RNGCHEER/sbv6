# sbv6 additions to fscarmen/sing-box; Bash + jq, no Python runtime.
V6_HOME=${SBV6_DIR:-/etc/sbv6}
V6_UPSTREAM=${SB_DIR:-/etc/sing-box}
V6_CORE=${SB_BINARY:-$V6_HOME/sing-box}
v6_probe_ip() {
  local family=$1 endpoint result
  ip -"$family" route get "$([ "$family" = 4 ] && echo 1.1.1.1 || echo 2606:4700:4700::1111)" >/dev/null 2>&1 || return 0
  for endpoint in "${IP_API_NODES[@]}"; do
    result=$(curl -q -"$family" -fsS --retry 0 --connect-timeout 1 --max-time 2 "$endpoint?lang=zh-CN" 2>/dev/null) || continue
    if jq -e --arg f "$family" '.ip | strings | if $f=="6" then contains(":") else test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$") end' <<< "$result" >/dev/null 2>&1; then
      printf '%s\n' "$result" > "$V6_TMP/ip$family.json"; return 0
    fi
  done
  return 0
}
v6_network_info() {
  [ "${V6_NETWORK_FETCHED:-0}" = 1 ] && return 0
  v6_probe_ip 4 & local pid4=$!
  v6_probe_ip 6 & local pid6=$!
  wait "$pid4"; wait "$pid6"
  local family info address localaddr
  for family in 4 6; do
    address=''; info=''
    if [ -s "$V6_TMP/ip$family.json" ]; then
      address=$(jq -r '.ip' "$V6_TMP/ip$family.json")
      info=$(jq -r '[.country // empty, .isp // .org // empty] | join("  ")' "$V6_TMP/ip$family.json")
    else
      localaddr=$(ip -o -"$family" addr show scope global 2>/dev/null | awk '!/tentative|dadfailed/ {split($4,a,"/");print a[1];exit}')
      [ -z "$localaddr" ] || { address=$localaddr; info='（本机地址，公网探测未成功）'; }
    fi
    printf -v "V6_PUBLIC$family" '%s' "${address:-未检测到}"
    printf -v "V6_IPINFO$family" '%s' "$info"
  done
  V6_NETWORK_FETCHED=1
}
v6_service_summary() {
  local name=$1 binary=$2 state='未运行' version='' pid='' memory=''
  if [ ! -x "$binary" ] && ! command -v "$binary" >/dev/null 2>&1; then printf '未安装'; return; fi
  if [ -d /run/systemd/system ]; then
    if systemctl is-active --quiet "$name" 2>/dev/null; then
      state='开启'; pid=$(systemctl show -p MainPID --value "$name" 2>/dev/null)
    fi
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service "$name" status >/dev/null 2>&1 && state='开启'
    [ ! -r "/run/$name.pid" ] || read -r pid < "/run/$name.pid"
  fi
  case "$name" in
    sbv6|sing-box) version=$("$binary" version 2>/dev/null | awk 'NR==1 {print $NF}') ;;
    argo) version=$("$binary" --version 2>/dev/null | awk 'NR==1 {print $3}') ;;
    nginx) version=$("$binary" -v 2>&1 | sed -n 's/.*nginx\///p') ;;
  esac
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ -r "/proc/$pid/status" ]; then
    memory=$(awk '/^VmRSS:/ {printf "  内存: %.1f MB",$2/1024}' "/proc/$pid/status")
  fi
  printf '%s  %s%s' "$state" "${version:+Version: $version}" "$memory"
}
v6_header() {
  local os='未知系统' virt='未知' kernel arch color='' reset=''
  if [ -r /etc/os-release ]; then os=$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-$NAME}"); fi
  kernel=$(uname -r); arch=$(uname -m)
  if command -v systemd-detect-virt >/dev/null 2>&1; then virt=$(systemd-detect-virt 2>/dev/null) || virt=${virt:-物理机}; fi
  v6_network_info
  if [ -t 1 ]; then color=$'\033[1;32m'; reset=$'\033[0m'; fi
  printf '\n%s====================================================================\n' "$color"
  printf ' sbv6 · Bash + jq  |  基于 fscarmen/sing-box %s\n' "$VERSION"
  printf ' 系统信息：\n   操作系统：%s\n   内核：%s\n   架构：%s\n   虚拟化：%s\n' "$os" "$kernel" "$arch" "$virt"
  printf '   IPv4：%s  %s\n   IPv6：%s  %s\n' "$V6_PUBLIC4" "$V6_IPINFO4" "$V6_PUBLIC6" "$V6_IPINFO6"
  printf '   sbv6 Sing-box：%s\n' "$(v6_service_summary sbv6 "$V6_CORE")"
  printf '   上游 Sing-box：%s\n' "$(v6_service_summary sing-box "$V6_UPSTREAM/sing-box")"
  printf '   Argo：%s\n' "$(v6_service_summary argo "$V6_UPSTREAM/cloudflared")"
  printf '   Nginx：%s\n' "$(v6_service_summary nginx nginx)"
  printf '====================================================================%s\n' "$reset"
}
v6_error() { printf '%s\n' "$*" >&2; return 1; }
v6_dependencies() {
  local c missing=0
  for c in jq curl openssl ip ss flock; do command -v "$c" >/dev/null || missing=1; done
  [ "$missing" = 0 ] && return 0
  if command -v apt-get >/dev/null; then apt-get update && apt-get install -y jq curl openssl iproute2 util-linux ca-certificates
  elif command -v apk >/dev/null; then apk add jq curl openssl iproute2 util-linux bash ca-certificates
  elif command -v dnf >/dev/null; then dnf install -y jq curl openssl iproute util-linux ca-certificates
  else v6_error '请安装 jq curl openssl iproute2 util-linux'; fi
}
v6_addresses() {
  ip -o -6 addr show | awk '/inet6/ && !/tentative|dadfailed|deprecated/ {split($4,a,"/"); print a[1]}'
}
v6_detect() {
  local source address fallback=''
  source=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p' | head -1)
  while read -r address; do
    [[ "$address" =~ ^[23] ]] || continue
    if ip -o -6 addr show | grep -F " $address/" | grep -qw temporary; then fallback=${fallback:-$address}; continue; fi
    [ "$address" = "$source" ] && { echo "$address"; return; }
    fallback=${fallback:-$address}
  done < <(v6_addresses)
  [ -n "$fallback" ] && { echo "$fallback"; return; }
  return 1
}
v6_choose() {
  local answer=${1:-} result
  if [ -z "$answer" ]; then result=$(v6_detect) && { echo "$result"; return; }; fi
  while :; do
    if [ -n "$answer" ]; then
      if v6_addresses | grep -Fqx -- "$answer"; then echo "$answer"; return; fi
      echo '该 IPv6 不在本机可用网卡地址中。' >&2
      [ "$V6_INTERACTIVE" = 1 ] || return 1
    fi
    [ "$V6_INTERACTIVE" = 1 ] || { v6_error '未发现本机公网 IPv6；请用 --ipv6 指定已配置的本机地址。'; return 1; }
    echo '未发现公网 IPv6。当前本机地址：' >&2
    ip -6 addr show >&2
    read -r -p '填写本机 IPv6（0/回车取消；没有公网 IPv6 时请先在 VPS 控制台配置）: ' answer
    [ -n "$answer" ] && [ "$answer" != 0 ] || return 1
  done
}
v6_ready() {
  local choice
  v6_dependencies || return
  mkdir -p "$V6_HOME"; chmod 700 "$V6_HOME"
  if [ ! -x "$V6_CORE" ]; then
    if [ -x "$V6_HOME/bin/sing-box" ]; then cp "$V6_HOME/bin/sing-box" "$V6_CORE"
    elif [ -x "$V6_UPSTREAM/sing-box" ]; then cp "$V6_UPSTREAM/sing-box" "$V6_CORE"
    else
      choice=$V6_UPSTREAM_CHOICE
      if [ -z "$choice" ]; then read -r -p '未安装上游：1 安装官方脚本；2 独立使用（只下载核心）[2]: ' choice; fi
      if [[ "$choice" = 1 || "$choice" = install ]]; then
        curl -fL "$UPSTREAM_URL" -o "$V6_TMP/upstream.sh" || return
        bash "$V6_TMP/upstream.sh" || return
        [ -x "$V6_UPSTREAM/sing-box" ] || return 1
        cp "$V6_UPSTREAM/sing-box" "$V6_CORE"
      else
        local arch archive
        case $(uname -m) in x86_64) arch=amd64;; aarch64) arch=arm64;; *) v6_error '暂不支持此架构'; return 1;; esac
        archive=sing-box-1.15.0-alpha.13-linux-$arch
        curl -fL --connect-timeout 15 --max-time 180 "https://github.com/SagerNet/sing-box/releases/download/v1.15.0-alpha.13/$archive.tar.gz" -o "$V6_TMP/core.tgz" || return
        tar -xzf "$V6_TMP/core.tgz" -C "$V6_TMP" "$archive/sing-box" || return
        cp "$V6_TMP/$archive/sing-box" "$V6_CORE"
      fi
      chmod +x "$V6_CORE"
    fi
  fi
  "$V6_CORE" version >/dev/null || return
  if [[ "${BASH_SOURCE[0]}" = /dev/fd/* ]]; then
    curl -fL https://raw.githubusercontent.com/RNGCHEER/sbv6/main/sbv6.sh -o "$V6_TMP/self.sh" || return
    bash -n "$V6_TMP/self.sh" || return
    cp "$V6_TMP/self.sh" "$V6_HOME/sbv6.sh"
  elif [ "${BASH_SOURCE[0]}" != "$V6_HOME/sbv6.sh" ]; then cp "${BASH_SOURCE[0]}" "$V6_HOME/sbv6.sh" || return; fi
  printf '#!/bin/sh\nexec bash %q "$@"\n' "$V6_HOME/sbv6.sh" > /usr/local/bin/sbv6
  chmod +x /usr/local/bin/sbv6
}
v6_migrate() {
  [ -s "$V6_HOME/state.json" ] && [ ! -f "$V6_HOME/bash-migrated" ] || return 0
  local node family key tag index dir pub file
  while IFS= read -r node; do
    family=$(jq -r '.family' <<< "$node"); key=$(jq -r '.key' <<< "$node")
    [[ "$family" =~ ^[46]$ && "$key" =~ ^[b-n]$ ]] || return 1
    index=$(( $(printf '%d' "'$key") - 87 )); tag=${NODE_TAG[index-11]}
    dir="$V6_HOME/v$family"; mkdir -p "$dir/conf" "$dir/subscribe"
    ln -sf "$V6_CORE" "$dir/sing-box"; ln -sf "$(command -v jq)" "$dir/jq"
    if [ ! -d "$dir/cert" ]; then
      if [ -d "$V6_HOME/cert-v6" ]; then
        mkdir -p "$dir/cert"; cp "$V6_HOME/cert-v6/cert.pem" "$dir/cert/cert.pem"; cp "$V6_HOME/cert-v6/key.pem" "$dir/cert/private.key"
      else (WORK_DIR=$dir; ssl_certificate addons.mozilla.org); fi
    fi
    file="$dir/conf/${index}_${tag}_inbounds.json"
    pub=$(jq -r '.public_key // empty' <<< "$node")
    printf '// "public_key":"%s"\n' "$pub" > "$file"
    jq --arg family "$family" '{inbounds:(.inbound as $ib | ($ib|del(._inner)) as $main |
      if $ib._inner then [($main|.detour=("shadowtls-in-v"+$family)), ($ib._inner|.tag=("shadowtls-in-v"+$family))] else [$main] end)}' <<< "$node" |
      sed -E 's/^([[:space:]]*"[^"]+":) /\1/' >> "$file" || return
    jq -r '.host' <<< "$node" > "$dir/host"
  done < <(jq -c '.nodes[]' "$V6_HOME/state.json")
  jq -e '.follow == false' "$V6_HOME/state.json" >/dev/null && touch "$V6_HOME/independent"
  touch "$V6_HOME/bash-migrated"
}
v6_restart() {
  if [ -d /run/systemd/system ]; then systemctl restart sbv6 && systemctl is-active --quiet sbv6
  else rc-service sbv6 restart; fi
}
v6_service() {
  if [ -d /run/systemd/system ]; then
    cat > /etc/systemd/system/sbv6.service <<EOF
[Unit]
Description=sbv6 sing-box dual stack
After=network-online.target
[Service]
ExecStart=$V6_CORE run -c $V6_HOME/config.json
Restart=on-failure
RestartSec=5
UMask=0077
[Install]
WantedBy=multi-user.target
EOF
    printf '[Service]\nType=oneshot\nExecStart=/usr/local/bin/sbv6 -s\n' > /etc/systemd/system/sbv6-sync.service
    printf '[Timer]\nOnBootSec=30\nOnUnitActiveSec=60\n[Install]\nWantedBy=timers.target\n' > /etc/systemd/system/sbv6-sync.timer
    systemctl daemon-reload && systemctl enable sbv6 && systemctl enable --now sbv6-sync.timer
  else
    cat > /etc/init.d/sbv6 <<EOF
#!/sbin/openrc-run
command="$V6_CORE"
command_args="run -c $V6_HOME/config.json"
command_background=true
pidfile=/run/sbv6.pid
depend() { need net; }
EOF
    chmod +x /etc/init.d/sbv6; rc-update add sbv6 default
    mkdir -p /etc/periodic/1min
    printf '#!/bin/sh\n/usr/local/bin/sbv6 -s\n' > /etc/periodic/1min/sbv6
    chmod +x /etc/periodic/1min/sbv6
  fi
}
v6_merge() {
  local file files=()
  while IFS= read -r file; do files+=("$file"); done < <(find "$V6_HOME" -path '*/conf/*_inbounds.json' -type f | sort)
  if [ ${#files[@]} -gt 0 ]; then
    sed '/^[[:space:]]*\/\//d' "${files[@]}" | jq -s '{log:{level:"warn"},inbounds:[.[].inbounds[]],outbounds:[{type:"direct",tag:"direct"}]}' > "$V6_TMP/candidate.json"
  else echo '{"inbounds":[],"outbounds":[{"type":"direct"}]}' > "$V6_TMP/candidate.json"; fi
  "$V6_CORE" check -c "$V6_TMP/candidate.json" || return
  cmp -s "$V6_TMP/candidate.json" "$V6_HOME/config.json" && return 0
  [ ! -f "$V6_HOME/config.json" ] || cp "$V6_HOME/config.json" "$V6_TMP/previous.json"
  cp "$V6_TMP/candidate.json" "$V6_HOME/config.json"
  v6_restart || { [ ! -f "$V6_TMP/previous.json" ] || { cp "$V6_TMP/previous.json" "$V6_HOME/config.json"; v6_restart; }; return 1; }
}
v6_generate() (
  local family=$1 address=$2 keys=$3 port=$4 name=$5
  WORK_DIR="$V6_HOME/v$family"; mkdir -p "$WORK_DIR/conf" "$WORK_DIR/logs" "$WORK_DIR/subscribe"
  TEMP_DIR=$V6_TMP; L=C; TLS_SERVER=addons.mozilla.org; IS_BRUTAL=false
  ln -sf "$V6_CORE" "$WORK_DIR/sing-box"; ln -sf "$(command -v jq)" "$WORK_DIR/jq"
  [ -s "$WORK_DIR/cert/cert.pem" ] || ssl_certificate "$TLS_SERVER"
  INSTALL_PROTOCOLS=(); local key index p file upstream
  for ((index=0;index<${#keys};index++)); do INSTALL_PROTOCOLS+=("${keys:index:1}"); done
  START_PORT=$port; NODE_NAME_CONFIRM="$name IPv$family"; UUID_CONFIRM=$(cat /proc/sys/kernel/random/uuid)
  SERVER_IP=$address; VMESS_HOST_DOMAIN=addons.mozilla.org; VLESS_HOST_DOMAIN=addons.mozilla.org
  VMESS_WS_PATH="$UUID_CONFIRM-vmess"; VLESS_WS_PATH="$UUID_CONFIRM-vless"
  sing-box_json change || return
  for file in "$WORK_DIR"/conf/*_inbounds.json; do
    [ -f "$file" ] || continue
    p=$(sed '/^[[:space:]]*\/\//d' "$file" | jq -r '.inbounds[0].listen_port')
    upstream="$V6_UPSTREAM/conf/${file##*/}"
    if [ ! -f "$V6_HOME/independent" ] && [ -s "$upstream" ]; then
      cp "$upstream" "$file"
    fi
    # Preserve public-key and WS metadata comments used by upstream export_list.
    grep '^[[:space:]]*//' "$file" | sed "s/\(WS_SERVER_IP_SHOW\".*: *\)\".*\"/\1\"$address\"/" > "$V6_TMP/patch"
    sed '/^[[:space:]]*\/\//d' "$file" | jq --arg addr "$address" --arg suffix " IPv$family" --argjson p "$p" '
      .inbounds |= map(if .listen_port then .listen=$addr | .listen_port=$p else . end |
        .tag = (if .listen_port then (.tag | sub(" (?<p>[^ ]+)$"; $suffix+" "+.p)) else .tag+$suffix end) |
        if .detour then .detour += $suffix else . end)' | sed -E 's/^([[:space:]]*"[^"]+":) /\1/' >> "$V6_TMP/patch" || return
    mv "$V6_TMP/patch" "$file"
  done
  printf '%s\n' "$address" > "$WORK_DIR/host"
)
v6_export() (
  local family=$1
  WORK_DIR="$V6_HOME/v$family"; [ -d "$WORK_DIR/conf" ] || exit 0
  TEMP_DIR=$V6_TMP; L=C; IS_SUB=no_sub; IS_ARGO=no_argo; IS_BRUTAL=false
  SBV6_NATIVE_EXPORT=1
  DIR=$WORK_DIR
  echo '{"experimental":{"clash_api":{}}}' > "$WORK_DIR/conf/04_experimental.json"
  echo '{"outbounds":["<OUTBOUND_REPLACE>",{"type":"direct","tag":"direct"}]}' > "$TEMP_DIR/sing-box-template"
  check_install() { :; }; ensure_stats_data() { return 1; }
  eval "$(declare -f fetch_nodes_value | sed '1s/fetch_nodes_value/v6_original_fetch/')"
  fetch_nodes_value() { v6_original_fetch; SERVER_IP=$(cat "$WORK_DIR/host"); }
  # Tags must retain the upstream protocol suffix for its reader.
  export_list
)
v6_outputs() {
  v6_export 4; v6_export 6
  cat "$V6_HOME"/v[46]/nodes.txt 2>/dev/null > "$V6_HOME/nodes.txt"
  base64 -w0 "$V6_HOME/nodes.txt" > "$V6_HOME/subscription.txt"
  printf '\nBase64 订阅：\n'; cat "$V6_HOME/subscription.txt"; echo
}
v6_firewall() {
  local family cmd proto port
  [ -s "$V6_HOME/config.json" ] || return 0
  for family in 4 6; do
    [ "$family" = 4 ] && cmd=iptables || cmd=ip6tables
    command -v "$cmd" >/dev/null || continue
    v6_clear_firewall "$cmd"
    while read -r proto port; do
      "$cmd" -w -C INPUT -p "$proto" --dport "$port" -m comment --comment sbv6 -j ACCEPT 2>/dev/null ||
        "$cmd" -w -I INPUT 1 -p "$proto" --dport "$port" -m comment --comment sbv6 -j ACCEPT || return
    done < <(jq -r --argjson f "$family" '.inbounds[] | select(.listen_port and ((.listen|contains(":")) == ($f==6))) |
      . as $i | (if .type=="hysteria2" or .type=="tuic" then ["udp"] elif .type=="naive" or .type=="shadowsocks" then ["tcp","udp"] else ["tcp"] end)[] | .+" "+($i.listen_port|tostring)' "$V6_HOME/config.json")
  done
}
v6_clear_firewall() {
  local cmd=$1 line rule
  while IFS= read -r line; do
    [[ "$line" =~ --comment[[:space:]]+\"?sbv6\"?([[:space:]]|$) ]] || continue
    read -r -a rule <<< "${line//\"/}"
    "$cmd" -w -D "${rule[@]:1}" || return
  done < <("$cmd" -w -S INPUT 2>/dev/null)
}
v6_add() {
  local family=$1 addr keys=${V6_PROTOCOLS:-} port=${V6_PORT:-} name=${V6_NAME:-$(hostname)} f p max
  addr=$(v6_choose "$V6_ADDRESS") || return
  [ -n "$keys" ] || read -r -p '协议 b-n，a=全部 [a]: ' keys
  [ "${keys:-a}" != a ] || keys=bcdefghijklmn
  [[ "$keys" =~ ^[b-n]+$ ]] || { v6_error '协议字母无效'; return 1; }
  [ -n "$port" ] || read -r -p '起始端口 [35000]: ' port
  port=${port:-35000}; [[ "$port" =~ ^[0-9]+$ ]] && ((port>0 && port+${#keys}<65536)) || return 1
  # Conservatively skip any occupied block; a dual-stack pair may share each port.
  while :; do
    max=$((port+${#keys}-1)); p=$port
    while ((p<=max)); do
      if ss -H -lnut | awk '{print $5}' | grep -qE ":$p$"; then break; fi
      ((p++))
    done
    ((p>max)) && break
    port=$((p+1)); ((port+${#keys}<65536)) || return 1
  done
  rm -rf -- "$V6_TMP/backup6" "$V6_TMP/backup4"
  cp -a "$V6_HOME/v6" "$V6_TMP/backup6" 2>/dev/null || :
  cp -a "$V6_HOME/v4" "$V6_TMP/backup4" 2>/dev/null || :
  v6_generate 6 "$addr" "$keys" "$port" "$name" || { v6_restore; return 1; }
  if [ "$family" = both ]; then
    [ -n "$V6_IPV4" ] || read -r -p '公网 IPv4: ' V6_IPV4
    v6_generate 4 0.0.0.0 "$keys" "$port" "$name" || { v6_restore; return 1; }
    echo "$V6_IPV4" > "$V6_HOME/v4/host"
  fi
  v6_merge || {
    v6_restore
    return 1
  }
  if [ -n "$V6_ADDRESS" ] || ! v6_detect >/dev/null; then echo "$addr" > "$V6_HOME/manual-ipv6"; fi
  v6_firewall; v6_outputs
}
v6_restore() {
  local f
  for f in 4 6; do rm -rf -- "$V6_HOME/v$f"; [ ! -d "$V6_TMP/backup$f" ] || cp -a "$V6_TMP/backup$f" "$V6_HOME/v$f"; done
}
v6_sync() {
  local addr file
  [ -d "$V6_HOME/v6/conf" ] || return 0
  if [ -f "$V6_HOME/manual-ipv6" ]; then addr=$(v6_choose "$(cat "$V6_HOME/manual-ipv6")") || return
  else addr=$(v6_detect) || { v6_error '未发现公网 IPv6，保留现有配置；菜单 7 可手动选择。'; return 1; }; fi
  for file in "$V6_HOME"/v6/conf/*_inbounds.json; do
    grep '^[[:space:]]*//' "$file" > "$V6_TMP/patch"
    sed '/^[[:space:]]*\/\//d' "$file" | jq --arg a "$addr" '.inbounds |= map(if .listen_port then .listen=$a else . end)' | sed -E 's/^([[:space:]]*"[^"]+":) /\1/' >> "$V6_TMP/patch" || return
    mv "$V6_TMP/patch" "$file"
  done
  echo "$addr" > "$V6_HOME/v6/host"; v6_merge && v6_firewall
}
v6_main() {
  UPSTREAM_URL=https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh
  V6_INTERACTIVE=0; V6_UPSTREAM_CHOICE=''; V6_ADDRESS=''; V6_PROTOCOLS=''; V6_PORT=''; V6_NAME=''; V6_IPV4=''
  local action=menu choice file answer
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) echo 'sbv6 (Bash + jq): -a 添加V6 -b 双栈 -l 节点 -s 同步 -d 诊断 -i 安装 -u 卸载 --sb 上游菜单'; return;;
      -a) action=add;; -b) action=both;; -l) action=list;; -s) action=sync;; -d) action=diag;; -i) action=install;; -u) action=uninstall;;
      --ipv6) shift; V6_ADDRESS=$1;; --ipv4) shift; V6_IPV4=$1;; --protocols) shift; V6_PROTOCOLS=$1;; -p|--port) shift; V6_PORT=$1;; --name) shift; V6_NAME=$1;; --upstream) shift; V6_UPSTREAM_CHOICE=$1;;
      *) v6_error "未知参数 $1"; return 1;;
    esac; shift
  done
  [ "$(id -u)" = 0 ] || { v6_error '请以 root 运行'; return 1; }
  V6_TMP=$(mktemp -d /tmp/sbv6.XXXXXXXX); trap 'rm -rf -- "$V6_TMP"' EXIT
  if [ "$action" = diag ]; then v6_header; ip -6 addr; ip -6 route; return; fi
  mkdir -p "$V6_HOME"; chmod 700 "$V6_HOME"; exec 9>"$V6_HOME/.lock"; flock -x 9
  if [ "$action" = list ]; then v6_outputs; return; fi
  if [ "$action" = uninstall ]; then
    read -r -p '确认卸载 sbv6（不卸载上游）？[y/N]: ' answer; [ "$answer" = y ] || return 0
    local cmd; for cmd in iptables ip6tables; do command -v "$cmd" >/dev/null && v6_clear_firewall "$cmd"; done
    if [ -d /run/systemd/system ]; then systemctl disable --now sbv6 sbv6-sync.timer; rm -f /etc/systemd/system/sbv6{,-sync}.service /etc/systemd/system/sbv6-sync.timer; systemctl daemon-reload
    else rc-service sbv6 stop; rc-update del sbv6; rm -f /etc/init.d/sbv6 /etc/periodic/1min/sbv6; fi
    rm -rf -- "$V6_HOME"; rm -f /usr/local/bin/sbv6; return
  fi
  [ "$action" != sync ] || { v6_sync; return; }
  [ "$action" != menu ] || V6_INTERACTIVE=1
  v6_ready || return; v6_migrate || return; v6_service || return
  case "$action" in add) v6_add 6; return;; both) v6_add both; return;; install) return;; esac
  while :; do
    v6_header
    printf '\n1 上游原版菜单  2 添加IPv6  3 双栈添加  4 节点输出\n5 删除节点  6 同步  7 指定IPv6  8 状态  9 卸载\n10 安装/更新命令  11 参考/独立凭据  0 退出\n'
    read -r -p '选择: ' choice
    case "$choice" in
      0) return;; 1) bash "$V6_HOME/sbv6.sh" --sb;; 2) v6_add 6;; 3) v6_add both;; 4) v6_outputs;;
      5) local files=() i=0 id; mapfile -t files < <(find "$V6_HOME" -path '*/conf/*_inbounds.json' -type f | sort)
         for file in "${files[@]}"; do echo "$((++i)) ${file##*/}"; done
         read -r -p '删除编号（0取消）: ' id
         if [[ "$id" =~ ^[1-9][0-9]*$ ]] && ((id<=${#files[@]})); then
           read -r -p '确认删除？[y/N]: ' answer
           if [ "$answer" = y ]; then cp "${files[id-1]}" "$V6_TMP/deleted"; rm "${files[id-1]}"; if v6_merge; then v6_firewall; else cp "$V6_TMP/deleted" "${files[id-1]}"; fi; fi
         fi;;
      6) v6_sync;; 7) if answer=$(v6_choose); then echo "$answer" > "$V6_HOME/manual-ipv6"; v6_sync; fi;; 8) V6_NETWORK_FETCHED=0; v6_header; ss -lnut;;
      9) echo '退出后运行 sbv6 -u 卸载';; 10) v6_ready;;
      11) if [ -f "$V6_HOME/independent" ]; then rm "$V6_HOME/independent"; echo '参考上游凭据'; else touch "$V6_HOME/independent"; echo '独立凭据（下次生成生效）'; fi;;
    esac
  done
}
if [ "${1:-}" = --source-only ]; then return 0 2>/dev/null || exit 0; fi
if [ "${1:-}" = --sb ]; then shift; else v6_main "$@"; exit $?; fi

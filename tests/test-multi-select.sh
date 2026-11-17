#!/usr/bin/env bash
set -o pipefail
BASE=$(cd "$(dirname "$0")/.." && pwd)
set -- --source-only
source "$BASE/sbv6.sh"

V6_TMP=$(mktemp -d)
trap 'rm -rf -- "$V6_TMP"' EXIT
V6_HOME="$V6_TMP/state"
V6_UPSTREAM="$V6_TMP/no-upstream"
V6_CORE="$BASE/tests/bin/sing-box-1.15.0-alpha.13-linux-amd64/sing-box"
mkdir -p "$V6_HOME"
touch "$V6_HOME/independent"

# Exact regression from the interactive menu: cn = Hysteria2 + Snell v6.
v6_generate 6 ::1 cn 35000 '双协议测试'
v6_restart() { return 0; }
v6_merge
v6_export 6 > "$V6_TMP/display.log"

[[ $(find "$V6_HOME/v6/conf" -name '*_inbounds.json' -type f | wc -l) -eq 2 ]]
[[ $(jq '.inbounds | length' "$V6_HOME/config.json") -eq 2 ]]
grep -q '^hysteria2://' "$V6_HOME/v6/list"
grep -q '^snell://' "$V6_HOME/v6/list"
grep -q '^v2rayn://hysteria2/' "$V6_TMP/display.log"
grep -q '^v2rayn://snell/' "$V6_TMP/display.log"
[[ $(grep -Ec '^v2rayn://(hysteria2|snell)/' "$V6_TMP/display.log") -eq 2 ]]
grep -q 'IPv6 节点导出完成：2/2' "$V6_TMP/display.log"
grep -q 'hysteria2.*端口 35000' "$V6_TMP/display.log"
grep -q 'snell-v6.*端口 35001' "$V6_TMP/display.log"
[[ $(jq '[.outbounds[] | select(.type != "direct")] | length' "$V6_HOME/v6/subscribe/sing-box") -eq 2 ]]

echo 'PASS cn selection generates and exports both Hysteria2 and Snell v6'

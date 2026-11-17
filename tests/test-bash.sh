#!/usr/bin/env bash
set -o pipefail
BASE=$(cd "$(dirname "$0")/.." && pwd)
set -- --source-only
source "$BASE/sbv6.sh"
V6_TMP=$(mktemp -d); V6_HOME="$V6_TMP/state"; V6_UPSTREAM="$V6_TMP/no-upstream"
trap 'rm -rf -- "$V6_TMP"' EXIT
V6_CORE="$BASE/tests/bin/sing-box-1.15.0-alpha.13-linux-amd64/sing-box"
mkdir -p "$V6_HOME"; touch "$V6_HOME/independent"
if ! v6_generate 6 ::1 bcdefghijklmn 43500 'WSL测试'; then echo 'FAIL generate'; exit 1; fi
v6_restart() { return 0; }
v6_merge || exit 1
[ "$(jq '.inbounds|length' "$V6_HOME/config.json")" = 14 ] || exit 1
[ "$(jq '[.inbounds[].tag]|unique|length' "$V6_HOME/config.json")" = 14 ] || exit 1
"$V6_CORE" run -c "$V6_HOME/config.json" > "$V6_TMP/core.log" 2>&1 & pid=$!
sleep 1
if ! kill -0 "$pid"; then cat "$V6_TMP/core.log"; exit 1; fi
ss -lnut | grep 43500 || { kill "$pid"; exit 1; }
kill "$pid"; wait "$pid" 2>/dev/null
echo 'PASS Bash upstream generator: 13 protocols, 14 inbounds including ShadowTLS detour, real core check and IPv6 listeners'
v6_export 6 > "$V6_TMP/export.log" 2> "$V6_TMP/export.err"
if [ ! -s "$V6_HOME/v6/list" ] || ! grep -q 'snell://' "$V6_HOME/v6/list"; then cat "$V6_TMP/export.err"; echo 'FAIL export'; exit 1; fi
echo 'PASS native upstream multi-client node output'
"$V6_CORE" check -c "$V6_HOME/v6/subscribe/sing-box" || exit 1
echo 'PASS native upstream sing-box client output passes core check'
old_home=$V6_HOME
mkdir -p "$V6_TMP/migration"
jq '{follow:false,nodes:[(.inbounds[]|select(.type=="shadowsocks" and .listen_port)|{key:"f",family:6,host:"::1",inbound:.,public_key:""}),
  (. as $config|.inbounds[]|select(.type=="shadowtls")|. as $main|{key:"e",family:6,host:"::1",public_key:"",inbound:($main+{_inner:($config.inbounds[]|select(.tag==$main.detour))})})]}' "$V6_HOME/config.json" > "$V6_TMP/migration/state.json"
V6_HOME="$V6_TMP/migration"
v6_migrate || exit 1
v6_merge || exit 1
[ "$(jq '.inbounds|length' "$V6_HOME/config.json")" = 3 ] || exit 1
echo 'PASS legacy JSON migration including ShadowTLS detour and existing credentials'
V6_HOME=$old_home
v6_addresses() { printf '%s\n' fe80::1 2606:4700::1; }
V6_INTERACTIVE=0
[ "$(v6_choose 2606:4700::1)" = 2606:4700::1 ] || exit 1
if v6_choose 2606:4700::2; then echo 'FAIL unassigned accepted'; exit 1; fi
v6_detect() { return 1; }
V6_INTERACTIVE=1
[ "$(v6_choose <<< '2606:4700::1')" = 2606:4700::1 ] || exit 1
if v6_choose <<< 0; then echo 'FAIL cancellation'; exit 1; fi
echo 'PASS Bash IPv6 manual selection, unassigned rejection, missing IPv6 and cancellation'

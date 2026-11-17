#!/usr/bin/env bash
set -eo pipefail
BASE=$(cd "$(dirname "$0")/.." && pwd)
set -- --source-only
source "$BASE/sbv6.sh"
V6_TMP=$(mktemp -d); trap 'rm -rf -- "$V6_TMP"' EXIT
V6_HOME="$V6_TMP/state"; V6_UPSTREAM="$V6_TMP/no-upstream"
V6_CORE="$BASE/tests/bin/sing-box-1.15.0-alpha.13-linux-amd64/sing-box"
mkdir -p "$V6_HOME"; touch "$V6_HOME/independent"
V6_NETWORK_FETCHED=1; V6_PUBLIC4=198.51.100.42; V6_IPINFO4=ISP
V6_PUBLIC6=2001:df4:3d40:0:f816:3eff:fef0:4051; V6_IPINFO6=ISP
V6_INTERACTIVE=0; V6_ADDRESS=''; V6_IPV4=''; V6_PROTOCOLS=f; V6_PORT=44900; V6_NAME=auto
v6_addresses() { printf '%s\n' fd00::1266:6aff:fe63:20b2 fe80::1; }
ip() { echo '2606:4700:4700::1111 dev eth0 src fd00::1266:6aff:fe63:20b2'; }
v6_resolve_address 6
[[ "$V6_SELECTED_HOST" = "$V6_PUBLIC6" && "$V6_SELECTED_BIND" = fd00::1266:6aff:fe63:20b2 ]]
v6_resolve_address 6 "$V6_PUBLIC6"
[[ "$V6_SELECTED_BIND" = fd00::1266:6aff:fe63:20b2 ]]
echo 'PASS screenshot case: public IPv6 auto-filled; ULA route source used for binding; same manual public input accepted'
if v6_resolve_address 6 2001:4860::1234; then echo 'FAIL unrelated address accepted'; exit 1; fi
v6_resolve_address 4
[[ "$V6_SELECTED_HOST" = 198.51.100.42 && "$V6_SELECTED_BIND" = 0.0.0.0 ]]
echo 'PASS IPv4 WAN auto-fill without IPv6 dependency'
# Exercise native generation with real loopback binding and a separate advertised WAN.
v6_addresses() { echo ::1; }
ip() { echo '2606:4700:4700::1111 dev lo src ::1'; }
v6_restart() { :; }; v6_firewall() { :; }
v6_add 6 </dev/null > "$V6_TMP/output" || { cat "$V6_TMP/output"; exit 1; }
jq -e '.inbounds[0].listen == "::1"' "$V6_HOME/config.json" >/dev/null
[[ $(cat "$V6_HOME/v6/host") = "$V6_PUBLIC6" ]]
jq -e --arg h "$V6_PUBLIC6" 'any(.outbounds[]; .server==$h)' "$V6_HOME/v6/subscribe/sing-box" >/dev/null
"$V6_CORE" check -c "$V6_HOME/config.json"
V6_PORT=44910; v6_add 4 </dev/null > "$V6_TMP/output4" || { cat "$V6_TMP/output4"; exit 1; }
[[ $(cat "$V6_HOME/v4/host") = "$V6_PUBLIC4" ]]
jq -e 'any(.inbounds[]; .listen=="0.0.0.0")' "$V6_HOME/config.json" >/dev/null
echo 'PASS noninteractive V6 and V4 additions: core config binds locally, native client output advertises detected WAN'
V6_PUBLIC6=2001:df4:3d40:0:f816:3eff:fef0:4052
v6_sync || exit 1
[[ $(cat "$V6_HOME/v6/host") = "$V6_PUBLIC6" ]]
jq -e '.inbounds[] | select(.type=="shadowsocks" and (.tag|contains("IPv6"))) | .listen=="::1"' "$V6_HOME/config.json" >/dev/null
echo 'PASS synchronization updates advertised public IPv6 separately from local binding'

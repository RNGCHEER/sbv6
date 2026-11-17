#!/usr/bin/env bash
set -euo pipefail
BASE=$(cd "$(dirname "$0")/.." && pwd)
set -- --source-only
source "$BASE/sbv6.sh"
V6_TMP=$(mktemp -d); trap 'rm -rf -- "$V6_TMP"' EXIT
v6_probe_ip() {
  echo "$1" >> "$V6_TMP/probes"
  if [ "$1" = 4 ]; then echo '{"ip":"198.51.100.42","country":"测试地区","isp":"测试 ISP"}' > "$V6_TMP/ip4.json"; fi
}
ip() {
  if [[ "$*" = *'-6'* ]]; then echo '2: eth0 inet6 fd00::123/64 scope global'; fi
}
v6_network_info
[[ "$V6_PUBLIC4" = 198.51.100.42 && "$V6_IPINFO4" = '测试地区  测试 ISP' ]]
[[ "$V6_PUBLIC6" = fd00::123 && "$V6_IPINFO6" = *本机地址* ]]
v6_network_info
[[ $(wc -l < "$V6_TMP/probes") = 2 ]]
echo 'PASS public IPv4 metadata, IPv6 local fallback label and menu cache'
V6_CORE=/does/not/exist; V6_UPSTREAM=/does/not/exist
v6_header > "$V6_TMP/header.txt"
grep -q 'IPv4：198.51.100.42' "$V6_TMP/header.txt"
grep -q 'IPv6：fd00::123' "$V6_TMP/header.txt"
grep -q 'sbv6 Sing-box：未安装' "$V6_TMP/header.txt"
echo 'PASS unavailable service shown as not installed'
cat "$V6_TMP/header.txt"

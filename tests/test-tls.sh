#!/usr/bin/env bash
set -o pipefail
BASE=$(cd "$(dirname "$0")/.." && pwd)
set -- --source-only
source "$BASE/sbv6.sh"
V6_TMP=$(mktemp -d); V6_HOME="$V6_TMP/state"; V6_UPSTREAM="$V6_TMP/no-upstream"
V6_CORE="$BASE/tests/bin/sing-box-1.15.0-alpha.13-linux-amd64/sing-box"
pids=()
cleanup() { for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || :; done; rm -rf -- "$V6_TMP"; }
trap cleanup EXIT
mkdir -p "$V6_HOME"; touch "$V6_HOME/independent"
v6_restart() { return 0; }; v6_firewall() { return 0; }
v6_generate 6 ::1 glm 45510 TLS || exit 1
# Simulate follow mode pointing at another certificate and SNI.
( WORK_DIR="$V6_TMP/upstream-cert"; ssl_certificate trojan.example ) || exit 1
file="$V6_HOME/v6/conf/16_trojan_inbounds.json"
jq --arg d "$V6_TMP/upstream-cert/cert" '.inbounds[0].tls |= (.server_name="trojan.example"|.certificate_path=($d+"/cert.pem")|.key_path=($d+"/private.key"))' "$file" |
  sed -E 's/^([[:space:]]*"[^"]+":) /\1/' > "$V6_TMP/trojan.json"
mv "$V6_TMP/trojan.json" "$file"
v6_merge || exit 1
v6_export 6 > "$V6_TMP/export.log" || exit 1
client="$V6_HOME/v6/subscribe/sing-box"
expected=$(openssl x509 -in "$V6_TMP/upstream-cert/cert/cert.pem" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64)
jq -e --arg pin "$expected" 'any(.outbounds[]; .type=="trojan" and .tls.server_name=="trojan.example" and .tls.certificate_public_key_sha256==[$pin] and (.tls.insecure!=true))' "$client" >/dev/null || exit 1
jq -e 'any(.outbounds[]; .type=="anytls" and .tls.server_name=="addons.mozilla.org" and (.tls.insecure!=true))' "$client" >/dev/null || exit 1
"$V6_CORE" check -c "$client" || exit 1
echo 'PASS mixed certificate sources: each protocol exports its actual SNI and SPKI pin without insecure=true'
"$V6_CORE" run -c "$V6_HOME/config.json" > "$V6_TMP/server.log" 2>&1 & pids+=("$!")
openssl s_server -accept 127.0.0.1:45600 -cert "$V6_TMP/upstream-cert/cert/cert.pem" -key "$V6_TMP/upstream-cert/cert/private.key" -www -quiet > "$V6_TMP/http.log" 2>&1 & pids+=("$!")
jq '{inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:45599}],outbounds:[.outbounds[]|select(.type=="trojan")]}' "$client" > "$V6_TMP/socks.json"
"$V6_CORE" run -c "$V6_TMP/socks.json" > "$V6_TMP/client.log" 2>&1 & pids+=("$!")
sleep 1
curl -q -kfSs --noproxy '' --max-time 8 --socks5-hostname 127.0.0.1:45599 https://127.0.0.1:45600 > "$V6_TMP/body" || { cat "$V6_TMP/client.log"; exit 1; }
grep -q 's_server' "$V6_TMP/body" || exit 1
echo 'PASS real IPv6 Trojan TLS handshake using exported SPKI pin; curl -k applies only to the local HTTPS test destination'
# Exercise the upstream TLS management menu, isolated to this address family.
v6_tls_manage 6 <<< $'1\nchanged.example' > "$V6_TMP/manage.log" || { cat "$V6_TMP/manage.log"; exit 1; }
v6_export 6 > "$V6_TMP/updated-export.log" || exit 1
jq -e 'all(.outbounds[]|select(.type=="trojan" or .type=="anytls" or .type=="naive"); .tls.server_name=="changed.example")' "$client" >/dev/null || { cat "$V6_TMP/manage.log"; exit 1; }
echo 'PASS upstream change_config SNI management regenerates certificates and synchronizes client output'
v6_tls_manage 6 <<< $'2\n2' > "$V6_TMP/fingerprint.log" || exit 1
v6_export 6 > "$V6_TMP/fingerprint-export.log" || exit 1
jq -e 'all(.outbounds[]|select(.type=="trojan" or .type=="anytls"); .tls.utls.fingerprint=="firefox")' "$client" >/dev/null || exit 1
echo 'PASS upstream client-fingerprint management persists across subsequent exports'
before=$(sha256sum "$V6_HOME/v6/cert/cert.pem" | awk '{print $1}')
v6_restart() { return 1; }
if v6_tls_manage 6 <<< $'1\nrollback.example' > "$V6_TMP/rollback.log" 2>&1; then echo 'FAIL rejected restart reported success'; exit 1; fi
after=$(sha256sum "$V6_HOME/v6/cert/cert.pem" | awk '{print $1}')
[ "$before" = "$after" ] || exit 1
v6_restart() { return 0; }
echo 'PASS rejected TLS change restores prior certificate and node configuration'
openssl x509 -checkend $((199*86400)) -noout -in "$V6_HOME/v6/cert/cert_200.pem" >/dev/null || exit 1
echo 'PASS Naive certificate uses the upstream 200-day certificate lifecycle'
openssl x509 -in "$V6_HOME/v6/cert/cert_200.pem" -not_before 20200101000000Z -not_after 20200102000000Z -signkey "$V6_HOME/v6/cert/private.key" -out "$V6_TMP/expired.pem" || exit 1
file="$V6_HOME/v6/conf/22_naive_inbounds.json"
jq --arg cert "$V6_TMP/expired.pem" '.inbounds[0].tls.certificate_path=$cert' "$file" | sed -E 's/^([[:space:]]*"[^"]+":) /\1/' > "$V6_TMP/expired-config.json"
mv "$V6_TMP/expired-config.json" "$file"
v6_export 6 > "$V6_TMP/renewed-export.log" || exit 1
renewed=$(jq -r '.inbounds[0].tls.certificate_path' "$file")
openssl x509 -checkend $((199*86400)) -noout -in "$renewed" >/dev/null || exit 1
echo 'PASS expired Naive certificate renewed by upstream ssl_certificate without overwriting its original source'
v6_tls_manage 6 nodes <<< $'3\nManaged IPv6' > "$V6_TMP/name.log" || { cat "$V6_TMP/name.log"; exit 1; }
jq -e 'all(.inbounds[]; .tag|startswith("Managed IPv6"))' "$V6_HOME/config.json" >/dev/null || exit 1
v6_tls_manage 6 nodes <<< $'5\n2001:db8::10' > "$V6_TMP/address.log" || { cat "$V6_TMP/address.log"; exit 1; }
[[ $(cat "$V6_HOME/v6/host") = 2001:db8::10 ]] || exit 1
jq -e 'all(.inbounds[]; .listen=="::1")' "$V6_HOME/config.json" >/dev/null || exit 1
echo 'PASS native node management edits node names and advertised addresses while preserving container binding'
v6_tls_manage 6 nodes <<< $'2\n1\n45530\ny' > "$V6_TMP/ports.log" || { cat "$V6_TMP/ports.log"; exit 1; }
jq -e '[.inbounds[].listen_port]|min==45530' "$V6_HOME/config.json" >/dev/null || { cat "$V6_TMP/ports.log"; exit 1; }
echo 'PASS native node management changes listening ports with upstream mode selection and confirmation'

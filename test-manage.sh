#!/usr/bin/env bash
# Functional test for uninstall / restore / switch in the candies-sb menu.
# Sandbox dir + fake sing-box; never touches /etc/sing-box or the real service.
# Covers: uninstall with credential backup, restore with identical creds,
#         switch AnyTLS Reality<->TLS (port/user/pass preserved),
#         HY2 obfs toggle, and regression that HY2 is untouched by uninstalls.
set -u
T=/tmp/sb-test-manage
rm -rf "$T"
mkdir -p "$T/etc/sing-box" "$T/bin"

# ---------- fake sing-box ----------
cat > "$T/bin/sing-box" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = "check" ]; then
  shift
  f=""
  while [ $# -gt 0 ]; do case "$1" in -c) f="$2"; shift 2;; *) shift;; esac; done
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null
  exit $?
fi
if [ "$1" = "generate" ] && [ "$2" = "reality-keypair" ]; then
  echo "PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  echo "PublicKey: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
  exit 0
fi
if [ "$1" = "generate" ] && [ "$2" = "rand" ]; then
  echo "0123456789abcdef"
  exit 0
fi
echo "fake sing-box: unknown args $*" >&2
exit 1
FAKE
chmod +x "$T/bin/sing-box"
export PATH="$T/bin:$PATH"

# ---------- extract menu from install.sh, rewrite paths to sandbox ----------
START=$(grep -n "<<'SB_SCRIPT'" ~/workspace/candies-sing-box/install.sh | head -n1 | cut -d: -f1)
END=$(grep -n '^SB_SCRIPT$' ~/workspace/candies-sing-box/install.sh | head -n1 | cut -d: -f1)
sed -n "$((START+1)),$((END-1))p" ~/workspace/candies-sing-box/install.sh \
  | sed "s|/etc/sing-box|$T/etc/sing-box|g; s|/root/node_names.txt|$T/node_names.txt|g" \
  > "$T/candies-sb-test"
bash -n "$T/candies-sb-test" || { echo "FAIL: test menu syntax"; exit 1; }
echo "-test" > "$T/node_names.txt"

PASS=0; FAIL=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS: $label"; PASS=$((PASS+1));
  else echo "FAIL: $label"; FAIL=$((FAIL+1)); fi
}
jqeq() {
  local label="$1" expr="$2" expected="$3" file="$4"
  local got
  got=$(jq -r "$expr" "$file" 2>/dev/null)
  if [ "$got" = "$expected" ]; then echo "PASS: $label"; PASS=$((PASS+1));
  else echo "FAIL: $label (got '$got', want '$expected')"; FAIL=$((FAIL+1)); fi
}
run_menu() { printf '%s\n' "$@" | bash "$T/candies-sb-test" 2>&1; }
CFG="$T/etc/sing-box/config.json"
PROTO="$T/etc/sing-box/.protocols"
CACHE="$T/etc/sing-box/.config_cache"
REMOVED="$T/etc/sing-box/.removed"

# ---------- base config: HY2 + AnyTLS Reality + AnyTLS TLS (live HK box) ----------
setup_base() {
cat > "$CFG" <<'JSON'
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 59999,
      "users": [{"password": "HY2OLDPASS"}],
      "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "/etc/sing-box/certs/fullchain.pem", "key_path": "/etc/sing-box/certs/privkey.pem"}
    },
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": 60000,
      "users": [{"name": "abcd1234", "password": "ANYTLSOLDPASS"}],
      "padding_scheme": [],
      "tls": {"enabled": true, "server_name": "addons.mozilla.org", "reality": {"enabled": true, "handshake": {"server": "addons.mozilla.org", "server_port": 443}, "private_key": "REALITYPKAAA", "short_id": ["7c925f33cf0a782c"]}}
    },
    {
      "type": "anytls",
      "tag": "anytls-tls-in",
      "listen": "::",
      "listen_port": 8443,
      "users": [{"name": "a5e9dc5c", "password": "TLSOLDPASS"}],
      "padding_scheme": [],
      "tls": {"enabled": true, "server_name": "www.bing.com", "certificate_path": "/etc/sing-box/certs/fullchain.pem", "key_path": "/etc/sing-box/certs/privkey.pem"}
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct-out"}]
}
JSON
cat > "$PROTO" <<'EOF'
ENABLE_SS=false
ENABLE_HY2=true
ENABLE_TUIC=false
ENABLE_REALITY=false
ENABLE_ANYTLS=true
ENABLE_VLESS_TLS=false
ENABLE_ANYTLS_TLS=true
EOF
cat > "$CACHE" <<'EOF'
ENABLE_SS=false
ENABLE_HY2=true
ENABLE_TUIC=false
ENABLE_REALITY=false
ENABLE_ANYTLS=true
ENABLE_VLESS_TLS=false
ENABLE_ANYTLS_TLS=true
HY2_PORT=59999
HY2_PSK=HY2OLDPASS
HY2_OBFS=none
HY2_OBFS_PSK=
ANYTLS_PORT=60000
ANYTLS_USER=abcd1234
ANYTLS_PSK=ANYTLSOLDPASS
ANYTLS_TLS_PORT=8443
ANYTLS_TLS_USER=a5e9dc5c
ANYTLS_TLS_PSK=TLSOLDPASS
REALITY_PK=REALITYPKAAA
REALITY_SID=7c925f33cf0a782c
REALITY_PUB=REALITYPUBAAA
REALITY_SNI=addons.mozilla.org
CUSTOM_IP=
EOF
rm -rf "$REMOVED"
}

# Menu layout for base (no backups): 4 add, 5 uninstall, 6 switch,
# 7 reset HY2, 8 reset AnyTLS Reality, 9 reset AnyTLS TLS, 10 start...
# With backups present: 6 restore, 7 switch, 8 reset HY2, 9 reset AnyTLS Reality, 10 reset AnyTLS TLS.

# ---------- Test 1: uninstall AnyTLS Reality (60000) ----------
setup_base
echo "=== Test 1: uninstall AnyTLS Reality ==="
OUT1=$(run_menu 5 2 0)
echo "$OUT1" | grep -q "已卸载 AnyTLS Reality" && { echo "PASS: 1 shows uninstalled"; PASS=$((PASS+1)); } || { echo "FAIL: 1 shows uninstalled"; FAIL=$((FAIL+1)); }
jqeq "1 inbound count = 2" '.inbounds | length' 2 "$CFG"
check "1 anytls-in gone" bash -c "! jq -e '.inbounds[] | select(.tag==\"anytls-in\")' \"$CFG\" >/dev/null"
jqeq "1 hy2 untouched" '.inbounds[] | select(.tag=="hy2-in") | .users[0].password' "HY2OLDPASS" "$CFG"
jqeq "1 anytls-tls untouched" '.inbounds[] | select(.tag=="anytls-tls-in") | .listen_port' 8443 "$CFG"
check "1 backup file exists" test -f "$REMOVED/anytls-in.json"
jqeq "1 backup port" '.inbound.listen_port' 60000 "$REMOVED/anytls-in.json"
jqeq "1 backup user" '.inbound.users[0].name' "abcd1234" "$REMOVED/anytls-in.json"
jqeq "1 backup pass" '.inbound.users[0].password' "ANYTLSOLDPASS" "$REMOVED/anytls-in.json"
jqeq "1 backup cache pass" '.cache.ANYTLS_PSK' "ANYTLSOLDPASS" "$REMOVED/anytls-in.json"
jqeq "1 backup reality pk" '.cache.REALITY_PK' "REALITYPKAAA" "$REMOVED/anytls-in.json"
check "1 .protocols ENABLE_ANYTLS=false" grep -q '^ENABLE_ANYTLS=false$' "$PROTO"
check "1 uris has no anytls reality" bash -c "! grep -q 'security=reality' \"$T/etc/sing-box/uris.txt\""
check "1 uris still has hy2" grep -q 'hy2://' "$T/etc/sing-box/uris.txt"

# ---------- Test 2: restore AnyTLS Reality (identical creds) ----------
echo "=== Test 2: restore AnyTLS Reality ==="
# menu now: 6 restore (backups exist), 7 switch
OUT2=$(run_menu 6 1 0)
echo "$OUT2" | grep -q "已恢复 AnyTLS Reality" && { echo "PASS: 2 shows restored"; PASS=$((PASS+1)); } || { echo "FAIL: 2 shows restored"; FAIL=$((FAIL+1)); }
jqeq "2 inbound count = 3" '.inbounds | length' 3 "$CFG"
jqeq "2 restored port" '.inbounds[] | select(.tag=="anytls-in") | .listen_port' 60000 "$CFG"
jqeq "2 restored user" '.inbounds[] | select(.tag=="anytls-in") | .users[0].name' "abcd1234" "$CFG"
jqeq "2 restored pass" '.inbounds[] | select(.tag=="anytls-in") | .users[0].password' "ANYTLSOLDPASS" "$CFG"
jqeq "2 restored reality pk" '.inbounds[] | select(.tag=="anytls-in") | .tls.reality.private_key' "REALITYPKAAA" "$CFG"
jqeq "2 restored reality sid" '.inbounds[] | select(.tag=="anytls-in") | .tls.reality.short_id[0]' "7c925f33cf0a782c" "$CFG"
check "2 backup file removed" test '!' -f "$REMOVED/anytls-in.json"
check "2 .protocols ENABLE_ANYTLS=true" grep -q '^ENABLE_ANYTLS=true$' "$PROTO"
check "2 uris has anytls reality" grep -q 'security=reality' "$T/etc/sing-box/uris.txt"

# ---------- Test 3: switch AnyTLS Reality -> AnyTLS TLS (fresh base, TLS removed first) ----------
echo "=== Test 3: switch AnyTLS Reality -> AnyTLS TLS ==="
setup_base
# remove the TLS variant from base so switch target is free
jq 'del(.inbounds[] | select(.tag=="anytls-tls-in"))' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
sed -i 's/^ENABLE_ANYTLS_TLS=true$/ENABLE_ANYTLS_TLS=false/' "$PROTO"
sed -i 's/^ENABLE_ANYTLS_TLS=true$/ENABLE_ANYTLS_TLS=false/; /^ANYTLS_TLS_PORT=/d; /^ANYTLS_TLS_USER=/d; /^ANYTLS_TLS_PSK=/d' "$CACHE"
# menu: 4 add, 5 uninstall, 6 switch, 7 reset HY2, 8 reset AnyTLS Reality
# switch list: 1) AnyTLS Reality -> TLS, 2) HY2 obfs
OUT3=$(run_menu 6 1 0)
echo "$OUT3" | grep -q "已切换：AnyTLS Reality → AnyTLS TLS" && { echo "PASS: 3 shows switched"; PASS=$((PASS+1)); } || { echo "FAIL: 3 shows switched"; FAIL=$((FAIL+1)); }
jqeq "3 inbound count = 2" '.inbounds | length' 2 "$CFG"
check "3 anytls-in gone" bash -c "! jq -e '.inbounds[] | select(.tag==\"anytls-in\")' \"$CFG\" >/dev/null"
jqeq "3 tls port preserved" '.inbounds[] | select(.tag=="anytls-tls-in") | .listen_port' 60000 "$CFG"
jqeq "3 tls user preserved" '.inbounds[] | select(.tag=="anytls-tls-in") | .users[0].name' "abcd1234" "$CFG"
jqeq "3 tls pass preserved" '.inbounds[] | select(.tag=="anytls-tls-in") | .users[0].password' "ANYTLSOLDPASS" "$CFG"
jqeq "3 tls is cert not reality" '.inbounds[] | select(.tag=="anytls-tls-in") | .tls.server_name' "www.bing.com" "$CFG"
check "3 .protocols flags flipped" bash -c "grep -q '^ENABLE_ANYTLS=false$' \"$PROTO\" && grep -q '^ENABLE_ANYTLS_TLS=true$' \"$PROTO\""
check "3 uris has tls link" grep -q 'security=tls' "$T/etc/sing-box/uris.txt"
check "3 uris no reality link" bash -c "! grep -q 'security=reality' \"$T/etc/sing-box/uris.txt\""

# ---------- Test 4: switch AnyTLS TLS -> AnyTLS Reality (back, keys reused) ----------
echo "=== Test 4: switch AnyTLS TLS -> AnyTLS Reality ==="
# state: HY2 + AnyTLS TLS (port 60000). menu: 6 switch; list: 1) TLS -> Reality, 2) HY2 obfs
OUT4=$(run_menu 6 1 0)
echo "$OUT4" | grep -q "已切换：AnyTLS TLS → AnyTLS Reality" && { echo "PASS: 4 shows switched back"; PASS=$((PASS+1)); } || { echo "FAIL: 4 shows switched back"; FAIL=$((FAIL+1)); }
jqeq "4 reality port preserved" '.inbounds[] | select(.tag=="anytls-in") | .listen_port' 60000 "$CFG"
jqeq "4 reality user preserved" '.inbounds[] | select(.tag=="anytls-in") | .users[0].name' "abcd1234" "$CFG"
jqeq "4 reality pass preserved" '.inbounds[] | select(.tag=="anytls-in") | .users[0].password' "ANYTLSOLDPASS" "$CFG"
check "4 reality pk reused (fake key from existing)" bash -c "jq -r '.inbounds[] | select(.tag==\"anytls-in\") | .tls.reality.private_key' \"$CFG\" | grep -q REALITYPKAAA"
check "4 .protocols flags flipped back" bash -c "grep -q '^ENABLE_ANYTLS=true$' \"$PROTO\" && grep -q '^ENABLE_ANYTLS_TLS=false$' \"$PROTO\""

# ---------- Test 5: HY2 obfs toggle (none -> salamander -> none) ----------
echo "=== Test 5: HY2 obfs toggle ==="
# state: HY2 + AnyTLS Reality. switch list: 1) AnyTLS Reality -> TLS, 2) HY2 obfs
OUT5=$(run_menu 6 2 0)
echo "$OUT5" | grep -q "加上 salamander" && { echo "PASS: 5 obfs added"; PASS=$((PASS+1)); } || { echo "FAIL: 5 obfs added"; FAIL=$((FAIL+1)); }
jqeq "5 hy2 obfs type" '.inbounds[] | select(.tag=="hy2-in") | .obfs.type' "salamander" "$CFG"
check "5 cache HY2_OBFS=salamander" grep -q '^HY2_OBFS=salamander$' "$CACHE"
check "5 uris has obfs" grep -q 'obfs=salamander' "$T/etc/sing-box/uris.txt"
OUT5b=$(run_menu 6 2 0)
echo "$OUT5b" | grep -q "去掉 salamander" && { echo "PASS: 5b obfs removed"; PASS=$((PASS+1)); } || { echo "FAIL: 5b obfs removed"; FAIL=$((FAIL+1)); }
check "5b hy2 obfs gone" bash -c "! jq -e '.inbounds[] | select(.tag==\"hy2-in\") | .obfs' \"$CFG\" >/dev/null"
check "5b cache HY2_OBFS=none" grep -q '^HY2_OBFS=none$' "$CACHE"

# ---------- Test 6: uninstall BOTH AnyTLS variants, restore one ----------
echo "=== Test 6: uninstall both AnyTLS, restore TLS only ==="
setup_base
OUT6=$(run_menu 5 "2 3" 0)
jqeq "6 inbound count = 1 (only HY2)" '.inbounds | length' 1 "$CFG"
check "6 backup anytls-in exists" test -f "$REMOVED/anytls-in.json"
check "6 backup anytls-tls-in exists" test -f "$REMOVED/anytls-tls-in.json"
check "6 .protocols both false" bash -c "grep -q '^ENABLE_ANYTLS=false$' \"$PROTO\" && grep -q '^ENABLE_ANYTLS_TLS=false$' \"$PROTO\""
# restore menu: 6 restore; list: 1) AnyTLS Reality, 2) AnyTLS TLS -> pick 2
OUT6b=$(run_menu 6 2 0)
jqeq "6b inbound count = 2" '.inbounds | length' 2 "$CFG"
jqeq "6b tls restored port" '.inbounds[] | select(.tag=="anytls-tls-in") | .listen_port' 8443 "$CFG"
jqeq "6b tls restored pass" '.inbounds[] | select(.tag=="anytls-tls-in") | .users[0].password' "TLSOLDPASS" "$CFG"
check "6b tls backup removed" test '!' -f "$REMOVED/anytls-tls-in.json"
check "6b reality backup still there" test -f "$REMOVED/anytls-in.json"
check "6b hy2 still fine" bash -c "jq -e '.inbounds[] | select(.tag==\"hy2-in\")' \"$CFG\" >/dev/null"

echo ""
echo "=========================="
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" = "0" ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $((FAIL > 0))

#!/usr/bin/env bash
# Functional test for protocol VARIANTS in the add-protocol menu.
# Uses a sandbox dir + fake sing-box; never touches /etc/sing-box or the real service.
# Covers: VLESS TLS, VLESS XHTTP, AnyTLS TLS, HY2 salamander obfs, TUIC congestion,
#         SS cipher choices, tag-based reset, and regression of Reality/AnyTLS reuse.
set -u
T=/tmp/sb-test-variants
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

# ---------- extract menu from the NEW install.sh, rewrite paths to sandbox ----------
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

# ---------- base config: HY2 + AnyTLS Reality (mirrors the live HK box) ----------
setup_base() {
cat > "$T/etc/sing-box/config.json" <<'JSON'
{
  "log": {"level": "info", "timestamp": true},
  "ntp": {"enabled": true, "server": "time.apple.com", "server_port": 123, "interval": "30m"},
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
      "tls": {
        "enabled": true,
        "server_name": "addons.mozilla.org",
        "reality": {
          "enabled": true,
          "handshake": {"server": "addons.mozilla.org", "server_port": 443},
          "private_key": "ORIGINAL_PRIVATE_KEY_AAAAAAAAAAAAAAAAAAAAAAAAAAA=",
          "short_id": ["abcdef0123456789"]
        }
      }
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct-out"}]
}
JSON
cat > "$T/etc/sing-box/.protocols" <<'EOF'
ENABLE_SS=false
ENABLE_HY2=true
ENABLE_TUIC=false
ENABLE_REALITY=false
ENABLE_ANYTLS=true
ENABLE_VLESS_TLS=false
ENABLE_VLESS_XHTTP=false
ENABLE_ANYTLS_TLS=false
EOF
cat > "$T/etc/sing-box/.config_cache" <<'EOF'
ENABLE_SS=false
ENABLE_HY2=true
ENABLE_TUIC=false
ENABLE_REALITY=false
ENABLE_ANYTLS=true
ENABLE_VLESS_TLS=false
ENABLE_VLESS_XHTTP=false
ENABLE_ANYTLS_TLS=false
HY2_PORT=59999
HY2_PSK=HY2OLDPASS
HY2_OBFS=none
ANYTLS_PORT=60000
ANYTLS_USER=abcd1234
ANYTLS_PSK=ANYTLSOLDPASS
REALITY_PK=ORIGINAL_PRIVATE_KEY_AAAAAAAAAAAAAAAAAAAAAAAAAAA=
REALITY_SID=abcdef0123456789
REALITY_PUB=ORIGINAL_PUBLIC_KEY_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
REALITY_SNI=addons.mozilla.org
CUSTOM_IP=203.0.113.10
EOF
printf 'ORIGINAL_PUBLIC_KEY_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=' > "$T/etc/sing-box/.reality_pub"
printf 'abcdef0123456789' > "$T/etc/sing-box/.reality_sid"
mkdir -p "$T/etc/sing-box/certs"
# fake cert so ensure_cert reuses it (no openssl needed in sandbox)
printf 'FAKECERT' > "$T/etc/sing-box/certs/fullchain.pem"
printf 'FAKEKEY' > "$T/etc/sing-box/certs/privkey.pem"
}

CFG="$T/etc/sing-box/config.json"

echo "=== Test 1: add VLESS TLS to base (HY2+AnyTLS Reality) ==="
setup_base
# menu 4 -> add 4 (VLESS) -> variant 2 (TLS) -> port TLS 51001 -> exit 0
OUT1=$(run_menu 4 4 2 51001 0)
echo "$OUT1" | grep -q "新协议已添加" && echo "PASS: 1 shows success" && PASS=$((PASS+1)) || { echo "FAIL: 1 shows success"; FAIL=$((FAIL+1)); echo "$OUT1" | tail -20; }
jqeq "1 inbound count = 3" '.inbounds | length' 3 "$CFG"
jqeq "1 vless-tls tag" '.inbounds[] | select(.tag=="vless-tls-in") | .type' "vless" "$CFG"
jqeq "1 vless-tls port" '.inbounds[] | select(.tag=="vless-tls-in") | .listen_port' 51001 "$CFG"
jqeq "1 vless-tls uses cert" '.inbounds[] | select(.tag=="vless-tls-in") | .tls.certificate_path' "$T/etc/sing-box/certs/fullchain.pem" "$CFG"
jqeq "1 vless-tls has no reality" '.inbounds[] | select(.tag=="vless-tls-in") | .tls.reality // "none"' "none" "$CFG"
jqeq "1 hy2 untouched" '.inbounds[] | select(.tag=="hy2-in") | .users[0].password' "HY2OLDPASS" "$CFG"
jqeq "1 anytls untouched" '.inbounds[] | select(.tag=="anytls-in") | .users[0].password' "ANYTLSOLDPASS" "$CFG"
check "1 .protocols ENABLE_VLESS_TLS" grep -q '^ENABLE_VLESS_TLS=true$' "$T/etc/sing-box/.protocols"
check "1 uris has vless-tls link" grep -q 'vless://.*security=tls' "$T/etc/sing-box/uris.txt"
check "1 uris still has anytls reality link" grep -q 'anytls://.*security=reality' "$T/etc/sing-box/uris.txt"

echo "=== Test 2: add AnyTLS TLS (reality key reuse) ==="
# menu 4 -> add 5 (AnyTLS) -> variant 2 (TLS) -> port 51003 -> exit 0
OUT2=$(run_menu 4 5 2 51003 0)
echo "$OUT2" | grep -q "新协议已添加" && echo "PASS: 2 shows success" && PASS=$((PASS+1)) || { echo "FAIL: 2 shows success"; FAIL=$((FAIL+1)); echo "$OUT2" | tail -20; }
jqeq "2 inbound count = 4" '.inbounds | length' 4 "$CFG"
jqeq "2 anytls-tls tag" '.inbounds[] | select(.tag=="anytls-tls-in") | .type' "anytls" "$CFG"
jqeq "2 anytls-tls port" '.inbounds[] | select(.tag=="anytls-tls-in") | .listen_port' 51003 "$CFG"
jqeq "2 anytls-tls uses cert" '.inbounds[] | select(.tag=="anytls-tls-in") | .tls.certificate_path' "$T/etc/sing-box/certs/fullchain.pem" "$CFG"
jqeq "2 anytls-tls has no reality" '.inbounds[] | select(.tag=="anytls-tls-in") | .tls.reality // "none"' "none" "$CFG"
jqeq "2 anytls reality untouched" '.inbounds[] | select(.tag=="anytls-in") | .users[0].password' "ANYTLSOLDPASS" "$CFG"
check "2 .protocols ENABLE_ANYTLS_TLS" grep -q '^ENABLE_ANYTLS_TLS=true$' "$T/etc/sing-box/.protocols"
check "2 uris has anytls-tls link" grep -q 'anytls://.*security=tls' "$T/etc/sing-box/uris.txt"

echo "=== Test 3: add already-installed VLESS TLS again (skip, no change) ==="
BEFORE3=$(md5sum "$CFG" | cut -d' ' -f1)
OUT3=$(run_menu 4 4 2 0)
echo "$OUT3" | grep -q "VLESS TLS 已安装" && echo "PASS: 3 warns already installed" && PASS=$((PASS+1)) || { echo "FAIL: 3 warns already installed"; FAIL=$((FAIL+1)); }
AFTER3=$(md5sum "$CFG" | cut -d' ' -f1)
[ "$BEFORE3" = "$AFTER3" ] && echo "PASS: 3 config unchanged" && PASS=$((PASS+1)) || { echo "FAIL: 3 config unchanged"; FAIL=$((FAIL+1)); }

echo "=== Test 4: reset VLESS TLS port only (tag-based, Reality untouched) ==="
# find menu option for reset VLESS TLS: show menu and pick it
# menu options: 1 view, 2 config, 3 edit, 4 add, 5 uninstall, 6 switch, then resets
# base+tests 1-2 installed: HY2, AnyTLS Reality, VLESS TLS, AnyTLS TLS
# resets shown: HY2(7), VLESS TLS(8), AnyTLS Reality(9), AnyTLS TLS(10)
OUT4=$(run_menu 8 51011 0)
echo "$OUT4" | grep -q "Vless TLS 端口: 51011" && echo "PASS: 4 reset shows new port" && PASS=$((PASS+1)) || { echo "FAIL: 4 reset shows new port"; FAIL=$((FAIL+1)); echo "$OUT4" | tail -10; }
jqeq "4 vless-tls port changed" '.inbounds[] | select(.tag=="vless-tls-in") | .listen_port' 51011 "$CFG"
jqeq "4 anytls-tls port unchanged" '.inbounds[] | select(.tag=="anytls-tls-in") | .listen_port' 51003 "$CFG"
jqeq "4 anytls reality port unchanged" '.inbounds[] | select(.tag=="anytls-in") | .listen_port' 60000 "$CFG"

echo "=== Test 5: fresh SS-only config, add HY2 salamander + TUIC cubic + SS chacha ==="
cat > "$CFG" <<'JSON'
{
  "log": {"level": "info", "timestamp": true},
  "ntp": {"enabled": true, "server": "time.apple.com", "server_port": 123, "interval": "30m"},
  "inbounds": [
    {"type": "shadowsocks", "listen": "::", "listen_port": 33333, "method": "2022-blake3-aes-128-gcm", "password": "OLDPASS", "tag": "ss-in"}
  ],
  "outbounds": [{"type": "direct", "tag": "direct-out"}]
}
JSON
cat > "$T/etc/sing-box/.protocols" <<'EOF'
ENABLE_SS=true
ENABLE_HY2=false
ENABLE_TUIC=false
ENABLE_REALITY=false
ENABLE_ANYTLS=false
ENABLE_VLESS_TLS=false
ENABLE_VLESS_XHTTP=false
ENABLE_ANYTLS_TLS=false
EOF
cat > "$T/etc/sing-box/.config_cache" <<'EOF'
ENABLE_SS=true
ENABLE_HY2=false
ENABLE_TUIC=false
ENABLE_REALITY=false
ENABLE_ANYTLS=false
ENABLE_VLESS_TLS=false
ENABLE_VLESS_XHTTP=false
ENABLE_ANYTLS_TLS=false
SS_PORT=33333
SS_PSK=OLDPASS
SS_METHOD=2022-blake3-aes-128-gcm
CUSTOM_IP=203.0.113.10
EOF
rm -f "$T/etc/sing-box/.reality_pub" "$T/etc/sing-box/.reality_sid"
# menu 4 -> add "2 3" (HY2+TUIC) -> port HY2 51021 -> obfs 2 (salamander) -> port TUIC 51022 -> cc 2 (cubic) -> exit 0
OUT5=$(run_menu 4 "2 3" 51021 2 51022 2 0)
echo "$OUT5" | grep -q "新协议已添加" && echo "PASS: 5 shows success" && PASS=$((PASS+1)) || { echo "FAIL: 5 shows success"; FAIL=$((FAIL+1)); echo "$OUT5" | tail -20; }
jqeq "5 inbound count = 3" '.inbounds | length' 3 "$CFG"
jqeq "5 hy2 obfs type" '.inbounds[] | select(.tag=="hy2-in") | .obfs.type' "salamander" "$CFG"
check "5 hy2 obfs password set" test -n "$(jq -r '.inbounds[] | select(.tag=="hy2-in") | .obfs.password' "$CFG")"
jqeq "5 tuic congestion" '.inbounds[] | select(.tag=="tuic-in") | .congestion_control' "cubic" "$CFG"
jqeq "5 ss untouched" '.inbounds[] | select(.tag=="ss-in") | .password' "OLDPASS" "$CFG"
check "5 uris hy2 has obfs" grep -q 'obfs=salamander' "$T/etc/sing-box/uris.txt"
check "5 uris tuic has cubic" grep -q 'congestion_control=cubic' "$T/etc/sing-box/uris.txt"
check "5 cache HY2_OBFS" grep -q '^HY2_OBFS=salamander$' "$T/etc/sing-box/.config_cache"
check "5 cache TUIC_CC" grep -q '^TUIC_CC=cubic$' "$T/etc/sing-box/.config_cache"

echo "=== Test 6: fresh empty config, add VLESS Reality (key generation path, regression) ==="
cat > "$CFG" <<'JSON'
{
  "log": {"level": "info", "timestamp": true},
  "ntp": {"enabled": true, "server": "time.apple.com", "server_port": 123, "interval": "30m"},
  "inbounds": [],
  "outbounds": [{"type": "direct", "tag": "direct-out"}]
}
JSON
cat > "$T/etc/sing-box/.protocols" <<'EOF'
ENABLE_SS=false
ENABLE_HY2=false
ENABLE_TUIC=false
ENABLE_REALITY=false
ENABLE_ANYTLS=false
ENABLE_VLESS_TLS=false
ENABLE_VLESS_XHTTP=false
ENABLE_ANYTLS_TLS=false
EOF
cat > "$T/etc/sing-box/.config_cache" <<'EOF'
ENABLE_SS=false
ENABLE_HY2=false
ENABLE_TUIC=false
ENABLE_REALITY=false
ENABLE_ANYTLS=false
ENABLE_VLESS_TLS=false
ENABLE_VLESS_XHTTP=false
ENABLE_ANYTLS_TLS=false
CUSTOM_IP=203.0.113.10
EOF
rm -f "$T/etc/sing-box/.reality_pub" "$T/etc/sing-box/.reality_sid"
# menu 4 -> add 4 (VLESS) -> variant 1 (Reality) -> SNI prompt (empty=default) -> port 51031 -> exit 0
# NOTE: ensure_reality_keys prompts for SNI when generating new keys
OUT6=$(run_menu 4 4 1 "" 51031 0)
echo "$OUT6" | grep -q "新协议已添加" && echo "PASS: 6 shows success" && PASS=$((PASS+1)) || { echo "FAIL: 6 shows success"; FAIL=$((FAIL+1)); echo "$OUT6" | tail -20; }
jqeq "6 inbound count = 1" '.inbounds | length' 1 "$CFG"
jqeq "6 vless reality pk generated" '.inbounds[] | select(.tag=="vless-in") | .tls.reality.private_key' "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" "$CFG"
jqeq "6 vless reality sid generated" '.inbounds[] | select(.tag=="vless-in") | .tls.reality.short_id[0]' "0123456789abcdef" "$CFG"
check "6 uris has vless reality link" grep -q 'vless://.*security=reality' "$T/etc/sing-box/uris.txt"

echo ""
echo "=========================="
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" = 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"

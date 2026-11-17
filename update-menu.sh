#!/usr/bin/env bash
# 只更新 candies-sb 管理面板（不碰配置、不重装、不换密码）
# 用法: bash update-menu.sh [install.sh 路径，默认 ./install.sh]
# 注意: 不要重跑 install.sh 来更新菜单——重跑会重新生成全部密码/UUID/密钥，
#       现有节点链接会作废。这个脚本只从 install.sh 里抽出管理面板部分重写。
set -euo pipefail

SRC="${1:-install.sh}"
SB_PATH="/usr/local/bin/candies-sb"

if [ "$(id -u)" != "0" ]; then
    echo "需要 root 权限" >&2
    exit 1
fi

if [ ! -f "$SRC" ]; then
    echo "找不到 $SRC,请先把新版 install.sh 传到这台机子再运行" >&2
    exit 1
fi

if ! grep -q "action_add_protocol" "$SRC"; then
    echo "这个 install.sh 里没有添加协议功能,请确认是新版" >&2
    exit 1
fi

if [ -f "$SB_PATH" ]; then
    cp "$SB_PATH" "$SB_PATH.bak.$(date +%Y%m%d%H%M%S)"
    echo "旧面板已备份"
fi

START=$(grep -n "<<'SB_SCRIPT'" "$SRC" | head -n1 | cut -d: -f1)
END=$(grep -n '^SB_SCRIPT$' "$SRC" | head -n1 | cut -d: -f1)

if [ -z "$START" ] || [ -z "$END" ] || [ "$END" -le "$START" ]; then
    echo "在 $SRC 里找不到管理面板代码段" >&2
    exit 1
fi

sed -n "$((START+1)),$((END-1))p" "$SRC" > "$SB_PATH"
chmod +x "$SB_PATH"
ln -sf /usr/local/bin/candies-sb /usr/bin/candies-sb

bash -n "$SB_PATH" || { echo "新面板语法检查失败,已停止" >&2; exit 1; }
grep -q "action_add_protocol" "$SB_PATH" || { echo "新面板里没有添加协议功能" >&2; exit 1; }

echo "✅ 管理面板已更新: $SB_PATH"
echo "现在输入 candies-sb,就能看到“添加新协议”了"

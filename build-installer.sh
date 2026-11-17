#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
awk -v extension=sbv6-extension.sh -v hook=native-export.sh '
  { sub(/\r$/, "") }
  /^# 卸载是纯本地操作：-U \/ -u 时置位/ && !inserted {
    while ((getline line < extension)>0) { sub(/\r$/, "", line); print line }
    close(extension); inserted=1
  }
  /  # 生成并显示节点信息/ {
    while ((getline line < hook)>0) { sub(/\r$/, "", line); print line }
    close(hook)
  }
  { print }
  END { if (!inserted) exit 1 }
' vendor/sing-box.sh > sbv6.sh.new
bash -n sbv6.sh.new
mv sbv6.sh.new sbv6.sh
echo 'Built sbv6.sh from upstream Bash source'

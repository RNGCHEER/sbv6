  if [ "$SBV6_NATIVE_EXPORT" = 1 ]; then
    printf '%s\n' "$V2RAYN_SUBSCRIBE" | grep -E '^[a-zA-Z0-9+]+://' > "$WORK_DIR/nodes.txt"
    base64 -w0 "$WORK_DIR/nodes.txt" > "$WORK_DIR/subscription.txt"
    printf '%s\n' "$CLASH_SUBSCRIBE" > "$WORK_DIR/clash.yaml"
    printf '%s\n' "$SHADOWROCKET_SUBSCRIBE" > "$WORK_DIR/shadowrocket.txt"
    printf '%s\n' "$THRONE_SUBSCRIBE" > "$WORK_DIR/throne.txt"
  fi

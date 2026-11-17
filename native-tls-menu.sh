  if [ "${SBV6_TLS_MANAGEMENT:-0}" = 1 ] || [ "${SBV6_NODE_MANAGEMENT:-0}" = 1 ]; then
    local TLS_IDX=() TLS_KEY=() TLS_VAL=() TLS_I
    for TLS_I in "${!MENU_KEY[@]}"; do
      if [ "${SBV6_NODE_MANAGEMENT:-0}" = 1 ]; then
        # These belong to upstream nginx/TUN/host routing, not this direct-node instance.
        case "${MENU_KEY[TLS_I]}" in subscribe|bindinterface|hy2hopping|hy2realm|customroute|warpaccount) continue;; esac
      else
        case "${MENU_KEY[TLS_I]}" in sni|fingerprint|xtlsmux) ;; *) continue;; esac
      fi
      TLS_IDX+=("${MENU_IDX[TLS_I]}"); TLS_KEY+=("${MENU_KEY[TLS_I]}"); TLS_VAL+=("${MENU_VAL[TLS_I]}")
    done
    MENU_IDX=("${TLS_IDX[@]}"); MENU_KEY=("${TLS_KEY[@]}"); MENU_VAL=("${TLS_VAL[@]}")
    if [[ " ${MENU_KEY[*]} " != *' sni '* ]]; then
      MENU_IDX=(129 "${MENU_IDX[@]}"); MENU_KEY=(sni "${MENU_KEY[@]}")
      MENU_VAL=("$(openssl x509 -noout -ext subjectAltName -in "$WORK_DIR/cert/cert.pem" | awk -F'DNS:' '/DNS:/{sub(/,.*/,"",$2);print $2}')" "${MENU_VAL[@]}")
    fi
  fi

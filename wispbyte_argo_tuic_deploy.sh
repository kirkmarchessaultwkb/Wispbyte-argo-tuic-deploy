#!/usr/bin/env bash
# wispbyte-argo-tuic-deploy.sh
# 一键在 Wispbyte（或类似 PaaS）上部署：KeepAlive Web + Cloudflare Argo（临时/固定） + TUIC。
# 用途：自托管开发/远程访问环境演示。请遵守法律与平台条款。

set -euo pipefail
IFS=$'\n\t'

# -------- configuration --------
: ${PORT:=${PORT:-}}
: ${CF_TOKEN:="eyJhIjoiOThhZmI1Zjg4YzQ5ZWNkMDYxZmI5ZTBhNDY0OTYyOGYiLCJ0IjoiYmUyNzEzMDgtYWJiZi00NzJlLWIwZjItNDUyMzQxZmVlODYyIiwicyI6Ik9ERXdNV0psTVdVdFpqZGhPUzAwTnpobUxUaGpZMkV0TVdFeE1HSmxPREZoT1RVNCJ9"}
: ${CF_DOMAIN:="wisp.xunda.ggff.net"}  # 固定隧道域名
: ${UUID:="77ef1ada-606c-46a5-8880-b79a23d3ae7a"}  # ✨新增：节点 UUID
: ${TUIC_TOKEN:="tuic_token_generate_here"}
: ${TUIC_PORT:=5000}
: ${KEEPALIVE_PORT:=${PORT:-14378}}
: ${WORKDIR:="/root/argo-tuic"}

mkdir -p "$WORKDIR"
cd "$WORKDIR"

info(){ printf "[INFO] %s\n" "$*"; }
warn(){ printf "[WARN] %s\n" "$*"; }

# Detect PORT
if [ -z "${PORT:-}" ]; then
  if [ -f /proc/1/environ ]; then
    PORT=$(tr '\0' '\n' </proc/1/environ | awk -F= '/^PORT=/ {print $2; exit}') || true
  fi
  PORT=${PORT:-$KEEPALIVE_PORT}
fi
info "Using PORT=$PORT"

# Detect arch
_arch=$(uname -m)
case "$_arch" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7*|armv6*) ARCH=armv6 ;;
  *) ARCH=amd64 ;;
esac
info "Arch: $_arch -> $ARCH"

download(){
  local url="$1" dest="$2"
  curl -fsSL "$url" -o "$dest" || wget -qO "$dest" "$url"
  chmod +x "$dest"
}

# Install cloudflared
CF_BIN="$WORKDIR/cloudflared"
if [ ! -f "$CF_BIN" ]; then
  info "Installing cloudflared..."
  case "$ARCH" in
    amd64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    arm64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
    armv6) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
  esac
  download "$CF_URL" "$CF_BIN"
fi

# Keepalive web
KEEP_PID_FILE="$WORKDIR/keepalive.pid"
nohup python3 -m http.server $PORT --bind 0.0.0.0 >/dev/null 2>&1 & echo $! > "$KEEP_PID_FILE"

# TUIC installer
info "Installing TUIC..."
bash -c "curl -Ls https://raw.githubusercontent.com/eishare/tuic-hy2-node.js-python/main/tuic.sh | sed 's/\r$//' | bash -s -- --noninteractive" || warn "TUIC installer error"

# nodejs-argo
info "Installing nodejs-argo..."
if [ ! -d "$WORKDIR/nodejs-argo" ]; then
  git clone https://github.com/eooce/nodejs-argo.git "$WORKDIR/nodejs-argo" || true
fi
cd "$WORKDIR/nodejs-argo"
npm install --production || true

# ✅ 写入 .env，包括 UUID
cat > .env <<EOF
PORT=$PORT
ARGO_DOMAIN=${CF_DOMAIN}
ARGO_AUTH=
UUID=${UUID}
EOF

# Run node
nohup node index.js >/dev/null 2>&1 & echo $! > "$WORKDIR/nodejs-argo.pid"

# cloudflared
nohup "$CF_BIN" tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate >/dev/null 2>&1 & echo $! > "$WORKDIR/cloudflared.pid"

cd "$WORKDIR"

echo "
✅ 部署完成！

UUID: $UUID
域名: $CF_DOMAIN

进程状态:
 - Web: $(cat "$KEEP_PID_FILE")
 - Argo: $(cat "$WORKDIR/cloudflared.pid")
 - NodeJS: $(cat "$WORKDIR/nodejs-argo.pid")

日志目录: $WORKDIR
若需要固定隧道 DNS，请在 Cloudflare 面板手动添加 CNAME。
"
exit 0

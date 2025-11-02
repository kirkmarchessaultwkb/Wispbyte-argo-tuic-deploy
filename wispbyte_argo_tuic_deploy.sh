#!/usr/bin/env bash
# wispbyte-argo-tuic-deploy.sh
# 一键在 Wispbyte（或类似 PaaS）上部署：KeepAlive Web + Cloudflare Argo（临时/固定） + TUIC。
# 用途：自托管开发/远程访问环境演示。请遵守法律与平台条款。
# 使用方法（在 Wispbyte Shell 里复制粘贴并运行）：
#   bash <(curl -Ls https://raw.githubusercontent.com/eishare/tuic-hy2-node.js-python/main/tuic.sh)  # 可选：只运行 tuic 脚本
#   bash ./wispbyte-argo-tuic-deploy.sh

set -euo pipefail
IFS=$'\n\t'

# -------- configuration (可在运行前通过 export 设置) --------
: ${PORT:=${PORT:-}}        # Wispbyte 平台会在环境中注入 PORT，脚本会自动读取
: ${CF_TOKEN:="eyJhIjoiOThhZmI1Zjg4YzQ5ZWNkMDYxZmI5ZTBhNDY0OTYyOGYiLCJ0IjoiYmUyNzEzMDgtYWJiZi00NzJlLWIwZjItNDUyMzQxZmVlODYyIiwicyI6Ik9ERXdNV0psTVdVdFpqZGhPUzAwTnpobUxUaGpZMkV0TVdFeE1HSmxPREZoT1RVNCJ9"}         # 若要固定域名，请设置此处为你的 Cloudflare API token（带 permutations）
: ${CF_DOMAIN:="wisp.xunda.ggff.net"}        # 若要固定域名，请设置为你的域名，如 dev.example.com
: ${TUIC_TOKEN:="tuic_token_generate_here"}
: ${TUIC_PORT:=5000}        # TUIC 本地监听端口（内部，不一定对公网开放）
: ${KEEPALIVE_PORT:=${PORT:-14378}} # 如果没有 PORT 环境变量，保底使用 14378
: ${WORKDIR:="/root/argo-tuic"}

mkdir -p "$WORKDIR"
cd "$WORKDIR"

info(){ printf "[INFO] %s\n" "$*"; }
warn(){ printf "[WARN] %s\n" "$*"; }
err(){ printf "[ERROR] %s\n" "$*"; }

# Detect port (priority: env PORT -> common env vars -> fallback)
if [ -z "${PORT:-}" ]; then
  # try common env files
  if [ -f /proc/1/environ ]; then
    PORT=$(tr '\0' '\n' </proc/1/environ | awk -F= '/^PORT=/ {print $2; exit}') || true
  fi
  PORT=${PORT:-$KEEPALIVE_PORT}
fi

info "Using PORT=$PORT"

# detect arch for binaries
_arch=$(uname -m)
case "$_arch" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7*|armv6*) ARCH=armv6 ;;
  *) ARCH=amd64 ;;
esac
info "Detected arch: $_arch -> $ARCH"

# ---------- helper: download executable ----------
download(){
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  else
    wget -qO "$dest" "$url"
  fi
  chmod +x "$dest"
}

# ---------- install cloudflared ----------
CF_BIN="$WORKDIR/cloudflared"
if [ ! -f "$CF_BIN" ]; then
  info "Installing cloudflared..."
  case "$ARCH" in
    amd64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    arm64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
    armv6) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
    *) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
  esac
  download "$CF_URL" "$CF_BIN"
else
  info "cloudflared already present"
fi

# ---------- Keepalive small web server (Python) ----------
KEEP_PID_FILE="$WORKDIR/keepalive.pid"
start_keepalive(){
  if [ -f "$KEEP_PID_FILE" ]; then
    pid=$(cat "$KEEP_PID_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      info "Keepalive already running (PID $pid)"
      return
    fi
  fi
  info "Starting keepalive web server on 0.0.0.0:$PORT"
  # run simple python http server to satisfy PaaS health check
  nohup bash -c "python3 -m http.server $PORT --bind 0.0.0.0 >/dev/null 2>&1 & echo \$! > '$KEEP_PID_FILE'" &>/dev/null
  sleep 1
  if [ -f "$KEEP_PID_FILE" ]; then
    info "Keepalive started (PID $(cat $KEEP_PID_FILE))"
  else
    warn "Failed to start keepalive via python3 - please ensure python3 is installed"
  fi
}

# ---------- TUIC 部分：使用你提供的仓库脚本安装 ----------
start_tuic(){
  info "Deploying TUIC using eishare/tuic-hy2-node.js-python helper (will auto-adapt port)"
  # This repository contains a tuic.sh installer which handles TUIC installation and auto-port logic
  if [ ! -d "$WORKDIR/tuic-hy2-node.js-python" ]; then
    git clone https://github.com/eishare/tuic-hy2-node.js-python.git "$WORKDIR/tuic-hy2-node.js-python" || true
  fi
  if [ -f "$WORKDIR/tuic-hy2-node.js-python/main/tuic.sh" ] || [ -f "$WORKDIR/tuic-hy2-node.js-python/tuic.sh" ]; then
    # prefer remote curl install to ensure latest
    bash -c "curl -Ls https://raw.githubusercontent.com/eishare/tuic-hy2-node.js-python/main/tuic.sh | sed 's/\r$//' | bash -s -- --noninteractive" || warn "tuic.sh returned non-zero"
  else
    # fallback: run remote
    bash -c "curl -Ls https://raw.githubusercontent.com/eishare/tuic-hy2-node.js-python/main/tuic.sh | sed 's/\r$//' | bash -s -- --noninteractive" || warn "tuic.sh remote install failed"
  fi
  info "TUIC deployment attempted — check tuic logs or $WORKDIR for created files"
}

# ---------- nodejs-argo 部分 ----------
start_nodejs_argo(){
  info "Installing nodejs-argo (Cloudflare Argo helper)"
  if [ ! -d "$WORKDIR/nodejs-argo" ]; then
    git clone https://github.com/eooce/nodejs-argo.git "$WORKDIR/nodejs-argo" || true
  fi
  cd "$WORKDIR/nodejs-argo" || return
  if [ -f package.json ]; then
    if command -v npm >/dev/null 2>&1; then
      npm install --production || warn "npm install returned non-zero"
    else
      warn "npm not found. nodejs-argo may not run without npm/node installed on the platform"
    fi
  fi

  # Create env file
  cat > .env <<EOF
PORT=$PORT
ARGO_DOMAIN=${CF_DOMAIN}
ARGO_AUTH=
EOF

  # Start index.js in background if node available
  if command -v node >/dev/null 2>&1; then
    nohup node index.js >/dev/null 2>&1 & echo $! > "$WORKDIR/nodejs-argo.pid"
    info "nodejs-argo started (PID $(cat "$WORKDIR/nodejs-argo.pid" 2>/dev/null || echo '?'))"
  else
    warn "node not available: please ensure Node.js is installed to run nodejs-argo"
  fi
  cd "$WORKDIR"
}

# ---------- cloudflared tunnel (临时 / 固定) ----------
start_cloudflared(){
  info "Starting cloudflared tunnel (temporary or fixed)"
  # If CF_TOKEN + CF_DOMAIN set -> try to create a named tunnel (requires account)
  if [ -n "${CF_TOKEN}" ] && [ -n "${CF_DOMAIN}" ]; then
    info "Fixed domain mode: attempting to create/configure tunnel for $CF_DOMAIN"
    export TUNNEL_CONN_RETRIES=0
    # Write a small config
    mkdir -p "$WORKDIR/argo"
    cat > "$WORKDIR/argo/config.yml" <<EOF
url: http://127.0.0.1:$PORT
logfile: $WORKDIR/argo/cloudflared.log
EOF
    nohup "$CF_BIN" tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate >/dev/null 2>&1 & echo $! > "$WORKDIR/cloudflared.pid"
    sleep 1
    info "cloudflared started (PID $(cat "$WORKDIR/cloudflared.pid" 2>/dev/null || echo '?'))"
    info "Note: creating DNS CNAME and full fixed tunnel automation requires Cloudflare API usage and may need additional commands which need your token to be present and have permissions."
  else
    info "Temporary tunnel mode: no CF_TOKEN/CF_DOMAIN provided — launching tunnel and using trycloudflare.com domain"
    nohup "$CF_BIN" tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate >/dev/null 2>&1 & echo $! > "$WORKDIR/cloudflared.pid"
    sleep 1
    info "cloudflared started (PID $(cat "$WORKDIR/cloudflared.pid" 2>/dev/null || echo '?'))"
    # try to retrieve the assigned trycloudflare host from the log if present
    sleep 2
    if [ -f "$WORKDIR/argo/cloudflared.log" ]; then
      host=$(grep -oE "https://[a-z0-9.-]+trycloudflare.com" "$WORKDIR/argo/cloudflared.log" | head -n1 || true)
      if [ -n "$host" ]; then
        info "Tunnel URL detected: $host"
      fi
    fi
  fi
}

# ---------- systemd units (if root) ----------
maybe_install_systemd(){
  if [ "$EUID" -eq 0 ]; then
    info "Running as root: installing simple systemd units"
    # keepalive
    cat > /etc/systemd/system/argo-tuic-keepalive.service <<EOF
[Unit]
Description=Argo TUIC Keepalive Web
After=network.target

[Service]
Type=simple
WorkingDirectory=$WORKDIR
ExecStart=/usr/bin/env python3 -m http.server $PORT --bind 0.0.0.0
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || true
    systemctl enable --now argo-tuic-keepalive.service || true
    info "systemd unit argo-tuic-keepalive.service installed and started"
  else
    info "Not root: skipping systemd installs (processes started in background)"
  fi
}

# ---------- start everything ----------
start_all(){
  start_keepalive
  start_nodejs_argo
  start_cloudflared
  start_tuic
  maybe_install_systemd
}

start_all

# ---------- summary ----------
cat <<EOF

Deployment attempted. Quick status:
 - WORKDIR: $WORKDIR
 - KEEPALIVE (python) PID: $(cat "$KEEP_PID_FILE" 2>/dev/null || echo 'not running')
 - cloudflared PID: $(cat "$WORKDIR/cloudflared.pid" 2>/dev/null || echo 'not running')
 - nodejs-argo PID: $(cat "$WORKDIR/nodejs-argo.pid" 2>/dev/null || echo 'not running')
 - TUIC: check output from the eishare installer (it prints tuic info)

Next steps:
 - If you want a fixed Cloudflare domain, export CF_TOKEN and CF_DOMAIN and re-run the cloudflared creation steps (the script will attempt temporary mode otherwise).
 - To view logs: ls $WORKDIR/logs or check the pid files under $WORKDIR
 - To stop: kill the pids listed above or use systemctl stop argo-tuic-keepalive (if installed as systemd)

EOF

# done
exit 0

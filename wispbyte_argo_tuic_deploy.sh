#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# -------------------- 基本参数（可通过环境变量预设） --------------------
# 推荐在 Wispbyte 面板里设置：CF_DOMAIN, CF_TOKEN, UUID（如果不设置会交互提示）
HOME_DIR="${HOME:-/home/container}"
WORKDIR="${WORKDIR:-$HOME_DIR/argo-tuic}"
PORT="${PORT:-}"                # 平台可能自动注入
CF_DOMAIN="${CF_DOMAIN:-}"      # 固定域名，例如 wisp.xunda.ggff.net
CF_TOKEN="${CF_TOKEN:-}"        # Cloudflare API token（建议在面板中设置，不在聊天中直接粘贴）
UUID="${UUID:-}"                # 节点 UUID，若空则自动生成
TUIC_PORT="${TUIC_PORT:-5000}"  # tuic 内部端口（默认）
KEEPALIVE_PORT_FALLBACK="${KEEPALIVE_PORT_FALLBACK:-14378}"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "[INFO] workdir = $WORKDIR"
echo "[INFO] home = $HOME_DIR"

# -------------------- 交互读取（如果 env 未设置） --------------------
# detect PORT
if [ -z "${PORT:-}" ]; then
  if [ -f /proc/1/environ ]; then
    PORT=$(tr '\0' '\n' </proc/1/environ | awk -F= '/^PORT=/ {print $2; exit}') || true
  fi
  PORT=${PORT:-$KEEPALIVE_PORT_FALLBACK}
fi

# CF_DOMAIN
if [ -z "${CF_DOMAIN}" ]; then
  read -p "请输入你的 Cloudflare 固定域名 (例如 wisp.xunda.ggff.net), 直接回车跳过(使用临时 trycloudflare): " in_cf_domain
  CF_DOMAIN="${in_cf_domain:-$CF_DOMAIN}"
fi

# CF_TOKEN (不回显)
if [ -z "${CF_TOKEN}" ]; then
  echo "提示：建议在 Wispbyte 环境变量面板预设 CF_TOKEN。"
  read -s -p "如需脚本自动创建 DNS/更改配置请输入 Cloudflare API Token（回车跳过，之后可手动设置）: " input_token
  echo
  CF_TOKEN="${input_token:-$CF_TOKEN}"
fi

# UUID
if [ -z "${UUID}" ]; then
  read -p "请输入 UUID（回车自动生成）: " input_uuid
  if [ -z "$input_uuid" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "[INFO] 未输入 UUID，已自动生成： $UUID"
  else
    UUID="$input_uuid"
    echo "[INFO] 使用输入 UUID： $UUID"
  fi
else
  echo "[INFO] 使用环境变量 UUID： $UUID"
fi

echo "[INFO] 使用 PORT=$PORT"
echo "[INFO] 使用 CF_DOMAIN=${CF_DOMAIN:-<none>}"

# -------------------- helper 下载函数 --------------------
download_exec() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  else
    wget -qO "$dest" "$url"
  fi
  chmod +x "$dest" || true
}

# -------------------- 安装 cloudflared（二进制） --------------------
CF_BIN="$WORKDIR/cloudflared"
if [ ! -f "$CF_BIN" ]; then
  echo "[INFO] 下载 cloudflared..."
  # 直接下载 amd64 版本（多数 Pterodactyl 容器为 amd64）
  download_exec "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" "$CF_BIN"
fi

# -------------------- keepalive Web（python） --------------------
KEEP_PID_FILE="$WORKDIR/keepalive.pid"
if [ -f "$KEEP_PID_FILE" ] && kill -0 "$(cat "$KEEP_PID_FILE" 2>/dev/null)" 2>/dev/null; then
  echo "[INFO] Keepalive 已在运行 (PID $(cat "$KEEP_PID_FILE"))"
else
  echo "[INFO] 启动 keepalive http server 监听 $PORT ..."
  nohup python3 -m http.server "$PORT" --bind 0.0.0.0 >/dev/null 2>&1 & echo $! > "$KEEP_PID_FILE"
  sleep 1
  echo "[INFO] Keepalive PID $(cat "$KEEP_PID_FILE" 2>/dev/null || echo '未启动')"
fi

# -------------------- 安装/运行 TUIC（使用 eishare 安装脚本） --------------------
echo "[INFO] 调用 TUIC 安装脚本 (eishare) — 可能会要求安装依赖，按脚本提示执行"
# 使用非 root 安装时，eishare 脚本会自动选择路径（通常放置在 /usr/local 或者 /opt），在 Pterodactyl 容器某些命令可能被限制
curl -fsSL https://raw.githubusercontent.com/eishare/tuic-hy2-node.js-python/main/tuic.sh | sed 's/\r$//' | bash -s -- --noninteractive || echo "[WARN] tuic 安装脚本返回非0（请手动检查或查看安装日志）"

# -------------------- 获取/部署 nodejs-argo（使用你 fork 的仓库） --------------------
NODE_DIR="$WORKDIR/nodejs-argo"
if [ -d "$NODE_DIR" ]; then
  echo "[INFO] nodejs-argo 目录已存在，拉取更新..."
  cd "$NODE_DIR"
  git pull origin main || true
else
  echo "[INFO] 克隆你的 nodejs-argo 仓库..."
  git clone https://github.com/kirkmarchessaultwkb/nodejs-argo.git "$NODE_DIR" || true
  cd "$NODE_DIR"
fi

# 若仓库中有 index.back，优先使用 index.back（与你早前策略一致）
if [ -f "index.back" ] && [ ! -f "index.js" ]; then
  echo "[INFO] 发现 index.back，复制为 index.js..."
  cp index.back index.js
fi

# 写入 .env（nodejs-argo 会读取）
cat > "$NODE_DIR/.env" <<EOF
PORT=$PORT
ARGO_DOMAIN=${CF_DOMAIN}
ARGO_AUTH=
UUID=${UUID}
CF_TOKEN=${CF_TOKEN}
EOF

# 安装依赖（如果 npm 可用）
if command -v npm >/dev/null 2>&1; then
  echo "[INFO] 安装 node 依赖..."
  npm install --production || echo "[WARN] npm install 失败（请手动安装依赖）"
else
  echo "[WARN] npm 未安装：nodejs-argo 需要 Node.js 环境，若面板未提供请安装 Node.js 或改用支持的镜像"
fi

# 后台运行 node
NODE_PID_FILE="$WORKDIR/nodejs-argo.pid"
if command -v node >/dev/null 2>&1; then
  nohup node "$NODE_DIR/index.js" >/dev/null 2>&1 & echo $! > "$NODE_PID_FILE"
  sleep 1
  echo "[INFO] nodejs-argo 启动 PID $(cat "$NODE_PID_FILE" 2>/dev/null || echo '启动失败')"
else
  echo "[WARN] node 未安装或不可用，跳过启动（请确保面板镜像包含 Node.js）"
fi

# -------------------- 启动 cloudflared 隧道（临时/固定） --------------------
CLOUDFLARED_PID_FILE="$WORKDIR/cloudflared.pid"
# 使用临时隧道（自动 trycloudflare 域名），如果 CF_DOMAIN & CF_TOKEN 都提供，则尝试带域名运行（注意：真正绑定固定域名通常需要在 Cloudflare 控制台或通过 API 创建 CNAME）
if [ -n "${CF_DOMAIN}" ] && [ -n "${CF_TOKEN}" ]; then
  echo "[INFO] CF_DOMAIN 与 CF_TOKEN 均存在，启动 cloudflared（尝试固定/自定义模式）..."
  nohup "$CF_BIN" tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate >/dev/null 2>&1 & echo $! > "$CLOUDFLARED_PID_FILE"
else
  echo "[INFO] 未提供完整 CF 固定域名/Token，启动临时 cloudflared 隧道..."
  nohup "$CF_BIN" tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate >/dev/null 2>&1 & echo $! > "$CLOUDFLARED_PID_FILE"
fi
sleep 2

# 试图从 cloudflared 日志或进程检索 trycloudflare 域名（若是临时隧道）
TRYCF_DOMAIN=""
if [ -f "$WORKDIR/argo/cloudflared.log" ]; then
  TRYCF_DOMAIN=$(grep -oE "https://[a-z0-9.-]+trycloudflare.com" "$WORKDIR/argo/cloudflared.log" | head -n1 || true)
fi

# -------------------- 输出订阅与节点信息 --------------------
echo
echo "========================================"
echo "部署完成（非root模式）"
echo "WORKDIR: $WORKDIR"
echo "UUID: $UUID"
echo "PORT: $PORT"
if [ -n "$CF_DOMAIN" ]; then
  echo "固定域名 (你设置的): $CF_DOMAIN"
fi
if [ -n "$TRYCF_DOMAIN" ]; then
  echo "临时 domain (trycloudflare): $TRYCF_DOMAIN"
fi
echo
# 标准订阅（推荐 TLS/443: 由 cloudflared/Argo 暴露 https）
if [ -n "$CF_DOMAIN" ]; then
  echo "标准订阅（HTTPS 标准端口）:"
  echo "https://$CF_DOMAIN/sub"
fi

# 非标端口订阅示例（若你在 Wispbyte 获取了特定端口并开放给公网）
echo "非标端口订阅（如果适用）:"
echo "http://$CF_DOMAIN:$PORT/sub"
if [ -n "$TRYCF_DOMAIN" ]; then
  echo "临时非标（trycloudflare）(若存在): http://$(echo $TRYCF_DOMAIN | sed 's#https://##'):$PORT/sub"
fi

echo
echo "进程/PID:"
echo " - keepalive: $(cat \"$KEEP_PID_FILE\" 2>/dev/null || echo 'not running')"
echo " - nodejs-argo: $(cat \"$NODE_PID_FILE\" 2>/dev/null || echo 'not running')"
echo " - cloudflared: $(cat \"$CLOUDFLARED_PID_FILE\" 2>/dev/null || echo 'not running')"
echo
echo "日志/文件夹: $WORKDIR"
echo "若要停止服务： kill <pid> 或重启容器（容器重启将需要你重新启动脚本或设置自动启动）"
echo "========================================"



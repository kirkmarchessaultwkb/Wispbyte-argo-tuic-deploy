#!/usr/bin/env bash
set -e

# ✅ Detect container home
HOME_DIR="${HOME:-/home/container}"
cd "$HOME_DIR"

echo ">> Working directory: $HOME_DIR"

# ✅ Required ENV vars (Wispbyte panel passes these)
UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
CF_TOKEN="${CF_TOKEN:-}"
CF_TUNNEL_ID="${CF_TUNNEL_ID:-}"
CF_TUNNEL_SECRET="${CF_TUNNEL_SECRET:-}"
CF_DOMAIN="${CF_DOMAIN:-}"
TUIC_PASS="${TUIC_PASS:-$(openssl rand -hex 8)}"
PORT="${PORT:-3000}"

echo "UUID = $UUID"
echo "TUIC Password = $TUIC_PASS"
echo "PORT = $PORT"

mkdir -p "$HOME_DIR/.argo"
mkdir -p "$HOME_DIR/tuic"
mkdir -p "$HOME_DIR/node"

# ✅ Save Argo creds (Pterodactyl safe)
echo "$CF_TUNNEL_SECRET" > "$HOME_DIR/.argo/tunnel-secret.json"

cat > "$HOME_DIR/.argo/tunnel.json" <<EOF
{"AccountTag":"","TunnelSecret":"$CF_TUNNEL_SECRET","TunnelID":"$CF_TUNNEL_ID"}
EOF

# ✅ Download Argo binary
curl -Lo cloudflared.tgz https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.tgz
tar -xvf cloudflared.tgz
mv cloudflared "$HOME_DIR/cloudflared"
chmod +x "$HOME_DIR/cloudflared"

# ✅ Start Argo (background)
nohup "$HOME_DIR/cloudflared" tunnel --no-autoupdate --config "$HOME_DIR/.argo/tunnel.json" run "$CF_TUNNEL_ID" >/dev/null 2>&1 &

# ✅ Install TUIC binary
curl -Lo tuic.tar.gz https://github.com/EAimTY/tuic/releases/latest/download/tuic-server-x86_64-unknown-linux-gnu.tar.gz
tar -xvf tuic.tar.gz -C tuic
chmod +x tuic/*

# ✅ TUIC server config
cat > "$HOME_DIR/tuic/tuic.json" <<EOF
{
 "server": "0.0.0.0:443",
 "uuid": "$UUID",
 "password": "$TUIC_PASS",
 "alpn": ["h3"],
 "congestion_control": "bbr"
}
EOF

# ✅ Start TUIC
nohup "$HOME_DIR/tuic/tuic-server" -c "$HOME_DIR/tuic/tuic.json" >/dev/null 2>&1 &

# ✅ Node app index file
cat > "$HOME_DIR/node/index.js" <<EOF
import express from "express";
const app = express();

const UUID = "$UUID";

app.get("/sub", (req, res) => {
 const config = \`vmess://\${Buffer.from(JSON.stringify({
   v: "2",
   ps: "Argo-TUIC",
   add: "$CF_DOMAIN",
   port: "443",
   id: UUID,
   aid: "0",
   net: "ws",
   type: "none",
   host: "$CF_DOMAIN",
   path: "/"
 })).toString('base64')}\`;

 res.send(config);
});

app.listen($PORT);
console.log("Node Argo+TUIC running on port $PORT");
EOF

# ✅ Start Node
npm init -y >/dev/null 2>&1
npm install express >/dev/null 2>&1
nohup node "$HOME_DIR/node/index.js" >/dev/null 2>&1 &

echo "✅ Deployment completed"
echo "订阅链接: https://$CF_DOMAIN/sub"


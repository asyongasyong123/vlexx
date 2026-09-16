cat <<'EOF' > deploy.sh && chmod +x deploy.sh && ./deploy.sh
#!/bin/bash
set -euo pipefail

# ============================================================
# OPENRESTY + VLESS-XHTTP — STABLE | DILI MO-TIMEOUT
# Qwiklabs-Safe Pattern | Same UUID
# ============================================================

UUID_KEY="a1b2c3d4-5678-40ef-98ab-cdef01234567"
SERVICE_NAME="openresty-xhttp"
WSPATH="/xhttp"
REGION="us-central1"
MEMORY="4Gi"
CPU="2"
CONCURRENCY="500"
MIN_INST=1
MAX_INST=2
TIMEOUT="3600"

# ============================================================
rm -rf ~/openresty-xhttp && mkdir -p ~/openresty-xhttp && cd ~/openresty-xhttp

cat > config.json <<JSONEND
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": ["8.8.8.8", "8.8.4.4"], "queryStrategy": "UseIPv4" },
  "inbounds": [
    {
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID_KEY", "level": 0}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "$WSPATH",
          "mode": "stream",
          "noGRPC": true,
          "heartbeat": 30000
        },
        "sockopt": {
          "tcpNoDelay": true,
          "keepAliveInterval": 30
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" }
    }
  ]
}
JSONEND

cat > nginx.conf <<'CONFEND'
worker_processes auto;
worker_rlimit_nofile 8192;

events {
    worker_connections 4096;
    use epoll;
}

http {
    sendfile on;
    tcp_nodelay on;
    keepalive_timeout 3600s;
    keepalive_requests 100000;

    upstream xhttp_backend {
        server 127.0.0.1:10000;
        keepalive 64;
        keepalive_timeout 3600s;
        keepalive_requests 10000;
    }

    server {
        listen 8080;

        location = /health {
            access_log off;
            return 200 "OK\n";
        }

        location /xhttp {
            proxy_pass http://xhttp_backend;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host $host;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_connect_timeout 15s;
            proxy_buffering off;
            proxy_cache off;
            proxy_request_buffering off;
        }

        location / {
            return 200 '<html><body style="font-family:system-ui;text-align:center;padding:3em;"><h1>✅ Service Active</h1><p>OpenResty + VLESS-XHTTP</p></body></html>';
        }
    }
}
CONFEND

cat > Dockerfile <<'DOCKEND'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && \
    unzip -q xray.zip xray && \
    chmod +x xray

FROM openresty/openresty:1.21.4.1-0-alpine
RUN mkdir -p /usr/local/bin
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray/config.json
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8080

CMD ["/bin/sh", "-c", \
    "xray run -c /etc/xray/config.json & \
    exec /usr/local/openresty/bin/openresty -g 'daemon off;'"]
DOCKEND

gcloud services enable run.googleapis.com cloudbuild.googleapis.com --quiet >/dev/null 2>&1

echo "🚀 Deploying $SERVICE_NAME..."

gcloud run deploy "$SERVICE_NAME" \
  --source . \
  --region "$REGION" \
  --platform managed \
  --allow-unauthenticated \
  --port 8080 \
  --cpu "$CPU" \
  --memory "$MEMORY" \
  --concurrency "$CONCURRENCY" \
  --min-instances "$MIN_INST" \
  --max-instances "$MAX_INST" \
  --timeout "${TIMEOUT}s" \
  --execution-environment=gen2 \
  --no-cpu-throttling \
  --cpu-boost \
  --session-affinity \
  --quiet

DOMAIN=$(gcloud run services describe "$SERVICE_NAME" --region "$REGION" --format='value(status.url)')
DOMAIN_CLEAN=${DOMAIN#https://}

echo
echo "============================================================"
echo "✅ DEPLOYMENT SUCCESS ✅"
echo "============================================================"
echo "Service:   $SERVICE_NAME"
echo "Domain:    $DOMAIN_CLEAN"
echo "Region:    $REGION"
echo "CPU:       $CPU"
echo "Memory:    $MEMORY"
echo "Min/Max:   $MIN_INST / $MAX_INST"
echo
echo "=== NETMOD SETTINGS ==="
echo "Host:      $DOMAIN_CLEAN"
echo "Port:      443"
echo "Network:   XHTTP"
echo "Path:      /xhttp"
echo "Mode:      stream"
echo "UUID:      $UUID_KEY"
echo "Security:  TLS"
echo "SNI:       $DOMAIN_CLEAN"
echo "Keep-Alive: ON"
echo "============================================================"
EOF

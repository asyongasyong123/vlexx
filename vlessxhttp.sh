#!/bin/bash
set -euo pipefail

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
            return 200 '<html><body style="font-family:system-ui;text-align:center;padding:3em;"><h1>✅ Service Active</h1></body></html>';
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

gcloud services enable run.googleapis.com cloudbuild.googleapis.com --quiet 2>/dev/null || true

echo "🚀 Building & Deploying..."
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
  --session-affinity

echo
DOMAIN=$(gcloud run services describe "$SERVICE_NAME" --region "$REGION" --format='value(status.url)')
echo "✅ DEPLOYED SUCCESSFULLY!"
echo "🔗 URL: $DOMAIN"
echo
echo "NETMOD SETTINGS:"
echo "Host: ${DOMAIN#https://}"
echo "Port: 443"
echo "Network: XHTTP"
echo "Path: /xhttp"
echo "Mode: stream"
echo "UUID: $UUID_KEY"
echo "TLS/SNI: ON"

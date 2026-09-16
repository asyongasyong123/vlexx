cat <<'EOF' > deploy.sh && chmod +x deploy.sh && ./deploy.sh
#!/bin/bash
set -euo pipefail

# ============================================================
# OPENRESTY + VLESS-XHTTP — STABLE | DILI MO-TIMEOUT
# Everyday Streaming & Download Optimized
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
mkdir -p ~/openresty-xhttp && cd ~/openresty-xhttp

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
    multi_accept on;
}

http {
    sendfile on;
    tcp_nodelay on;
    tcp_nopush on;
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

cat > supervisord.conf <<'SUPEND'
[supervisord]
nodaemon=true
logfile=/dev/null
user=root

[program:xray]
command=/usr/local/bin/xray run -c /etc/xray/config.json
autorestart=true
startsecs=3
startretries=20
stdout_logfile=/dev/stdout
stderr_logfile=/dev/stderr

[program:openresty]
command=/usr/local/openresty/bin/openresty -g 'daemon off;'
autorestart=true
startsecs=3
startretries=20
stdout_logfile=/dev/stdout
stderr_logfile=/dev/stderr
SUPEND

cat > Dockerfile <<'DOCKEND'
FROM ghcr.io/xtls/xray-core:26.7.28 AS xray-bin
FROM openresty/openresty:1.21.4.1-0-alpine

RUN apk add --no-cache supervisor tzdata

COPY --from=xray-bin /usr/local/bin/xray /usr/local/bin/xray
COPY config.json /etc/xray/config.json
COPY nginx.conf /etc/nginx/nginx.conf
COPY supervisord.conf /etc/supervisord.conf

RUN /usr/local/bin/xray run -test -c /etc/xray/config.json
EXPOSE 8080

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
DOCKEND

echo "🚀 Deploying $SERVICE_NAME..."

gcloud run deploy "$SERVICE_NAME" \
  --source . \
  --region "$REGION" \
  --platform managed \
  --port 8080 \
  --cpu "$CPU" \
  --memory "$MEMORY" \
  --concurrency "$CONCURRENCY" \
  --min-instances "$MIN_INST" \
  --max-instances "$MAX_INST" \
  --timeout "${TIMEOUT}s" \
  --execution-environment=gen2 \
  --cpu-boost \
  --session-affinity \
  --allow-unauthenticated \
  --startup-probe=tcpSocket.port=8080,initialDelaySeconds=15,periodSeconds=8,failureThreshold=15,timeoutSeconds=5 \
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

#!/usr/bin/env bash
set -euo pipefail

# =============================
# grpc.sh — Cloud Run deploy + Telegram push (final)
# =============================

# Colors
RESET='\033[0m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
log(){ echo -e "${GREEN}[INFO]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
error(){ echo -e "${RED}[ERROR]${RESET} $1"; }

# Telegram helpers
validate_bot_token(){ [[ "$1" =~ ^[0-9]{8,12}:[A-Za-z0-9_-]{20,}$ ]]; }
validate_chat_id(){ [[ "$1" =~ ^-?[0-9]+$ ]]; }
send_to_telegram(){
  local chat_id="$1"; local message="$2"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${chat_id}\",\"text\":\"${message}\",\"parse_mode\":\"Markdown\",\"disable_web_page_preview\":true}" \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage")
  [[ "$code" == "200" ]]
}
send_deployment_notification(){
  local message="$1"; local ok=0
  case $TELEGRAM_DESTINATION in
    channel) send_to_telegram "$TELEGRAM_CHANNEL_ID" "$message" && ok=1 ;;
    bot)     send_to_telegram "$TELEGRAM_CHAT_ID" "$message" && ok=1 ;;
    both)
      send_to_telegram "$TELEGRAM_CHANNEL_ID" "$message" && ok=$((ok+1))
      send_to_telegram "$TELEGRAM_CHAT_ID" "$message" && ok=$((ok+1))
      ;;
    none) log "Skip Telegram"; return 0 ;;
  esac
  [[ $ok -gt 0 ]]
}

# Project check
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[[ -z "$PROJECT" ]] && { error "No gcloud project set. Run: gcloud config set project <id>"; exit 1; }

# =============================
# Protocol selection
# =============================
echo -e "${BLUE}Protocols:${RESET}"
echo "1) Trojan (WS)"
echo "2) VLESS (WS)"
echo "3) VLESS (gRPC)"
echo "4) ALL"
read -rp "Choose protocol [default 1]: " opt
case "${opt:-1}" in
  2) PROTO="vless"; IMAGE="docker.io/n4vip/vless:latest";;
  3) PROTO="vlessgrpc"; IMAGE="docker.io/n4vip/vlessgrpc:latest";;
  4) PROTO="all"; IMAGE="docker.io/n4vip/vless:latest";;
  *) PROTO="trojan"; IMAGE="docker.io/n4vip/trojan:latest";;
esac
log "Selected: $PROTO"

# =============================
# Defaults & user input
# =============================
SERVICE="my-grpc-service"
REGION="us-central1"
HOST_DOMAIN="m.googleapis.com"

VLESS_UUID="ba0e3984-ccc9-48a3-8074-b2f507f41ce8"
VLESSGRPC_UUID="0c890000-4733-b20e-067f-fc341bd20000"
VLESSGRPC_SVC="n4vpnfree-grpc"
TROJAN_PASS="Nanda"

read -rp "Service name [default $SERVICE]: " svc; SERVICE=${svc:-$SERVICE}
read -rp "Region [default $REGION]: " r; REGION=${r:-$REGION}
read -rp "VLESS UUID [default $VLESS_UUID]: " v; [[ -n "$v" ]] && VLESS_UUID="$v"
read -rp "VLESS gRPC UUID [default $VLESSGRPC_UUID]: " vg; [[ -n "$vg" ]] && VLESSGRPC_UUID="$vg"
read -rp "gRPC serviceName [default $VLESSGRPC_SVC]: " sn; [[ -n "$sn" ]] && VLESSGRPC_SVC="$sn"
read -rp "Trojan password [default $TROJAN_PASS]: " tp; [[ -n "$tp" ]] && TROJAN_PASS="$tp"
read -rp "Host domain [default $HOST_DOMAIN]: " hd; [[ -n "$hd" ]] && HOST_DOMAIN="$hd"

# Telegram setup
echo -e "${BLUE}Telegram Setup:${RESET}"
echo "1) Channel only"
echo "2) Bot private message only"
echo "3) Both"
echo "4) None"
read -rp "Select (1-4) [default 4]: " t
case "${t:-4}" in
  1) TELEGRAM_DESTINATION="channel";;
  2) TELEGRAM_DESTINATION="bot";;
  3) TELEGRAM_DESTINATION="both";;
  4) TELEGRAM_DESTINATION="none";;
esac
if [[ "$TELEGRAM_DESTINATION" != "none" ]]; then
  while true; do
    read -rp "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
    validate_bot_token "$TELEGRAM_BOT_TOKEN" && break || warn "Invalid token"
  done
  if [[ "$TELEGRAM_DESTINATION" == "channel" || "$TELEGRAM_DESTINATION" == "both" ]]; then
    read -rp "Channel ID (e.g. -1001234567890): " TELEGRAM_CHANNEL_ID
  fi
  if [[ "$TELEGRAM_DESTINATION" == "bot" || "$TELEGRAM_DESTINATION" == "both" ]]; then
    read -rp "Chat ID: " TELEGRAM_CHAT_ID
  fi
fi

# =============================
# Deploy to Cloud Run
# =============================
log "Enabling APIs..."
gcloud services enable run.googleapis.com cloudbuild.googleapis.com --quiet
log "Deploying $SERVICE ..."
gcloud run deploy "$SERVICE" --image "$IMAGE" --platform managed --region "$REGION" \
  --allow-unauthenticated --cpu 2 --memory 2Gi --quiet
SERVICE_URL=$(gcloud run services describe "$SERVICE" --region "$REGION" --format 'value(status.url)')
CANONICAL_HOST="${SERVICE_URL#https://}"
log "Service URL: $SERVICE_URL"

# =============================
# Build links
# =============================
PATH_ENCODED="%2Fshayshayblack"
VLESS_WS="vless://${VLESS_UUID}@${HOST_DOMAIN}:443?path=${PATH_ENCODED}&security=tls&type=ws&host=${CANONICAL_HOST}&sni=${CANONICAL_HOST}#${SERVICE}-WS"
VLESS_GRPC="vless://${VLESSGRPC_UUID}@${HOST_DOMAIN}:443?mode=gun&security=tls&type=grpc&serviceName=${VLESSGRPC_SVC}&sni=${CANONICAL_HOST}#${SERVICE}-gRPC"
TROJAN_WS="trojan://${TROJAN_PASS}@${HOST_DOMAIN}:443?path=${PATH_ENCODED}&security=tls&type=ws&host=${CANONICAL_HOST}&sni=${CANONICAL_HOST}#${SERVICE}-Trojan"

if [[ "$PROTO" == "all" ]]; then
  MESSAGE="*Deploy Success* ✅
*Project:* \`${PROJECT}\`
*Service:* \`${SERVICE}\`
*Region:* \`${REGION}\`
*URL:* \`${SERVICE_URL}\`

*VLESS (WS):*
\`\`\`
${VLESS_WS}
\`\`\`

*VLESS (gRPC):*
\`\`\`
${VLESS_GRPC}
\`\`\`

*Trojan (WS):*
\`\`\`
${TROJAN_WS}
\`\`\`

*Usage:* Copy the above links and import to your V2Ray client."
else
  case "$PROTO" in
    trojan) LABEL="Trojan (WS)"; LINK="$TROJAN_WS";;
    vless) LABEL="VLESS (WS)"; LINK="$VLESS_WS";;
    vlessgrpc) LABEL="VLESS (gRPC)"; LINK="$VLESS_GRPC";;
  esac
  MESSAGE="*Cloud Run Deploy Success* ✅
*Project:* \`${PROJECT}\`
*Service:* \`${SERVICE}\`
*Region:* \`${REGION}\`
*URL:* \`${SERVICE_URL}\`

*${LABEL}:*
\`\`\`
${LINK}
\`\`\`

*Usage:* Copy the above link and import to your V2Ray client
━━━━━━━━━━━━━━━━━━━━"
fi

echo -e "$MESSAGE" > deployment-info.txt
log "Saved links to deployment-info.txt"

if [[ "$TELEGRAM_DESTINATION" != "none" ]]; then
  if send_deployment_notification "$MESSAGE"; then
    log "Telegram message sent"
  else
    warn "Telegram send failed"
  fi
fi

log "Done."

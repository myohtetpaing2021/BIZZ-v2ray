#!/usr/bin/env bash
set -euo pipefail

# =============================
# grpc.sh — Cloud Run deploy + Telegram push (full)
# - Builds/deploys (uses upstream repo image if no Dockerfile)
# - Produces VLESS-WS, VLESS-gRPC, Trojan-WS links
# - Telegram destination: channel | bot | both | none
# - path is fixed to /shayshayblack (URL-encoded: %2Fshayshayblack)
# =============================

# Colors / helpers
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RESET=$'\e[0m'; BOLD=$'\e[1m'
  C_GREEN=$'\e[38;5;46m'; C_RED=$'\e[38;5;196m'
  C_YEL=$'\e[38;5;226m'; C_BLUE=$'\e[38;5;33m'
  C_GREY=$'\e[38;5;245m'
else
  RESET= BOLD= C_GREEN= C_RED= C_YEL= C_BLUE= C_GREY=
fi

hr(){ printf "${C_GREY}%s${RESET}\n" "────────────────────────────────────────────────────"; }
sec(){ printf "\n${C_BLUE}📦 ${BOLD}%s${RESET}\n" "$1"; hr; }
ok(){ printf "${C_GREEN}✔${RESET} %s\n" "$1"; }
warn(){ printf "${C_YEL}⚠${RESET} %s\n" "$1"; }
err(){ printf "${C_RED}✘${RESET} %s\n" "$1"; }
kv(){ printf "   ${C_GREY}%s${RESET}  %s\n" "$1" "$2"; }

# Load .env if present (export variables)
if [[ -f .env ]]; then
  set -a; source ./.env; set +a
  ok ".env loaded (variables exported)"
fi

# =============================
# Validation helpers
# =============================
validate_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

validate_bot_token() {
  # permissive: digits, colon, and suffix chars (avoid rejecting valid tokens)
  [[ "$1" =~ ^[0-9]{5,15}:[A-Za-z0-9_\-]{8,}$ ]]
}

validate_channel_chat_id() {
  [[ "$1" =~ ^-?[0-9]+$ ]]
}

# send message using Telegram Bot API (returns 0 on success)
send_to_telegram() {
  local chat_id="$1"
  local message="$2"
  # use urlencoded text to avoid JSON quoting issues
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --data-urlencode "text=${message}" \
    -d "chat_id=${chat_id}" \
    -d "parse_mode=Markdown" \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" || echo "000")
  if [[ "$http_code" == "200" ]]; then
    return 0
  else
    warn "Telegram send failed (HTTP $http_code)"
    return 1
  fi
}

send_deployment_notification() {
  local message="$1"
  local success_count=0

  case "${TELEGRAM_DESTINATION:-none}" in
    channel)
      ok "Sending to Telegram channel ${TELEGRAM_CHANNEL_ID}..."
      if send_to_telegram "${TELEGRAM_CHANNEL_ID}" "${message}"; then success_count=$((success_count+1)); fi
      ;;
    bot)
      ok "Sending to Bot private chat ${TELEGRAM_CHAT_ID}..."
      if send_to_telegram "${TELEGRAM_CHAT_ID}" "${message}"; then success_count=$((success_count+1)); fi
      ;;
    both)
      ok "Sending to both channel & bot..."
      if send_to_telegram "${TELEGRAM_CHANNEL_ID}" "${message}"; then success_count=$((success_count+1)); fi
      if send_to_telegram "${TELEGRAM_CHAT_ID}" "${message}"; then success_count=$((success_count+1)); fi
      ;;
    none|*)
      ok "Telegram disabled by selection (none)."
      return 0
      ;;
  esac

  if [[ $success_count -gt 0 ]]; then
    ok "Telegram notifications sent ($success_count)"
    return 0
  else
    warn "All Telegram notifications failed (but deployment may still be OK)"
    return 1
  fi
}

# =============================
# Start interactive flow
# =============================
printf "\n${C_GREEN}${BOLD}🚀 grpc.sh — Cloud Run deploy (with Telegram)${RESET}\n"
hr

# Project check
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [[ -z "$PROJECT" ]]; then
  err "No active gcloud project. Run: gcloud config set project <PROJECT_ID>"
  exit 1
fi
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)' 2>/dev/null || true)"
ok "GCP project: ${PROJECT} (number: ${PROJECT_NUMBER})"

# Choose protocol
sec "Protocol"
printf "   1) Trojan (WS)\n   2) VLESS (WS)\n   3) VLESS (gRPC)\n"
read -rp "Choose protocol [default 1]: " _opt || true
case "${_opt:-1}" in
  2) PROTO="vless"; IMAGE="${IMAGE:-docker.io/n4vip/vless:latest}";;
  3) PROTO="vlessgrpc"; IMAGE="${IMAGE:-docker.io/n4vip/vlessgrpc:latest}";;
  *) PROTO="trojan"; IMAGE="${IMAGE:-docker.io/n4vip/trojan:latest}";;
esac
ok "Selected ${PROTO^^}"

# Defaults (kept similar to your original grpc.sh)
SERVICE="${SERVICE:-freen4vpn}"
REGION="${REGION:-us-central1}"
MEMORY="${MEMORY:-16Gi}"
CPU="${CPU:-4}"
TIMEOUT="${TIMEOUT:-3600}"
PORT="${PORT:-8080}"

# Default keys (same defaults as in your original file)
TROJAN_PASS="${TROJAN_PASS:-Nanda}"
TROJAN_TAG="${TROJAN_TAG:-N4%20GCP%20Hour%20Key}"
# Note: we will use PATH_ENCODED for path to ensure it's /shayshayblack
TROJAN_PATH="${TROJAN_PATH:-%2F%40n4vpn}"

VLESS_UUID="${VLESS_UUID:-0c890000-4733-b20e-067f-fc341bd20000}"
VLESS_PATH="${VLESS_PATH:-%2FN4VPN}"
VLESS_TAG="${VLESS_TAG:-N4%20GCP%20VLESS}"

VLESSGRPC_UUID="${VLESSGRPC_UUID:-0c890000-4733-b20e-067f-fc341bd20000}"
VLESSGRPC_SVC="${VLESSGRPC_SVC:-n4vpnfree-grpc}"
VLESSGRPC_TAG="${VLESSGRPC_TAG:-GCP-VLESS-GRPC}"

# User overrides
sec "Service configuration"
read -rp "Service name [default: ${SERVICE}]: " _svc || true
SERVICE="${_svc:-$SERVICE}"

read -rp "Region [default: ${REGION}]: " _r || true
REGION="${_r:-$REGION}"

# UUID override (only for VLESS WS link)
read -rp "VLESS UUID (press Enter to keep default): " _v && [[ -n "$_v" ]] && VLESS_UUID="$_v"
read -rp "VLESS-gRPC UUID (press Enter to keep default): " _vg && [[ -n "$_vg" ]] && VLESSGRPC_UUID="$_vg"
read -rp "Trojan password (press Enter to keep default): " _tp && [[ -n "$_tp" ]] && TROJAN_PASS="$_tp"

# Host domain for linking (mostly keep m.googleapis.com)
read -rp "Host domain for client links [default: m.googleapis.com]: " HOST_DOMAIN || true
HOST_DOMAIN="${HOST_DOMAIN:-m.googleapis.com}"

# Telegram destination selection (channel / bot / both / none)
select_telegram_destination() {
  sec "Telegram destination"
  printf "   1) Channel only\n   2) Bot private message only\n   3) Both Channel and Bot\n   4) None (don't send)\n"
  while true; do
    read -rp "Select (1-4) [default 4]: " tg || true
    case "${tg:-4}" in
      1) TELEGRAM_DESTINATION="channel"; break;;
      2) TELEGRAM_DESTINATION="bot"; break;;
      3) TELEGRAM_DESTINATION="both"; break;;
      4) TELEGRAM_DESTINATION="none"; break;;
      *) echo "Enter 1-4";;
    esac
  done

  if [[ "${TELEGRAM_DESTINATION}" != "none" ]]; then
    # Bot token required
    while true; do
      read -rp "Enter Telegram Bot Token (or set TELEGRAM_BOT_TOKEN in .env): " TELEGRAM_BOT_TOKEN || true
      TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
      if validate_bot_token "${TELEGRAM_BOT_TOKEN:-}"; then break; else warn "Token looks invalid — re-enter"; fi
    done
  fi

  if [[ "${TELEGRAM_DESTINATION}" == "channel" || "${TELEGRAM_DESTINATION}" == "both" ]]; then
    while true; do
      read -rp "Enter Telegram Channel ID (e.g. -1001234567890) or username @name: " TELEGRAM_CHANNEL_ID || true
      # allow numeric ids or @username (we'll accept @username but sendToTelegram expects numeric)
      if [[ "${TELEGRAM_CHANNEL_ID}" =~ ^@ ]]; then
        # ok - will try to send using @username (bot must be admin if channel)
        break
      elif validate_channel_chat_id "${TELEGRAM_CHANNEL_ID:-}"; then
        break
      else
        warn "Invalid channel id format"
      fi
    done
  fi

  if [[ "${TELEGRAM_DESTINATION}" == "bot" || "${TELEGRAM_DESTINATION}" == "both" ]]; then
    while true; do
      read -rp "Enter your chat ID for bot private message (numeric): " TELEGRAM_CHAT_ID || true
      if validate_channel_chat_id "${TELEGRAM_CHAT_ID:-}"; then break; else warn "Invalid chat id"; fi
    done
  fi
}

select_telegram_destination

# Summary & confirm
sec "Summary"
kv "Project" "$PROJECT"
kv "Service" "$SERVICE"
kv "Region" "$REGION"
kv "Protocol" "$PROTO"
kv "Host domain" "$HOST_DOMAIN"
kv "VLESS UUID" "${VLESS_UUID}"
kv "VLESS-gRPC serviceName" "${VLESSGRPC_SVC}"
kv "Trojan pass" "[hidden]"  # don't show password
kv "Telegram" "${TELEGRAM_DESTINATION}"
if [[ "${TELEGRAM_DESTINATION}" != "none" ]]; then
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    kv "Bot token" "${TELEGRAM_BOT_TOKEN:0:8}..."
  fi
  [[ -n "${TELEGRAM_CHANNEL_ID:-}" ]] && kv "Channel ID" "${TELEGRAM_CHANNEL_ID}"
  [[ -n "${TELEGRAM_CHAT_ID:-}" ]] && kv "Chat ID" "${TELEGRAM_CHAT_ID}"
fi

while true; do
  read -rp "Proceed with deployment? (y/n): " yn || true
  case "${yn:-y}" in
    [Yy]*) break;;
    [Nn]*) ok "Aborted by user"; exit 0;;
    *) echo "y/n";;
  esac
done

# Validate CLI prerequisites
if ! command -v gcloud &>/dev/null; then err "gcloud is required. Install Google Cloud SDK."; exit 1; fi
if ! command -v git &>/dev/null; then warn "git not found, but may not be required."; fi

# Enable APIs
sec "Enable APIs"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com --quiet || warn "API enable may have failed or already enabled"

# Clone upstream repo (use same repo user used previously)
cleanup() {
  [[ -d gcp-v2ray ]] && rm -rf gcp-v2ray
}
trap cleanup EXIT

sec "Cloning repository"
if ! git clone https://github.com/nyeinkokoaung404/gcp-v2ray.git gcp-v2ray &>/dev/null; then
  warn "Clone failed or network issue — proceeding assuming image exists or Dockerfile present locally"
else
  ok "Repo cloned"
  cd gcp-v2ray
fi

# Build image if Dockerfile present; else rely on prebuilt image set earlier
if [[ -f Dockerfile || -f docker/Dockerfile ]]; then
  sec "Building container image with Cloud Build"
  IMAGE="gcr.io/${PROJECT}/${SERVICE}-image:$(date +%s)"
  if gcloud builds submit --tag "${IMAGE}" --quiet; then
    ok "Image built: ${IMAGE}"
  else
    err "Cloud Build failed"; exit 1
  fi
else
  ok "No Dockerfile found in repo — using image: ${IMAGE}"
fi

# Deploy to Cloud Run
sec "Deploying to Cloud Run"
if ! gcloud run deploy "${SERVICE}" \
    --image "${IMAGE}" \
    --platform managed \
    --region "${REGION}" \
    --allow-unauthenticated \
    --cpu "${CPU}" \
    --memory "${MEMORY}" \
    --timeout "${TIMEOUT}" \
    --port "${PORT}" \
    --quiet; then
  err "Cloud Run deploy failed"; exit 1
fi
ok "Deployed ${SERVICE} to Cloud Run"

# Find service URL (prefer reliable API output)
SERVICE_URL=$(gcloud run services describe "${SERVICE}" --region "${REGION}" --format 'value(status.url)' --quiet || true)
if [[ -z "${SERVICE_URL}" ]]; then
  # fallback to canonical host pattern (may vary), use project number if available
  if [[ -n "${PROJECT_NUMBER}" ]]; then
    CANONICAL_HOST="${SERVICE}-${PROJECT_NUMBER}.${REGION}.run.app"
    SERVICE_URL="https://${CANONICAL_HOST}"
  else
    err "Couldn't determine service URL"
    exit 1
  fi
fi
CANONICAL_HOST="${SERVICE_URL#https://}"

sec "Service info"
kv "URL" "${SERVICE_URL}"

# Fixed path
PATH_ENCODED="%2Fshayshayblack"   # /shayshayblack

# Build URIs
VLESS_WS_URI="vless://${VLESS_UUID}@${HOST_DOMAIN}:443?path=${PATH_ENCODED}&security=tls&alpn=h3%2Ch2%2Chttp%2F1.1&encryption=none&host=${CANONICAL_HOST}&fp=randomized&type=ws&sni=${CANONICAL_HOST}#${SERVICE}"
VLESS_GRPC_URI="vless://${VLESSGRPC_UUID}@${HOST_DOMAIN}:443?mode=gun&security=tls&alpn=http%2F1.1&encryption=none&fp=randomized&type=grpc&serviceName=${VLESSGRPC_SVC}&sni=${CANONICAL_HOST}#${SERVICE}-gRPC"
TROJAN_WS_URI="trojan://${TROJAN_PASS}@${HOST_DOMAIN}:443?path=${PATH_ENCODED}&security=tls&alpn=http%2F1.1&host=${CANONICAL_HOST}&fp=randomized&type=ws&sni=${CANONICAL_HOST}#${SERVICE}-Trojan"

# Choose which to present depending on selected PROTO
case "${PROTO}" in
  trojan) SELECTED_URI="${TROJAN_WS_URI}" ; LABEL="TROJAN (WS)" ;;
  vless)  SELECTED_URI="${VLESS_WS_URI}"  ; LABEL="VLESS (WS)"  ;;
  vlessgrpc) SELECTED_URI="${VLESS_GRPC_URI}" ; LABEL="VLESS (gRPC)" ;;
  *) SELECTED_URI="${VLESS_WS_URI}" ; LABEL="VLESS (WS)" ;;
esac

# Save to file
cat > deployment-info.txt <<EOF
Service: ${SERVICE}
Region:  ${REGION}
URL:     ${SERVICE_URL}

VLESS (WS):
${VLESS_WS_URI}

VLESS (gRPC):
${VLESS_GRPC_URI}

Trojan (WS):
${TROJAN_WS_URI}

Selected (${LABEL}):
${SELECTED_URI}
EOF

ok "Deployment info saved to deployment-info.txt"

# Compose Telegram message (Markdown)
TELEGRAM_MSG="━━━━━━━━━━━━━━━━━━━━
*Cloud Run Deploy Success* ✅
*Project:* \`${PROJECT}\`
*Service:* \`${SERVICE}\`
*Region:* \`${REGION}\`
*URL:* \`${SERVICE_URL}\`

\`\`\`
${SELECTED_URI}
\`\`\`

_Copy the above link into your client (ensure client supports gRPC if using vless-gRPC)._
━━━━━━━━━━━━━━━━━━━━"

# Send to Telegram if requested
if [[ "${TELEGRAM_DESTINATION}" != "none" ]]; then
  sec "Sending to Telegram"
  if send_deployment_notification "${TELEGRAM_MSG}"; then
    ok "Telegram notifications completed"
  else
    warn "Telegram notification(s) failed — check token and chat/channel IDs. (Bot must be added to channel and given permission)"
  fi
else
  ok "Telegram disabled; skipping send"
fi

sec "Output"
cat deployment-info.txt
ok "All done. Enjoy!"

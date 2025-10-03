#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log(){ echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[ERROR]${NC} $1"; }
info(){ echo -e "${BLUE}[INFO]${NC} $1"; }

validate_uuid() {
    local uuid_pattern='^[0-9a-fA-F0-9]{8}-[0-9a-fA-F0-9]{4}-[0-9a-fA-F0-9]{4}-[0-9a-fA-F0-9]{4}-[0-9a-fA-F0-9]{12}$'
    if [[ ! $1 =~ $uuid_pattern ]]; then
        error "Invalid UUID: $1"
        return 1
    fi
    return 0
}

validate_bot_token() {
    local token_pattern='^[0-9]{8,12}:[A-Za-z0-9_-]{20,}$'
    if [[ ! $1 =~ $token_pattern ]]; then
        error "Invalid Telegram Bot Token format"
        return 1
    fi
    return 0
}

validate_channel_id() {
    if [[ ! $1 =~ ^-?[0-9]+$ ]]; then
        error "Invalid channel/chat id: $1"
        return 1
    fi
    return 0
}

select_region() {
    echo
    info "=== Region Selection ==="
    echo "1) us-central1"
    echo "2) us-west1"
    echo "3) us-east1"
    echo "4) europe-west1"
    echo "5) asia-southeast1"
    echo "6) asia-northeast1"
    while true; do
        read -p "Select region (1-6): " r
        case $r in
            1) REGION="us-central1"; break;;
            2) REGION="us-west1"; break;;
            3) REGION="us-east1"; break;;
            4) REGION="europe-west1"; break;;
            5) REGION="asia-southeast1"; break;;
            6) REGION="asia-northeast1"; break;;
            *) echo "Enter 1-6";;
        esac
    done
    info "Region -> $REGION"
}

select_telegram_destination() {
    echo
    info "=== Telegram Destination ==="
    echo "1) Channel only"
    echo "2) Bot private message only"
    echo "3) Both"
    echo "4) None"
    while true; do
        read -p "Select (1-4): " t
        case $t in
            1) TELEGRAM_DESTINATION="channel"; break;;
            2) TELEGRAM_DESTINATION="bot"; break;;
            3) TELEGRAM_DESTINATION="both"; break;;
            4) TELEGRAM_DESTINATION="none"; break;;
            *) echo "Enter 1-4";;
        esac
    done
}

get_user_input() {
    echo
    info "=== Service Configuration ==="
    while true; do
        read -p "Service name (no spaces recommended) : " SERVICE_NAME
        if [[ -n "$SERVICE_NAME" ]]; then break; else error "Service name can't be empty"; fi
    done

    # UUID default (keeps your earlier default if you press enter)
    while true; do
        read -p "UUID (press Enter to use default ba0e3984-...): " UUID
        UUID=${UUID:-ba0e3984-ccc9-48a3-8074-b2f507f41ce8}
        if validate_uuid "$UUID"; then break; fi
    done

    if [[ "$TELEGRAM_DESTINATION" != "none" ]]; then
        while true; do
            read -p "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
            if validate_bot_token "$TELEGRAM_BOT_TOKEN"; then break; fi
        done
    fi

    if [[ "$TELEGRAM_DESTINATION" == "channel" || "$TELEGRAM_DESTINATION" == "both" ]]; then
        while true; do
            read -p "Telegram Channel ID (e.g. -1001234567890): " TELEGRAM_CHANNEL_ID
            if validate_channel_id "$TELEGRAM_CHANNEL_ID"; then break; fi
        done
    fi
    if [[ "$TELEGRAM_DESTINATION" == "bot" || "$TELEGRAM_DESTINATION" == "both" ]]; then
        while true; do
            read -p "Your chat ID for bot private message: " TELEGRAM_CHAT_ID
            if validate_channel_id "$TELEGRAM_CHAT_ID"; then break; fi
        done
    fi

    read -p "Host domain for link (default: m.googleapis.com): " HOST_DOMAIN
    HOST_DOMAIN=${HOST_DOMAIN:-m.googleapis.com}

    read -p "Trojan password (default: Nanda): " TROJAN_PASS
    TROJAN_PASS=${TROJAN_PASS:-Nanda}
}

show_config_summary() {
    echo
    info "=== Summary ==="
    echo "Project: $(gcloud config get-value project 2>/dev/null || echo '(not set)')"
    echo "Region: $REGION"
    echo "Service: $SERVICE_NAME"
    echo "Host domain: $HOST_DOMAIN"
    echo "UUID: $UUID"
    echo "Telegram: $TELEGRAM_DESTINATION"
    [[ -n "${TELEGRAM_CHANNEL_ID:-}" ]] && echo "Channel ID: $TELEGRAM_CHANNEL_ID"
    [[ -n "${TELEGRAM_CHAT_ID:-}" ]] && echo "Chat ID: $TELEGRAM_CHAT_ID"
    echo
    while true; do
        read -p "Proceed? (y/n): " c
        case $c in [Yy]*) break;; [Nn]*) info "Cancelled"; exit 0;; *) echo "y/n";; esac
    done
}

validate_prereqs() {
    log "Validating prerequisites..."
    if ! command -v gcloud &>/dev/null; then error "gcloud not installed"; exit 1; fi
    if ! command -v git &>/dev/null; then error "git not installed"; exit 1; fi
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
    if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then error "gcloud project not configured. Run: gcloud config set project PROJECT_ID"; exit 1; fi
}

cleanup() {
    log "Cleaning temp..."
    [[ -d "gcp-v2ray" ]] && rm -rf gcp-v2ray
}

send_to_telegram() {
    local chat_id="$1"; local message="$2"
    local resp
    resp=$(curl -s -w "%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"${chat_id}\",\"text\":\"${message}\",\"parse_mode\":\"Markdown\",\"disable_web_page_preview\":true}" \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage")
    local code="${resp: -3}"
    if [[ "$code" == "200" ]]; then return 0; else error "Telegram send failed (HTTP $code)"; return 1; fi
}

send_deployment_notification() {
    local message="$1"
    local ok=0
    case $TELEGRAM_DESTINATION in
        channel) send_to_telegram "$TELEGRAM_CHANNEL_ID" "$message" && ok=1 || true;;
        bot) send_to_telegram "$TELEGRAM_CHAT_ID" "$message" && ok=1 || true;;
        both) send_to_telegram "$TELEGRAM_CHANNEL_ID" "$message" && ok=$((ok+1)) || true; send_to_telegram "$TELEGRAM_CHAT_ID" "$message" && ok=$((ok+1)) || true;;
        none) log "Skipping telegram"; return 0;;
    esac
    if [[ $ok -gt 0 ]]; then log "Telegram notifications sent"; else warn "Telegram notifications failed"; fi
}

# Sanitize service name (no spaces)
sanitize() { echo "$1" | tr ' ' '-' | tr -cd 'A-Za-z0-9-_.':; }

main() {
    info "GCP Cloud Run V2Ray Deploy Script (modified)"
    select_region
    select_telegram_destination
    get_user_input
    show_config_summary

    validate_prereqs
    trap cleanup EXIT

    log "Enabling APIs..."
    gcloud services enable cloudbuild.googleapis.com run.googleapis.com iam.googleapis.com --quiet

    cleanup

    log "Cloning upstream repo (used for build files)..."
    if ! git clone https://github.com/nyeinkokoaung404/gcp-v2ray.git gcp-v2ray; then
        error "Clone failed"; exit 1
    fi
    cd gcp-v2ray

    log "Building container image..."
    PROJECT_ID=$(gcloud config get-value project)
    IMAGE="gcr.io/${PROJECT_ID}/gcp-v2ray-image"
    if ! gcloud builds submit --tag "${IMAGE}" --quiet; then error "Build failed"; exit 1; fi

    log "Deploying to Cloud Run..."
    if ! gcloud run deploy "${SERVICE_NAME}" \
        --image "${IMAGE}" \
        --platform managed \
        --region "${REGION}" \
        --allow-unauthenticated \
        --cpu 2 \
        --memory 4Gi \
        --quiet; then
        error "Deployment failed"; exit 1
    fi

    SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" --region "${REGION}" --format 'value(status.url)' --quiet)
    if [[ -z "$SERVICE_URL" ]]; then error "Failed to get service URL"; exit 1; fi
    DOMAIN="${SERVICE_URL#https://}"

    # fixed path name as requested
    PATH_ENCODED="%2Fshayshayblack"   # /shayshayblack URL-encoded

    # sanitize for serviceName usage in grpc
    SERVICE_NAME_GRPC="$(sanitize "${SERVICE_NAME}-grpc")"

    # Build links (ensure characters that must be encoded are safe)
    # 1) WebSocket VLESS (original style) - host and sni set to deployed domain
    VLESS_WS="vless://${UUID}@${HOST_DOMAIN}:443?path=${PATH_ENCODED}&security=tls&alpn=h3%2Ch2%2Chttp%2F1.1&encryption=none&host=${DOMAIN}&fp=randomized&type=ws&sni=${DOMAIN}#${SERVICE_NAME}"

    # 2) VLESS gRPC (pattern based on user's example)
    # use serviceName param -> Service name on server side should match this.
    VLESS_GRPC="vless://${UUID}@${HOST_DOMAIN}:443?mode=gun&security=tls&alpn=http%2F1.1&encryption=none&fp=randomized&type=grpc&serviceName=${SERVICE_NAME_GRPC}&sni=${DOMAIN}#${SERVICE_NAME}-gRPC"

    # 3) Trojan (use TROJAN_PASS as password; example uses ws type in original but user gave ws; we keep ws type and same host)
    # Here we keep path encoded as /@n4vpn in their example, but requirement was to avoid errors — we set path to /shayshayblack for consistency
    TROJAN_LINK="trojan://${TROJAN_PASS}@${HOST_DOMAIN}:443?path=${PATH_ENCODED}&security=tls&alpn=http%2F1.1&host=${DOMAIN}&fp=randomized&type=ws&sni=${DOMAIN}#${SERVICE_NAME}-Trojan"

    # Save and show
    MESSAGE="━━━━━━━━━━━━━━━━━━━━
*Cloud Run Deploy Success* ✅
*Project:* \`${PROJECT_ID}\`
*Service:* \`${SERVICE_NAME}\`
*Region:* \`${REGION}\`
*URL:* \`${SERVICE_URL}\`

\`\`\`
${VLESS_WS}

${VLESS_GRPC}

${TROJAN_LINK}
\`\`\`
*Usage:* Copy the above links into your client (ensure client supports gRPC if using vless-grpc).
━━━━━━━━━━━━━━━━━━━━"

    echo "$MESSAGE" > deployment-info.txt
    log "Saved deployment-info.txt"

    info "=== Deployment info ==="
    echo "$MESSAGE"
    echo

    if [[ "$TELEGRAM_DESTINATION" != "none" ]]; then
        log "Sending to Telegram..."
        send_deployment_notification "$MESSAGE"
    fi

    log "Done. Service URL: $SERVICE_URL"
    log "Links saved to deployment-info.txt"
}

main "$@"

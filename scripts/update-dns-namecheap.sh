#!/bin/bash
# update-dns-namecheap.sh — Set @ and * A records on NameCheap
#
# Usage:
#   NAMECHEAP_API_USER=myuser NAMECHEAP_API_KEY=abc123 \
#     ./scripts/update-dns-namecheap.sh <domain> <ip>
#
# Required env vars:
#   NAMECHEAP_API_USER   NameCheap account username
#   NAMECHEAP_API_KEY    NameCheap API key (Profile → Tools → API Access)
#
# Optional env vars:
#   NAMECHEAP_SANDBOX    Set to "true" to use sandbox endpoint (default: false)
#                        Sandbox requires a separate account at sandbox.namecheap.com
#                        Use to test the script mechanics without touching real DNS.
#
# One-time NameCheap setup (production):
#   1. Log in → Profile → Tools → API Access
#   2. Enable API access
#   3. Add your public IP to the whitelist:  curl https://api.ipify.org
#   4. Copy the API key shown on that page
#
# If the script exits with "IP not whitelisted", visit:
#   https://ap.www.namecheap.com/settings/tools/apiaccess/

set -euo pipefail

# --- Validate positional args ---
if [[ $# -ne 2 ]]; then
    echo "❌ Usage: $0 <domain> <ip>"
    echo "   Example: $0 cmdbee.org 34.1.2.3"
    exit 1
fi

DOMAIN="$1"
LB_IP="$2"

# --- Validate required env vars ---
if [[ -z "${NAMECHEAP_API_USER:-}" ]]; then
    echo "❌ NAMECHEAP_API_USER is not set."
    exit 1
fi

if [[ -z "${NAMECHEAP_API_KEY:-}" ]]; then
    echo "❌ NAMECHEAP_API_KEY is not set."
    exit 1
fi

# --- Split domain into SLD + TLD (last-dot split: cmdbee.org → cmdbee + org) ---
TLD="${DOMAIN##*.}"
SLD="${DOMAIN%.*}"

echo "Domain: $DOMAIN (SLD=$SLD TLD=$TLD) → $LB_IP"

# --- Select API endpoint ---
if [[ "${NAMECHEAP_SANDBOX:-false}" == "true" ]]; then
    API_BASE="https://api.sandbox.namecheap.com/xml.response"
    echo "⚠️  Using NameCheap SANDBOX API — no real DNS changes will be made"
else
    API_BASE="https://api.namecheap.com/xml.response"
fi

# --- Detect current public IP (NameCheap requires it as ClientIp param) ---
echo "🌐 Detecting public IP..."
CLIENT_IP=$(curl -sf --max-time 10 https://api.ipify.org) || {
    echo "❌ Could not detect public IP via api.ipify.org"
    exit 1
}
echo "   Client IP: $CLIENT_IP"

# --- Call NameCheap setHosts API ---
echo "📡 Calling NameCheap API for $DOMAIN..."
RESPONSE=$(curl -sf --max-time 15 \
    "${API_BASE}?ApiUser=${NAMECHEAP_API_USER}&ApiKey=${NAMECHEAP_API_KEY}&UserName=${NAMECHEAP_API_USER}&ClientIp=${CLIENT_IP}&Command=namecheap.domains.dns.setHosts&SLD=${SLD}&TLD=${TLD}&HostName1=@&RecordType1=A&Address1=${LB_IP}&TTL1=300&HostName2=*&RecordType2=A&Address2=${LB_IP}&TTL2=300") || {
    echo "❌ API request failed (network error or timeout)"
    exit 1
}

# --- Parse XML response ---
if echo "$RESPONSE" | grep -q 'IsSuccess="true"'; then
    echo "✅ DNS updated successfully:"
    echo "   @ → $LB_IP (TTL 300s)"
    echo "   * → $LB_IP (TTL 300s)"
    echo "   Propagation typically takes 1–5 minutes."
    exit 0
fi

# IP not whitelisted (NameCheap error code 1011102)
if echo "$RESPONSE" | grep -q '1011102'; then
    echo "❌ NameCheap API rejected your IP: $CLIENT_IP"
    echo "   Whitelist it at: https://ap.www.namecheap.com/settings/tools/apiaccess/"
    echo "   Then re-run this script (or re-run bootstrap.sh)."
    exit 1
fi

# Other API errors — extract human-readable message
ERROR_MSG=$(echo "$RESPONSE" \
    | grep -o '<Error[^>]*>[^<]*</Error>' \
    | head -1 \
    | sed 's/<[^>]*>//g')

if [[ -n "$ERROR_MSG" ]]; then
    echo "❌ NameCheap API error: $ERROR_MSG"
else
    echo "❌ Unexpected API response:"
    echo "$RESPONSE"
fi
exit 1

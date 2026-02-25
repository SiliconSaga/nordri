# NameCheap DNS Automation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Automate `@` and `*` A record updates on NameCheap at the end of `bootstrap.sh gke`, eliminating the last manual step in the cluster rebuild → test cycle.

**Architecture:** A standalone bash script `scripts/update-dns-namecheap.sh` calls the NameCheap XML API to overwrite all DNS records for a domain with two A records pointing at the Traefik LB IP. `bootstrap.sh` calls it if `NAMECHEAP_API_KEY` is set; falls back to the existing manual instructions box if not or if the call fails.

**Tech Stack:** bash, curl, NameCheap XML API v2 (`namecheap.domains.dns.setHosts`), `api.ipify.org` for public IP detection.

---

### Task 1: Create `scripts/update-dns-namecheap.sh` — validation skeleton

**Files:**
- Create: `scripts/update-dns-namecheap.sh`

**Step 1: Create the file with arg/env validation only**

```bash
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
```

**Step 2: Make it executable**

```bash
chmod +x scripts/update-dns-namecheap.sh
```

**Step 3: Verify validation paths**

```bash
# Missing args
./scripts/update-dns-namecheap.sh
# Expected: ❌ Usage: ...

# Missing env var
./scripts/update-dns-namecheap.sh cmdbee.org 1.2.3.4
# Expected: ❌ NAMECHEAP_API_USER is not set.

# Missing API key
NAMECHEAP_API_USER=test ./scripts/update-dns-namecheap.sh cmdbee.org 1.2.3.4
# Expected: ❌ NAMECHEAP_API_KEY is not set.

# Valid args — should print domain split and exit 0
NAMECHEAP_API_USER=test NAMECHEAP_API_KEY=test \
  ./scripts/update-dns-namecheap.sh cmdbee.org 1.2.3.4
# Expected: Domain: cmdbee.org (SLD=cmdbee TLD=org) → 1.2.3.4
```

**Step 4: Commit**

```bash
git add scripts/update-dns-namecheap.sh
git commit -m "feat: add update-dns-namecheap.sh skeleton with arg/env validation"
```

---

### Task 2: Add public IP detection and API call

**Files:**
- Modify: `scripts/update-dns-namecheap.sh`

**Step 1: Add after the SLD/TLD block**

```bash
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

echo "$RESPONSE"
```

**Step 2: Verify network error path**

```bash
# Bad API URL should give network/timeout error
NAMECHEAP_API_USER=test NAMECHEAP_API_KEY=test \
  ./scripts/update-dns-namecheap.sh cmdbee.org 1.2.3.4
# Expected: prints public IP, then raw XML response (likely auth error from NameCheap)
# The raw response print is temporary — response parsing comes in Task 3
```

**Step 3: Commit**

```bash
git add scripts/update-dns-namecheap.sh
git commit -m "feat: add public IP detection and NameCheap API call"
```

---

### Task 3: Add XML response parsing and exit codes

**Files:**
- Modify: `scripts/update-dns-namecheap.sh`

**Step 1: Replace the `echo "$RESPONSE"` line with proper parsing**

```bash
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
```

**Step 2: Verify with invalid credentials (expected: auth error, not whitelist error)**

```bash
NAMECHEAP_API_USER=fakeuser NAMECHEAP_API_KEY=fakekey \
  ./scripts/update-dns-namecheap.sh cmdbee.org 1.2.3.4
# Expected: ❌ NameCheap API error: <some auth message>
# (Not a crash, not raw XML — a clean error line)
```

**Step 3: Verify with sandbox (requires sandbox.namecheap.com account)**

```bash
NAMECHEAP_API_USER=sandboxuser NAMECHEAP_API_KEY=sandboxkey \
  NAMECHEAP_SANDBOX=true \
  ./scripts/update-dns-namecheap.sh cmdbee.org 1.2.3.4
# Expected with valid sandbox creds: ✅ DNS updated successfully
# Expected with invalid creds: ❌ NameCheap API error: ...
```

**Step 4: Commit**

```bash
git add scripts/update-dns-namecheap.sh
git commit -m "feat: add XML response parsing with whitelist and error detection"
```

---

### Task 4: Integrate into `bootstrap.sh`

**Files:**
- Modify: `bootstrap.sh` (Step 6 block, lines ~475–505)

**Step 1: After the `TRAEFIK_IP` wait loop (after the `done` that ends the while loop), add the DNS automation block**

Find this line in Step 6 (just before the `echo "╔══` line):
```bash
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
```

Insert BEFORE it:
```bash
    # --- DNS Automation (optional — requires NameCheap credentials) ---
    # Set NAMECHEAP_API_USER and NAMECHEAP_API_KEY to automate A record updates.
    # See scripts/update-dns-namecheap.sh for one-time NameCheap setup instructions.
    DNS_UPDATED=false
    if [[ -n "${NAMECHEAP_API_KEY:-}" ]]; then
        echo ""
        echo "🔧 [DNS] NameCheap credentials detected — attempting automated DNS update..."
        if "$SCRIPT_DIR/scripts/update-dns-namecheap.sh" \
             "${NAMECHEAP_DOMAIN:-cmdbee.org}" "$TRAEFIK_IP"; then
            DNS_UPDATED=true
        else
            echo "⚠️  DNS automation failed. Follow manual instructions below."
        fi
    fi
```

**Step 2: Wrap the manual instructions box in a conditional**

Change:
```bash
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║              📋 MANUAL STEPS REQUIRED                            ║"
```

To:
```bash
    if [[ "$DNS_UPDATED" == "false" ]]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║              📋 MANUAL STEPS REQUIRED                            ║"
```

And add a closing `fi` after the last line of the box (just before `echo ""`):
```bash
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    fi   # DNS_UPDATED
```

**Step 3: Verify the manual path still works (no credentials set)**

```bash
# Dry-run check — should still show manual instructions box when no key is set
grep -A5 "DNS_UPDATED" bootstrap.sh
# Expected: block is present, DNS_UPDATED logic wraps the manual box
```

**Step 4: Commit**

```bash
git add bootstrap.sh
git commit -m "feat: wire update-dns-namecheap.sh into bootstrap.sh Step 6"
```

---

### Task 5: Update `docs/bootstrap.md`

**Files:**
- Modify: `docs/bootstrap.md` (Post-Bootstrap GKE section, lines ~72–81)

**Step 1: Replace the Post-Bootstrap section**

Find:
```markdown
## Post-Bootstrap (GKE)

After the root app is applied the bootstrap script waits for the Traefik LB IP and
prints DNS instructions. cert-manager and the Gateway deploy automatically via ArgoCD.

**Manual steps required:**
1. Point your domain A record at the printed Traefik LB IP
2. Test cert issuance with `letsencrypt-gateway-staging` before using production
   (see `nidavellir/demos/whoami/` for a ready-made validation app)
```

Replace with:
```markdown
## Post-Bootstrap (GKE)

After the root app is applied the bootstrap script waits for the Traefik LB IP.
cert-manager and the Gateway deploy automatically via ArgoCD.

### Automated DNS (recommended)

Set these env vars before running `bootstrap.sh` to have DNS updated automatically:

```bash
export NAMECHEAP_API_USER=your-username
export NAMECHEAP_API_KEY=your-api-key
export NAMECHEAP_DOMAIN=cmdbee.org   # default; override for other domains
./bootstrap.sh gke
```

The script updates `@` and `*` A records to the Traefik LB IP via the NameCheap API,
then cert-manager can issue certs as soon as DNS propagates (~1–5 minutes).

**One-time NameCheap setup:**
1. Log in → Profile → Tools → API Access → Enable API
2. Whitelist your public IP: `curl https://api.ipify.org`
3. Copy the API key

If the call fails (e.g. your IP changed), `bootstrap.sh` falls back to manual
instructions. Re-run `scripts/update-dns-namecheap.sh` once the whitelist is updated.

**Testing the script without touching real DNS:**
```bash
NAMECHEAP_API_USER=sandboxuser NAMECHEAP_API_KEY=sandboxkey \
  NAMECHEAP_SANDBOX=true \
  ./scripts/update-dns-namecheap.sh cmdbee.org 1.2.3.4
```
Requires a separate account at [sandbox.namecheap.com](https://www.sandbox.namecheap.com).

### Manual DNS (fallback)

If credentials are not set, `bootstrap.sh` prints the LB IP and these steps:
1. Point `@` and `*` A records at the printed Traefik LB IP at your registrar
2. Test cert issuance with `letsencrypt-gateway-staging` before using production
   (see `nidavellir/demos/whoami/` for a ready-made validation app)
```

**Step 2: Verify the doc renders cleanly**

```bash
# Quick sanity check — no unclosed code fences
grep -c '```' docs/bootstrap.md
# Expected: even number
```

**Step 3: Commit**

```bash
git add docs/bootstrap.md
git commit -m "docs: update bootstrap.md with NameCheap DNS automation instructions"
```

---

### Task 6: End-to-end smoke test

**Step 1: Test the error paths of the final script**

```bash
# No args
./scripts/update-dns-namecheap.sh
# Expected: ❌ Usage: ...

# No env vars
./scripts/update-dns-namecheap.sh cmdbee.org 1.2.3.4
# Expected: ❌ NAMECHEAP_API_USER is not set.

# Invalid credentials → clean error, not a crash
NAMECHEAP_API_USER=x NAMECHEAP_API_KEY=y \
  ./scripts/update-dns-namecheap.sh cmdbee.org 1.2.3.4
# Expected: ❌ NameCheap API error: <message>  (exit code 1)
```

**Step 2: Verify bootstrap.sh behaviour with no credentials**

```bash
# Grep confirms manual box is still reachable
grep -n "DNS_UPDATED\|MANUAL STEPS" bootstrap.sh
# Expected: DNS_UPDATED=false and ╔══ MANUAL block both present and correctly nested
```

**Step 3: Live test with real credentials against a running cluster**

```bash
export NAMECHEAP_API_USER=<real-user>
export NAMECHEAP_API_KEY=<real-key>
./scripts/update-dns-namecheap.sh cmdbee.org $(kubectl get svc traefik -n kube-system \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
# Expected: ✅ DNS updated successfully ...
# Verify: dig @ 1.1.1.1 cmdbee.org   (should show new IP within ~5 minutes)
```

**Step 4: Commit if any final tweaks were made**

```bash
git add -p
git commit -m "fix: any final adjustments from smoke test"
```

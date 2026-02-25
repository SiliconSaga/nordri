# Design: NameCheap DNS Automation

**Date**: 2026-02-24
**Status**: Approved — ready for implementation

## Goal

Automate the `@` and `*` A record updates on NameCheap after a GKE cluster bootstrap,
so a full end-to-end test cycle (provision → bootstrap → DNS → cert issuance → traffic)
requires zero manual steps.

## Context

After `bootstrap.sh gke` completes, the Traefik LoadBalancer IP is known. Currently
the script prints it and tells the user to go update DNS manually. This is the last
manual step preventing fully automated end-to-end testing with kuttl or similar tools.

`cmdbee.org` is a test-only domain — no MX, TXT, or other records need preserving.
The NameCheap `setHosts` API overwrites all records in a single call, which is fine here.

## Scope

- GKE only (homelab uses no external DNS/cert-manager for now)
- Single registrar: NameCheap
- Two records only: `@` and `*` A records pointing to the Traefik LB IP
- TTL: 300 seconds (fast propagation for test cycles)
- Opt-in: script is a no-op if credentials aren't set; bootstrap falls back to manual instructions

## Solution

### New file: `scripts/update-dns-namecheap.sh`

Standalone script, callable from bootstrap or independently.

**Interface**:
```bash
NAMECHEAP_API_USER=myuser NAMECHEAP_API_KEY=abc123 \
  ./scripts/update-dns-namecheap.sh <domain> <ip>
```

**Steps**:
1. Validate args and required env vars (`NAMECHEAP_API_USER`, `NAMECHEAP_API_KEY`)
2. Detect current public IP via `curl -s https://api.ipify.org` (required as NameCheap `ClientIp`)
3. Split domain on last dot → `SLD` and `TLD` (e.g. `cmdbee` + `org`)
4. Call `namecheap.domains.dns.setHosts` with two records: `@` A and `*` A both pointing to `<ip>`
5. Parse XML response:
   - `IsSuccess="true"` → print confirmation
   - Error `1011102` (IP not whitelisted) → print current IP + link to NameCheap API Access settings
   - Other errors → extract and print `<Error>` text
6. Exit 0 on success, non-zero on any failure

**Optional env vars**:
| Var | Default | Purpose |
|-----|---------|---------|
| `NAMECHEAP_API_USER` | (required) | NameCheap account username |
| `NAMECHEAP_API_KEY` | (required) | NameCheap API key |
| `NAMECHEAP_SANDBOX` | `false` | Use sandbox endpoint for testing the script itself |

The sandbox endpoint (`api.sandbox.namecheap.com`) lets you verify the script's API
mechanics without touching real DNS. Clearly documented in the script header.

### Changes to `bootstrap.sh`

In the Step 6 (GKE post-bootstrap) block, after `TRAEFIK_IP` is resolved:

```bash
DNS_UPDATED=false
if [[ -n "${NAMECHEAP_API_KEY:-}" ]]; then
    if "$SCRIPT_DIR/scripts/update-dns-namecheap.sh" \
         "${NAMECHEAP_DOMAIN:-cmdbee.org}" "$TRAEFIK_IP"; then
        DNS_UPDATED=true
    fi
fi

# Fall back to manual instructions if DNS wasn't auto-updated
if [[ "$DNS_UPDATED" == "false" ]]; then
    # ... existing manual instructions box ...
fi
```

`NAMECHEAP_DOMAIN` defaults to `cmdbee.org` but can be overridden for other users.

### Changes to `docs/bootstrap.md`

Add a section under the GKE post-bootstrap instructions documenting the optional
env vars and the one-time NameCheap setup steps (enable API access, whitelist Mac IP).

## One-time NameCheap Setup (user action, not scripted)

1. Log in to NameCheap → Profile → Tools → API Access
2. Enable API access
3. Add your Mac's public IP to the whitelist (`curl https://api.ipify.org`)
4. Copy the API key

This is done once. If the Mac's IP changes (rare), the script exits with a clear message
and the URL to update the whitelist.

## Out of Scope

- Cloud NAT / static egress IP (only needed if in-cluster components call NameCheap)
- ExternalDNS (only needed if LB IP drifts mid-cluster lifetime — not observed in practice)
- Multi-level TLDs (`.co.uk` etc.) — simple last-dot split is sufficient for now
- Other registrars
- Homelab / DNS-01 challenge support

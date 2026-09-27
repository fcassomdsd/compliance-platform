#!/usr/bin/env bash
#
# verify-production-doc.sh — assert that "An ideal production configuration.md"
# still describes the platform that is actually in the tree.
#
# This exists because the 1.0 draft of that document drifted for two months into
# naming the wrong Alfresco image, a pre-built AtroCore image whose licensing
# problem had been deliberately engineered away, the wrong PostgreSQL versions,
# the wrong published ports, and none of the three required Docker networks.
# Four of those were not cosmetic: following them would have produced a broken
# or legally problematic deployment. Proofreading did not catch it for two
# months; a script would have caught it the same day.
#
# Run from the workspace root, with the six component repos checked out beside
# this one. Needs no Docker daemon and no .env files — it reads tracked files.
#
# Exit 0 = the document agrees with the tree. Exit 1 = drift; fix one or both.

set -uo pipefail

DOC="An ideal production configuration.md"
FAILED=0
CHECKS=0

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

# ok <description> <condition-exit-code>
ok() {
  CHECKS=$((CHECKS + 1))
  if [ "$2" -eq 0 ]; then
    green "  ok    $1"
  else
    red   "  FAIL  $1"
    FAILED=$((FAILED + 1))
  fi
}

# The document must mention this image, and the compose file must use it.
check_image() {
  local image="$1" composefile="$2"
  grep -qF -- "$image" "$composefile" 2>/dev/null
  local in_compose=$?
  grep -qF -- "$image" "$DOC"
  local in_doc=$?
  if [ $in_compose -ne 0 ]; then
    ok "$image is used by $composefile" 1
  elif [ $in_doc -ne 0 ]; then
    ok "$image (in $composefile) is named in the document" 1
  else
    ok "$image — compose and document agree" 0
  fi
}

# A published host port must be accounted for in the document, so that the
# production profile's port-closure list (§2.3) cannot silently fall behind.
check_port_documented() {
  local port="$1" what="$2"
  grep -qE '`'"$port"'`' "$DOC"
  ok "host port $port ($what) is accounted for in the document" $?
}

banner() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ -f "$DOC" ] || { red "Run me from the workspace root — $DOC not found."; exit 1; }

banner "Images named in the document vs. images in the compose files"
check_image "alfresco/alfresco-governance-repository-community:25.2.0" compliance_cmis/docker-compose.yml
check_image "alfresco/alfresco-search-services:2.0.16"                 compliance_cmis/docker-compose.yml
check_image "alfresco/alfresco-transform-core-aio:5.2.0"               compliance_cmis/docker-compose.yml
check_image "alfresco/alfresco-activemq:5.18-jre17-rockylinux8"        compliance_cmis/docker-compose.yml
check_image "nodered/node-red:4.1.10"                                  compliance_flow/docker-compose.yaml
check_image "traefik:3.6"                                              compliance_cmis/commons/base.yaml

banner "Images the document must NOT resurrect"
# The corrections table (§11) legitimately *quotes* the wrong values in order to
# record what was fixed, so the negative checks below run against the document
# with that section stripped out. Otherwise the record of the fix would read as
# a reintroduction of the bug.
BODY=$(sed '/^## 11\. Corrections applied/,/^## Appendix A/d' "$DOC")

# A pre-built AtroCore image would reintroduce the GPL-3.0 distribution problem
# that was closed by moving the install to container bootstrap.
! printf '%s' "$BODY" | grep -qiE 'image:\s*atrocrm|atrocrmenterprise'
ok "document does not prescribe a pre-built AtroCore image (GPL-3.0)" $?
! printf '%s' "$BODY" | grep -q 'alfresco-content-repository-community'
ok "document does not prescribe the wrong (non-governance) Alfresco image" $?
# ...but the corrections table must still record both, so the history is not lost.
grep -q 'atrocrmenterprise' "$DOC" && grep -q 'alfresco-content-repository-community' "$DOC"
ok "corrections table still records both as fixed" $?
! grep -qE 'atrocrmenterprise|atrocrm:latest' atrocore-docker/docker-compose.yaml
ok "atrocore-docker still builds locally rather than pulling a prebuilt image" $?

banner "Alfresco stack memory limits (the §3 sizing table)"
LIMIT_SUM=$(grep -hoE 'mem_limit:\s*[0-9]+[mg]' \
              compliance_cmis/docker-compose.yml compliance_cmis/commons/base.yaml 2>/dev/null \
            | grep -oE '[0-9]+[mg]' \
            | awk '{ n = $0 + 0; if ($0 ~ /g$/) n *= 1024; total += n } END { print total+0 }')
[ "$LIMIT_SUM" -eq 8832 ]
ok "declared mem_limit total is 8832m as documented (found ${LIMIT_SUM}m)" $?
grep -q '2560m' "$DOC"
ok "document records Alfresco's raised 2560m cap" $?

banner "The three shared Docker networks (ADR-005's constraint)"
for net in backend_net alfresco_backend import-backend; do
  grep -q "$net" "$DOC"
  ok "network $net is named in the document" $?
done
grep -q 'name: backend_net' atrocore-docker/docker-compose.yaml
ok "backend_net is still created by atrocore-docker" $?
grep -q 'name: alfresco_backend' compliance_cmis/docker-compose.yml
ok "alfresco_backend is still created by compliance_cmis" $?
grep -qE 'external:\s*true' compliance_flow/docker-compose.yaml
ok "compliance_flow still only consumes the shared networks" $?

banner "Published host ports (the §2.3 closure list)"
check_port_documented 80   "AtroCore admin UI"
check_port_documented 8080 "Traefik / compliance_web prod"
check_port_documented 8888 "Traefik dashboard"
check_port_documented 8083 "Solr"
check_port_documented 8090 "transform-core-aio"
check_port_documented 5432 "PostgreSQL (Alfresco)"
check_port_documented 1880 "Node-RED"
check_port_documented 8000 "compliance_import"

banner "The host-port-8080 collision stays resolved (P3.3)"
# This check ran in the opposite direction before P3.3: it asserted the
# collision existed and that the document flagged it. Now it asserts the
# collision is gone, so reintroducing it fails here rather than on a
# deployment day when the prod profile refuses to start beside Alfresco.
CMIS_8080=$(grep -c '"${BIND_IP:-0.0.0.0}:8080:8080"' compliance_cmis/commons/base.yaml || true)
[ "${CMIS_8080:-0}" -ge 1 ]
ok "compliance_cmis's Traefik still owns host 8080 (the demo depends on it)" $?

! grep -qE '^\s*- "(\$\{BIND_IP[^"]*\}:)?8080:80"' compliance_web/docker-compose.yml
ok "compliance_web no longer publishes host 8080" $?

grep -q 'Host port 8080 — resolved in P3.3' "$DOC"
ok "the document records the collision as resolved, not live" $?

banner "TLS edge and per-interface binding (P3.3)"
grep -q 'frontend-tls:' compliance_web/docker-compose.yml
ok "a TLS edge service exists" $?

grep -q 'listen 8443 ssl' compliance_web/docker/nginx/tls.conf
ok "the TLS server listens on an unprivileged port (so nginx runs non-root)" $?

# HSTS must appear in the TLS server and NOT in the plain-HTTP one: sending it
# over HTTP is meaningless, and a demo stack sending it would pin a
# developer's browser to HTTPS for a host that does not serve it.
grep -q 'Strict-Transport-Security' compliance_web/docker/nginx/tls.conf
ok "HSTS is set on the TLS server" $?
! grep -q 'Strict-Transport-Security' compliance_web/docker/nginx/default.conf
ok "HSTS is NOT set on the plain-HTTP server" $?

BINDCOUNT=$(grep -l 'BIND_IP' */docker-compose*.y*ml compliance_cmis/commons/base.yaml 2>/dev/null | wc -l)
[ "$BINDCOUNT" -ge 5 ]
ok "BIND_IP governs published ports in $BINDCOUNT compose files" $?

banner "Hardening claims match the tree"
# P3.2 landed, so the document now claims hardening EXISTS. This check runs in
# the opposite direction to the one it replaced: it fails if the hardening is
# removed while the document still advertises it.
HARDENED=$(grep -lE '^\s*(read_only:|cap_drop:)' \
             */docker-compose*.y*ml compliance_cmis/commons/base.yaml 2>/dev/null | wc -l)
[ "$HARDENED" -ge 3 ]
ok "read_only/cap_drop present in $HARDENED compose files (document claims P3.2 done)" $?

# Every service should declare no-new-privileges. This is the control that
# applies everywhere, so a service missing it is a genuine gap rather than a
# documented exception.
NNP=$(grep -c 'no-new-privileges' */docker-compose*.y*ml 2>/dev/null | awk -F: '{t+=$2} END {print t+0}')
[ "$NNP" -ge 10 ]
ok "no-new-privileges declared $NNP times across the compose files" $?

# Digest pinning: the document's image inventory says every external image is
# pinned, so an unpinned one means the two have drifted.
UNPINNED=$(grep -hoE '^\s*image:\s+[a-z0-9./_-]+:[a-zA-Z0-9._-]+\s*$' \
             */docker-compose*.y*ml compliance_cmis/commons/base.yaml 2>/dev/null \
           | grep -v '@sha256' | grep -vc 'compliance-web-backend:local' || true)
[ "${UNPINNED:-0}" -eq 0 ]
ok "every external image reference is digest-pinned" $?

banner "Observability and health claims match the tree (P3.5)"
# The document's P3.5 section is now a claim that things exist, so these run
# in the fail-if-removed direction, like the hardening checks above.

# Every service the health table names must actually serve /health. Grep for
# the definition, not for the word: the runbook mentions these paths too.
grep -q '"url": *"/health"' compliance_flow/flows/17-health.json
ok "compliance_flow serves GET /health (a flow, so reaching it proves flows.json loaded)" $?
grep -q 'Alias /health' atrocore-docker/.docker/health.conf
ok "atrocore-docker serves GET /health" $?
grep -q "app.get('/health'" compliance_web/server/app.cjs
ok "compliance_web serves GET /health" $?
grep -qE '^@app\.get\("/health"\)' compliance_import/main.py
ok "compliance_import serves GET /health" $?

# ...and the four compose healthchecks the table claims.
grep -q 'healthcheck:' compliance_flow/docker-compose.yaml
ok "compliance_flow declares a healthcheck" $?
# Named, not counted. A count check passed a mutation that deleted the
# backend's healthcheck, because four of the five remained -- and the backend
# is the one this tier added and the one every request depends on.
svc_has_healthcheck() { # svc_has_healthcheck <compose file> <service>
  awk -v want="$2" '
    /^  [a-zA-Z0-9_.-]+:/ { svc = $1; sub(/:$/, "", svc) }
    svc == want && /^    healthcheck:/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$1"
}
svc_has_healthcheck compliance_web/docker-compose.yml backend
ok "compliance_web's backend declares a healthcheck" $?
svc_has_healthcheck compliance_web/docker-compose.yml db
ok "compliance_web's db declares a healthcheck" $?
svc_has_healthcheck atrocore-docker/docker-compose.yaml atro-web
ok "atrocore-docker's atro-web declares a healthcheck" $?
svc_has_healthcheck atrocore-docker/docker-compose.yaml db
ok "atrocore-docker's db declares a healthcheck" $?

# The monitoring stack and its drill.
[ -f atrocore-docker/observability/docker-compose.yaml ]
ok "the observability stack exists" $?
[ -x atrocore-docker/scripts/verify-observability.sh ]
ok "the alerting drill exists and is executable" $?
grep -q 'observability:verify' atrocore-docker/.gitlab-ci.yml
ok "observability:verify is wired into CI" $?

# The two probes that catch the measured silent failures. Their absence is the
# single most consequential thing that could quietly regress here.
grep -q 'activemq:61616' atrocore-docker/observability/prometheus/prometheus.yml
ok "ActiveMQ's broker port is probed (the measured silent failure)" $?
grep -q 'solr6:8983' atrocore-docker/observability/prometheus/prometheus.yml
ok "Solr is probed" $?

# The document states these two thresholds and explains why each is not the
# conventional value. If someone "tidies" them to round numbers, the reasoning
# in the document becomes a lie.
grep -q 'container_spec_memory_limit_bytes{container!=""} > 0) > 0.98' \
  atrocore-docker/observability/prometheus/rules/platform-alerts.yml
ok "the memory alert fires at 98%, not 90% (Alfresco idles at 95-97% of its cap)" $?
grep -q 'pg_archiver_ready_count' atrocore-docker/observability/prometheus/rules/platform-alerts.yml
ok "WAL archiving is alerted on by backlog, not by the age of the last archive" $?

# The six auth metrics the readiness doc has named since the auth subsystem
# shipped, and which P3.5 finally emits.
for m in auth_login_success_total auth_login_failed_total auth_login_rate_limited_total \
         auth_session_401_total auth_csrf_mismatch_total auth_session_rotated_total \
         auth_role_refresh_failed_total; do
  grep -q "$m" compliance_web/server/metrics/authMetrics.cjs
  ok "auth metric $m is defined" $?
done

# Structured logging in the two services that emitted free text.
[ -f compliance_import/structured_logging.py ] && [ -f compliance_web/server/logging/structuredLogger.cjs ]
ok "compliance_import and compliance_web both log structured JSON" $?

# Credential redaction. These closed real leaks, so a regression would be
# silent -- and a grep for the word `alf_ticket` is not enough, because the
# file explains at length why it redacts it. Exercise the functions instead:
# deleting the parameter from the list is the mutation that has to fail.
python3 -c "
import sys; sys.path.insert(0, 'compliance_import')
from structured_logging import redact
sys.exit(0 if redact('http://a?alf_ticket=LIVE') == 'http://a?alf_ticket=[redacted]' else 1)
" 2>/dev/null
ok "Alfresco tickets are redacted from compliance_import's logs" $?

node -e "
const { redact } = require('./compliance_web/server/logging/structuredLogger.cjs');
const out = redact('sessionId', 'live-session-value');
process.exit(out !== 'live-session-value' && String(out).startsWith('sha256:') ? 0 : 1);
" 2>/dev/null
ok "session ids are digested in compliance_web's logs" $?

banner "Result"
if [ "$FAILED" -eq 0 ]; then
  green "$CHECKS checks passed — the document matches the tree."
  exit 0
fi
red "$FAILED of $CHECKS checks failed."
red "Either the tree moved and the document needs updating, or the document is wrong."
exit 1

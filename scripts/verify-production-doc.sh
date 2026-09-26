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

banner "The host-port-8080 conflict must stay flagged while it exists"
CMIS_8080=$(grep -c '"8080:8080"' compliance_cmis/commons/base.yaml || true)
WEB_8080=$(grep -c '"8080:80"' compliance_web/docker-compose.yml || true)
if [ "$CMIS_8080" -gt 0 ] && [ "$WEB_8080" -gt 0 ]; then
  grep -q 'Blocking conflict on host port 8080' "$DOC"
  ok "conflict still exists in compose, and the document still flags it" $?
else
  green "  ok    host port 8080 conflict appears resolved in compose"
  CHECKS=$((CHECKS + 1))
  if grep -q 'Blocking conflict on host port 8080' "$DOC"; then
    red "  FAIL  conflict is resolved but the document still describes it as live"
    FAILED=$((FAILED + 1))
    CHECKS=$((CHECKS + 1))
  fi
fi

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

banner "Result"
if [ "$FAILED" -eq 0 ]; then
  green "$CHECKS checks passed — the document matches the tree."
  exit 0
fi
red "$FAILED of $CHECKS checks failed."
red "Either the tree moved and the document needs updating, or the document is wrong."
exit 1

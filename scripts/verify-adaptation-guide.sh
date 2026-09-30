#!/usr/bin/env bash
#
# verify-adaptation-guide.sh — assert that COUNTRY_ADAPTATION_GUIDE.md still
# describes the platform that is actually in the tree.
#
# Its sibling, verify-production-doc.sh, exists because a roadmap document
# drifted for two months into naming files and images that were wrong. This
# guide carries the same risk for a worse reader: an adopting authority's
# technical lead, following it on a tree they have never seen, with no way to
# tell a stale path from their own mistake. Every path it names is an
# instruction to open a file.
#
# The checks that matter most are the ones that fail when the TREE moves and
# nobody thinks to reopen the guide: a new group-to-role mapping added in a
# migration, a renamed seed file, an alert default flipped. Several are
# deliberately assertions of ABSENCE — that no OIDC dependency has appeared,
# that no real alert destination has been committed — because those are the
# promises the guide makes that would otherwise fail silently.
#
# Run from the workspace root, with the six component repos checked out beside
# this one. Needs no Docker daemon and no .env files — it reads tracked files.
#
# Exit 0 = the guide agrees with the tree. Exit 1 = drift; fix one or both.

set -uo pipefail

DOC="COUNTRY_ADAPTATION_GUIDE.md"
FAILED=0
CHECKS=0

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1m%s\033[0m\n' "$*"; }

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

# A path the guide tells an adopter to edit. Both halves matter: the file has
# to exist, and the guide has to still name it — a check that only tested
# existence would keep passing after the guide stopped mentioning the file.
check_path() {
  local path="$1" mention="${2:-$1}"
  if [ ! -e "$path" ]; then
    ok "$path exists" 1
    return
  fi
  grep -qF -- "$mention" "$DOC"
  ok "$path exists and the guide names it" $?
}

[ -f "$DOC" ] || { red "Run me from the workspace root — $DOC not found."; exit 1; }

# ---------------------------------------------------------------------------
banner "Every file the guide tells an adopter to edit"
# ---------------------------------------------------------------------------
check_path compliance_cmis/configs/entity-profile.json
check_path compliance_cmis/configs/entity-logo.png              entity-logo.png
check_path compliance_cmis/tools/smart-folder-catalog.json
check_path compliance_cmis/templates/pilot                      'templates/pilot'
check_path compliance_cmis/scripts/bootstrap-site-content.sh    bootstrap-site-content.sh
check_path compliance_cmis/scripts/seed-demo-identities.sh      seed-demo-identities.sh
check_path compliance_cmis/webscripts/common/vso-paths.lib.js
check_path compliance_cmis/domain-rules/nomenclatura.spec.json
check_path compliance_cmis/docs/smart-folders-operational-map.md
check_path atrocore-docker/sql/seed-nomenclatura-catalog.sql
check_path atrocore-docker/scripts/seed-icao-reference-data.sh
check_path atrocore-docker/scripts/verify-observability.sh      verify-observability.sh
check_path atrocore-docker/scripts/preflight-secrets.sh         'preflight-secrets.sh'
check_path atrocore-docker/data-packs/Normativa.csv             'data-packs/{Reglamento,Normativa}.csv'
check_path atrocore-docker/data-packs/Reglamento.csv            'data-packs/{Reglamento,Normativa}.csv'
check_path atrocore-docker/metadata/entityDefs/Normativa.json
check_path atrocore-docker/observability/alertmanager/alertmanager.yml     'observability/alertmanager/alertmanager.yml'
check_path atrocore-docker/observability/alertmanager/alertmanager.demo.yml alertmanager.demo.yml
check_path compliance_web/src/utils/capEvaluationCriteria.js
check_path compliance_web/server/domain/capEvaluationCriteria.cjs
check_path compliance_web/migrations/0002_closure_reviewer_role.sql        0002_closure_reviewer_role.sql
check_path compliance_web/migrations/0003_group_role_mappings.sql          0003_group_role_mappings.sql
check_path compliance_web/docs/auth/ALFRESCO_ROLE_SETUP.md
check_path compliance_checklist/app.config.json                 app.config.json
check_path "An ideal production configuration.md"
check_path FOOTPRINT_AUDIT.md
check_path RELEASE_READINESS_CHECKLIST.md

# ---------------------------------------------------------------------------
banner "§9 — the group-to-role table matches what the migrations seed"
# ---------------------------------------------------------------------------
# This is the check with the shortest fuse. Adding a role is a migration, and
# nothing about writing that migration prompts anyone to reopen this guide.
MIGRATIONS=$(cat compliance_web/migrations/0002_closure_reviewer_role.sql \
                 compliance_web/migrations/0003_group_role_mappings.sql 2>/dev/null)

# Forward: every row the guide prints is really seeded.
GUIDE_ROWS=$(sed -n '/^## 9\./,/^## 10\./p' "$DOC" \
  | grep -oE '^\| `U-VSO-[^`]+` \| `[a-z_]+` \|' \
  | sed -E 's/^\| `([^`]+)` \| `([^`]+)` \|$/\1 \2/')

GUIDE_ROW_COUNT=$(printf '%s\n' "$GUIDE_ROWS" | grep -c . )
[ "$GUIDE_ROW_COUNT" -gt 0 ]
ok "§9's mapping table was found and parsed ($GUIDE_ROW_COUNT rows)" $?

while read -r group role; do
  [ -z "$group" ] && continue
  printf '%s' "$MIGRATIONS" | grep -qF "'$group'" \
    && printf '%s' "$MIGRATIONS" | grep -qF "'$role'"
  ok "guide row $group -> $role is seeded by a migration" $?
done <<< "$GUIDE_ROWS"

# Reverse: every ACTIVE mapping the migrations seed is printed in the guide.
# Without this the table can silently go stale by omission, which is the
# failure mode that does not announce itself.
SEEDED=$(printf '%s' "$MIGRATIONS" \
  | grep -oE "\('U-VSO-[A-Za-z_]+',\s*'[a-z_]+'" \
  | sed -E "s/\('([^']+)',\s*'([^']+)'/\1 \2/")
# 0002 seeds its row through a SELECT rather than a VALUES tuple.
SEEDED=$(printf '%s\nU-VSO-IN_ClosureReviewer closure_reviewer\n' "$SEEDED")

# U-VSO-EL_EspecialistaLider is deactivated by 0003 on purpose; it must NOT be
# advertised to an adopter as a mapping they get.
while read -r group role; do
  [ -z "$group" ] && continue
  [ "$group" = "U-VSO-EL_EspecialistaLider" ] && continue
  printf '%s\n' "$GUIDE_ROWS" | grep -qF "$group $role"
  ok "seeded mapping $group -> $role is listed in §9" $?
done <<< "$SEEDED"

! grep -q 'U-VSO-EL_EspecialistaLider' "$DOC"
ok "§9 does not advertise the retired EspecialistaLider mapping" $?

# ---------------------------------------------------------------------------
banner "§9 — the claims about how a grant is made"
# ---------------------------------------------------------------------------
SEED_IDS=compliance_cmis/scripts/seed-demo-identities.sh

# The guide sends adopters to this script as the template for granting
# repository access, and specifically claims it shows BOTH halves.
grep -q 'api/sites/.*/memberships' "$SEED_IDS"
ok "seed-demo-identities.sh still grants site membership (half one)" $?
grep -q 'locallySet' "$SEED_IDS" && grep -qE '\-X PUT' "$SEED_IDS"
ok "seed-demo-identities.sh still sets a folder ACL (half two)" $?
grep -q 'SiteConsumer' "$SEED_IDS" && grep -q 'Contributor' "$SEED_IDS"
ok "the narrow SiteConsumer + folder Contributor shape is still what it grants" $?

# The guide promises an adopter needs no identity provider. If an OIDC client
# ever becomes a dependency of the auth path, that promise needs rewriting
# before someone plans an adaptation around it.
! grep -qiE '"(openid-client|oidc-[a-z-]+|passport-openidconnect|keycloak[a-z-]*)"' \
    compliance_web/package.json
ok "compliance_web has taken on no OIDC client dependency" $?
grep -q 'alfresco_group_role_map' compliance_web/server/auth/pgSessionRepository.cjs
ok "roles still resolve through alfresco_group_role_map at session time" $?

# ---------------------------------------------------------------------------
banner "§8 — the alert destination still ships unconfigured"
# ---------------------------------------------------------------------------
COMPOSE=atrocore-docker/observability/docker-compose.yaml
grep -q 'ALERTMANAGER_CONFIG:-alertmanager.demo.yml' "$COMPOSE"
ok "the default really is alertmanager.demo.yml, as the table says" $?

AM=atrocore-docker/observability/alertmanager/alertmanager.yml
grep -q 'name: platform-default' "$AM" && grep -q 'name: platform-critical' "$AM"
ok "alertmanager.yml declares both receivers the guide says to fill in" $?

# "nothing ships configured" — an uncommented notifier block here would mean a
# destination was committed, which is both a broken promise and, for email, a
# credential in a tracked file.
! grep -qE '^\s{1,}(email|webhook|slack|msteams|opsgenie|pagerduty)_configs:' "$AM"
ok "no notifier is left uncommented in alertmanager.yml" $?
grep -qE '#\s*webhook_configs:' "$AM" && grep -qE '#\s*email_configs:' "$AM"
ok "both the webhook and email examples the guide promises are present" $?

# ---------------------------------------------------------------------------
banner "§1 — the ICAO reference data really is the size it claims"
# ---------------------------------------------------------------------------
ICAO_SQL=atrocore-docker/sql/seed-icao-reference-data.sql
count_rows() { # count_rows <table>
  awk -v t="$1" '
    $0 ~ "^INSERT INTO public\\." t " " { inblock = 1; next }
    /^INSERT INTO public\./               { inblock = 0 }
    inblock && /^[[:space:]]*\(.?'"'"'/    { n++ }
    END { print n + 0 }
  ' "$ICAO_SQL"
}
for pair in "documento_o_a_c_i 15 Annex documents" \
            "acapite_o_a_c_i 1890 Annex paragraphs" \
            "usoap_protocol_question 281 Protocol Questions"; do
  set -- $pair
  table="$1"; expected="$2"; shift 2; what="$*"
  actual=$(count_rows "$table")
  [ "$actual" = "$expected" ]
  ok "$what: guide says $expected, seed has $actual" $?
done
# The guide prints 1,890 with a thousands separator in one place and 1890 in
# another; both spellings have to survive a re-count.
grep -q '1,890' "$DOC" && grep -qE '1,890 paragraphs|1,890 Annex' "$DOC"
ok "the paragraph count is still stated in the guide" $?

# ---------------------------------------------------------------------------
banner "Internal structure — cross-references and the summary table"
# ---------------------------------------------------------------------------
SECTIONS=$(grep -oE '^## [0-9]+\.' "$DOC" | grep -oE '[0-9]+' | sort -n)
SECTION_COUNT=$(printf '%s\n' "$SECTIONS" | grep -c .)
[ "$SECTION_COUNT" -ge 9 ]
ok "the guide still has its numbered sections ($SECTION_COUNT found)" $?

# Every §N the prose points at must be a section that exists. Renumbering is
# exactly the edit that breaks these, and it breaks them silently.
BAD_REFS=""
for ref in $(grep -oE '§[0-9]+' "$DOC" | tr -d '§' | sort -un); do
  printf '%s\n' "$SECTIONS" | grep -qx "$ref" || BAD_REFS="$BAD_REFS §$ref"
done
[ -z "$BAD_REFS" ]
ok "every §N cross-reference resolves to a section${BAD_REFS:+ (dangling:$BAD_REFS)}" $?

# Each summary-table row is numbered for the section that explains it.
BAD_ROWS=""
for row in $(sed -n '/^## 10\./,$p' "$DOC" | grep -oE '^\| [0-9]+ \|' | grep -oE '[0-9]+'); do
  printf '%s\n' "$SECTIONS" | grep -qx "$row" || BAD_ROWS="$BAD_ROWS $row"
done
[ -z "$BAD_ROWS" ]
ok "every summary-table row number matches a section${BAD_ROWS:+ (orphans:$BAD_ROWS)}" $?

# Every substitution section from 2 onward should appear in the summary table,
# so the table an adopter scopes their project from cannot lose an item.
MISSING_ROWS=""
for sec in $SECTIONS; do
  [ "$sec" -lt 2 ] && continue
  [ "$sec" -ge 10 ] && continue
  sed -n '/^## 10\./,$p' "$DOC" | grep -qE "^\| $sec \|" || MISSING_ROWS="$MISSING_ROWS $sec"
done
[ -z "$MISSING_ROWS" ]
ok "every section has a summary-table row${MISSING_ROWS:+ (missing:$MISSING_ROWS)}" $?

# ---------------------------------------------------------------------------
banner "Result"
# ---------------------------------------------------------------------------
if [ "$FAILED" -eq 0 ]; then
  green "$CHECKS checks passed — the guide matches the tree."
  exit 0
fi
red "$FAILED of $CHECKS checks failed — the guide and the tree disagree."
exit 1

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **New to this platform as an external adopter (a civil aviation authority or someone evaluating it on one's behalf)?** Start at [`GETTING_STARTED_FOR_ADOPTERS.md`](GETTING_STARTED_FOR_ADOPTERS.md) instead — this file is a dense technical reference for people already working in the code.

## Repository structure

This directory is a **collection of independent repositories**, not a monorepo. The workspace root is itself the thin umbrella meta-repo (`compliance-platform`, published as documentation only, no submodules, with the six component directories and `internal/` gitignored) — each subdirectory below has its own `.git` and is developed/released independently. Always run `git` commands from inside the relevant subdirectory, and treat cross-repo changes as separate commits/MRs in separate repos.

| Directory | What it is | Stack |
|---|---|---|
| `atrocore-docker` | AtroCore/AtroPIM backend (CRM/entity store for inspections, inspectors, specialties, locations) | Docker Compose, Apache+PHP 8.4, PostgreSQL 15 |
| `compliance_cmis` | Alfresco Content Services customization (VSO content model, Share forms, Web Scripts) | Alfresco/ACS, JS Web Scripts, Docker Compose |
| `compliance_flow` | Node-RED integration middleware — the API gateway between the checklist app and AtroCore/Alfresco | Node-RED (flows.json-driven) |
| `compliance_import` | ZIP ingestion service — validates and stores inspection/follow-up payloads into Alfresco | Python, FastAPI, uvicorn |
| `compliance_web` | Web UI for inspection/compliance workflows + auth/session backend | Vue 3 + Vite frontend, Express backend, PostgreSQL |
| `compliance_checklist` | Offline-capable Electron desktop app for field inspectors | Electron, Vue 3, Node.js, Pinia |

Two root-level docs describe the platform as a whole and are the best starting point for any cross-cutting work:

- `atrocore-docker/docs/COMPLIANCE_INTEGRATION_RUNBOOK.md` — startup order, environment/secrets setup, cross-system smoke tests, and failure-isolation guide for the full stack. Its §7 is the **demo quickstart** — the verified clean-clone-to-demonstrable sequence (seeding the synthetic dataset — a fictional ICAO `ZZZZ` airport with demo providers/inspectors/site-visits/inspections via `atrocore-docker/sql/seed-demo-dataset.sql`, matched by demo payload ZIPs under `compliance_import`'s `example data/`, creating the demo identities, populating findings and follow-ups, and walking the closure review), including the traps that cost time to find. Every subproject's own README now has a "Whole-Platform Demo Quickstart" section pointing back here.

  **The demo is executable, not just documented.** `atrocore-docker/scripts/demo-quickstart.sh --yes` takes a running stack to a demonstrable system in one additive, idempotent pass (install → schema → seeds → identities → site content → imports → closure → reporting artifacts); §7 of the runbook is the same sequence by hand; internal tracking (originally twelve, now nine still-open items) records what is verified — as of 2026-09-17: Share smart folders documented but not scripted; a `Pending Closure Review`/`Pending Closure Approval` naming mismatch between `compliance_checklist`'s schema and what the server actually writes (see the closure gate below); and **P3 (production hardening) at 0%** — no Vault, Keycloak, observability, or replication exist yet, so demo credentials must never reach a real deployment. Three items are resolved: the gateway's `API_KEY` now ships **enabled by default** with a shared public placeholder value across `compliance_flow`/`compliance_web`/`compliance_import` (see the Auth section below); the canonical-import search-index race (findings resolved by a deterministic `Hallazgos/<year>/<findingId>.{pdf,json}` node lookup first, search only as fallback — verified live with Solr stopped entirely) is fixed; and `vso:evidenceReviewStatus`'s model description no longer claims an enforcement gate that doesn't exist. Don't assume any other item has closed without checking with the team. Adapting this platform for a different civil aviation authority than the one it was built for (Dominican Republic's IDAC)? See `COUNTRY_ADAPTATION_GUIDE.md` (repo root) — nothing here is a generic multi-tenant product, but the substitution points are documented. On a **fresh clone** three scripts must run before the first import, each because a container writes into a bind mount it does not own: `compliance_cmis/scripts/bootstrap-alf-data.sh`, `compliance_flow/scripts/bootstrap-node-red-data.sh` and — once the stack is up — `compliance_cmis/scripts/bootstrap-site-content.sh` (the site, its folders and the five `.fodt` templates existed only in a provisioned instance until 2026-09-16). `atrocore-docker`'s **`demo:verify`** CI job (manual/scheduled, never a merge gate) does all of that from an empty checkout and runs the quickstart; it is green.
- `FOOTPRINT_AUDIT.md` — the stack's actual resource floor: **8GB RAM minimum, 16GB recommended**, 4–8 vCPU; Alfresco+Solr+two Postgres instances alone idle at ~3.5GiB before this platform's own code runs, with Alfresco's memory cap already at 95–97% utilization idle. Read before promising a lightweight footprint to a resource-constrained deployment target (e.g. a smaller civil aviation authority).
- `An ideal production configuration.md` — target production architecture (3-VM deployment), network policy, security model, DR plan, and ADRs. Treat this as a design/roadmap document, not the current state — it documents future decisions (e.g., Keycloak, Vault) not yet implemented, and carries no separate "not current state" banner on the file itself, so don't let its level of detail read as "already built."

## Big-picture architecture

This is an aviation safety compliance/inspection platform. Data and control flow across services as follows:

```
compliance_checklist (Electron, offline-first)
        │  ZIP export (checklist + evidence) on upload
        ▼
compliance_import (FastAPI, :8000)  ──stores──▶  compliance_cmis / Alfresco (:8080)
        ▲
        │ all queries/CRUD/report+plan generation route through
        │
compliance_flow (Node-RED, :1880)  ───────────▶  atrocore-docker (AtroCore/AtroCRM)
        │                                          entities: inspections, inspectors,
        │                                          specialties, locations, service areas
        └────────────────────────────────────────▶ compliance_cmis / Alfresco (:8080)
                                                     document store, findings, follow-ups

compliance_web (Vue :5173 + Express :4000) ──▶ compliance_flow, Alfresco-backed login, PostgreSQL sessions
```

Key architectural points:

- **compliance_flow (Node-RED) is the integration hub.** Neither `compliance_web` nor `compliance_checklist` talk to AtroCore or Alfresco directly for entity/CRUD/workflow operations — everything routes through Node-RED's REST API (`/queryEntity`, `/inspectionPlan`, `/inspectionReport`, `/importCanonical`, `/findings/open`, etc). The flow logic itself lives in `compliance_flow/data/flows.json`, not in a conventional source tree — changes to middleware behavior are changes to that JSON flow file (edited via the Node-RED editor at `:1880` or directly).
- **compliance_import only writes; it doesn't read.** It's a one-way ZIP-to-Alfresco ingestion path (`/inspection-import`, `/followup-import`) with schema validation (`schema/*.schema.json`), ZIP-bomb protection, and Alfresco credential resolution via `*_FILE` env vars → Docker secrets → plain env vars (in that priority order).
- **compliance_cmis owns the domain model and canonical documents.** The VSO content model (`configs/model/vsoModel.xml`) and Web Scripts (`webscripts/`) define inspection plans/reports, canonical checklist/finding/follow-up documents, and finding-closure rules. `webscripts/common/vso-paths.lib.js` is the single source of truth for all Alfresco folder paths — update it when destination/source folders change, not individual Web Scripts.
- **Inspection status is a state machine, tracked per provider, not per site visit.** A `SiteVisit` covers one visit to a location; each `Inspection` is one provider's work within that site visit and has its own independent status: `Created → Defined → Assigned → Planned → Uploaded → Reported → Complete`, with `Inactive` as a soft-delete state (only reachable pre-`Uploaded`). One inspection can be `Planned` while a sibling inspection on the same site visit is still `Created` — they never block each other. `/inspectionPlan` transitions to `Planned`; `/importCanonical` transitions `Planned → Uploaded`; `/inspectionReport` transitions to `Reported`. Table: `compliance_web/docs/STYLE_GUIDE.md` §12 (more current/precise than the top-level `compliance_web/README.md` table, which predates the per-provider split).
- **compliance_checklist is offline-first.** It stores workspaces locally (`~/Documents/Current_inspection/`), polls API health every 30s, and falls back to bundled fallback data (`app.config.json`) when services are unreachable. Its only network dependencies are `compliance_flow` (reads) and `compliance_import` (ZIP upload).
- **Field naming convention across CMIS payloads** (`compliance_cmis`): `*Id` = canonical internal identifier (required for writes), `*Code` = stable human/search key, `*Name` = display snapshot only. Accept `id`/`code` aliases, normalize to canonical, and reject payloads where both are present but disagree.
- **Data governance / traceability**: `finding.dateIssued` is the canonical field name for finding issue date across `compliance_checklist`, API payloads, and the Alfresco model (renamed from `vso:openedDate` → `vso:dateIssued`) — keep these in sync if touching that field anywhere.
- **Nomenclatura document-ID scheme** (adopted 2026-09): `V-XXXX-YYYY-##` (Visita/SiteVisit), `AV-XXXX-T-####` (Actividad de vigilancia/Inspection), `LV-XXXXT####-EEE` (Lista de verificación/Checklist), `H-XXXXT####-EEE-###` (Hallazgo/Finding), `P-XXXXT####-EEE###-##` (Plan de acciones correctivas/CAP), `S-XXXXT####-EEE###-##` (Seguimiento/Follow-up), where `XXXX`=ICAO location code, `T`=1-letter activity type (A/I/M/D/S — Auditoría/Inspección/Monitoreo/Revisión documental/Análisis de suceso, backed by a new `ActivityType` reference entity in `atrocore-docker`), `YYYY`=year, `EEE`=one of the 16 flat specialty codes (no domain grouping). **Activity codes are independently sequenced from their parent SiteVisit's code** — this used to be the same value, so don't assume they're interchangeable. The canonical spec now lives in one place, `compliance_cmis/domain-rules/nomenclatura.spec.json` — `compliance_web`, `compliance_checklist`, and `compliance_import` each vendor a byte-for-byte copy under their own `domain-rules/`, with a CI-enforced conformance test per repo (e.g. `compliance_web/tests/server/domainRulesConformance.test.js`). Builder/parser logic built from that spec lives in `compliance_web/server/domain/idFormats.cjs` (mirrored in `compliance_web/src/utils/documentCodes.js`), `compliance_import/id_utils.py`/`domain_rules.py`, and `compliance_cmis/webscripts/canonical-model-import/import-canonical-models.post.js` (+ `webscripts/common/vso-follow-up.lib.js`) — if the format ever changes, edit the spec in `compliance_cmis` first and re-vendor into each consumer; the conformance tests fail on drift.

Three Docker networks glue the backend services together and must exist before starting `compliance_flow`: `backend_net` (AtroCore), `alfresco_backend` (Alfresco), `import-backend` (import service). See `atrocore-docker/docs/COMPLIANCE_INTEGRATION_RUNBOOK.md` §2–3 for creation and startup order.

## Finding / follow-up / CAP lifecycle (cross-cutting business rule)

This lifecycle is enforced in `compliance_cmis` (`configs/model/vsoModel.xml`, `webscripts/`) and consumed by `compliance_import` and `compliance_web` — treat the model as the source of truth if the two disagree.

- `vso:finding.vso:findingStatus`: `Open → CAP Submitted → CAP Accepted → In Progress → Pending Closure Review → Verifying Effective Closure → Pending Closure Approval → Closed`, plus `CAP Overdue`, `Solution Overdue`, and `Overdue` (grew from 8 to 11 values in 2026-09 — don't assume older references to just 8 states are current).
- `vso:followUpReport.vso:followUpType` (mandatory): `Progress Review`, `CAP Verification`, `Closure Verification`, `Ad-hoc Inquiry`.
- **Closure gate is two steps, not one.** A follow-up with `followUpType="Closure Verification"` **and** `effectivenessConfirmed=true` only makes a finding *eligible* — it moves the finding to `Pending Closure Approval`, not `Closed`. A separate `closure_reviewer`-role user (see Auth and role model below) must then approve via `compliance_web`'s `PATCH /findings/:findingId/closure-review` (`{"decision":"approve"|"reject"}`) to actually reach `Closed`; a reject clears any closure date rather than leaving it stale. Any other type/flag combination attempting closure at the follow-up-import step must still fail validation (HTTP 400). **Known naming drift**: `compliance_checklist`'s schema still documents `Pending Closure Review` as the state this produces; the server actually writes `Pending Closure Approval` — treat `compliance_cmis`'s webscripts as authoritative until this is reconciled.
- Follow-ups are children of the **finding** (`vso:hasFollowUp`, one finding → many follow-ups), not of the corrective action. A CAP link (`vso:relatedCorrectiveAction`) is optional and can be attached after the follow-up is created; `capId` is not required to create a follow-up.
- `vso:followUpId` auto-generates as `S-<reducedFindingId>-<NN>` when omitted, sequenced per finding (replaced an earlier `FU-XXXXNNNYYY-MM-VV` format in 2026-09 — don't trust old code/docs still referencing `FU-` prefixes).
- `vso:evidenceItem.vso:evidenceRole` (constrained): `Compliance Evidence`, `Finding Support`, `Progress Evidence`, `Closure Evidence`, `RCA Evidence`, `Risk Assessment Evidence`, `Containment Evidence` (grew from 4 to 7 values in 2026-09). A separate, model-unconstrained `vso:evidenceType` vocabulary (`Regulatory Requirement`, `State Certification/Approval`, `Oversight Activity Evidence`) is used by convention only — not enforced by the schema, so validate it in application code if it matters.
- `compliance_cmis` also has `vso:capEvaluation`/`vso:capEvaluationCriterion` content types (manual CAP review against an IDAC-PAC-EVAL-01 checklist), a `vso:findingReviewStatus` (`Pending Review`/`Confirmed`), and residual-risk/severity properties on findings — new in 2026-09, no dedicated doc yet beyond `configs/model/vsoModel.xml` itself.
- Details/edge cases (ID collisions, restart-to-reload requirement, full smoke-test matrix): `compliance_cmis/docs/model-reload-validation-and-smoke-tests.md`.

### USOAP / regulatory evidence domain

`compliance_cmis` also implements ICAO USOAP (Universal Safety Oversight Audit Programme) evidence organization on top of the finding/evidence model — relevant when working on findings, evidence, or reporting features:

- Checklist items and findings are tagged against ICAO Critical Elements `CE-1`...`CE-8` (`vso:usoapCriticalElement`), areas (`vso:usoapAreaCode`), and specific ICAO Protocol Questions (`vso:usoapPqReference`, e.g. "PQ 7.035") resolved via a citation chain rooted in `atrocore-docker`: `UsoapProtocolQuestion` (ICAO PQ) → cites → `AcapiteOACI` (Annex paragraph) → `Normativa` (national regulation article) → `ChecklistQuestion` (checklist-question catalog; renamed from `ProtocolQuestion` in 2026-09 to disambiguate from `UsoapProtocolQuestion`). `compliance_flow`'s Node-RED "getChecklistQuestion" flow resolves this chain per question; `compliance_cmis`'s canonical-import webscript writes the result onto `vso:checklistItem`/`vso:finding` nodes with `vso:usoapTagSource = "Chain-derived"`. For PQs that apply to a whole document/checklist/inspection rather than one checklist item, the same `vso:usoapEvidenceContext` aspect can be applied directly (`vso:usoapTagSource = "Direct"`) — see `compliance_cmis/docs/usoap-evidence-structure.md`.
- `POST /api/usoap/ce-evidence-report` produces an audit-prep report grouped by Protocol Question/area for a given CE, including a `gaps` array flagging evidence missing ICAO references or role/type classification.
- Share "smart folder" navigation (auditor-facing, CE × area × evidence-role/type) is provider-profile-scoped: see `compliance_cmis/docs/smart-folders-operational-map.md` (provider → template mapping) and `compliance_cmis/docs/usoap-evidence-structure.md` before changing folder templates in `compliance_cmis/templates/`.

## Auth and role model (compliance_web)

- **Role catalog**: `admin`, `inspector`, `planner`, `reporter`, `cap_entry`, `assigner` (gates `/assign-inspectors`; previously scoped to a specialty subset by AGA/SNA/VA Alfresco-group membership, but that domain-based scoping was retired along with the domain grouping itself — an assigner now acts across all specialties), and `closure_reviewer` (added 2026-09, mapped from Alfresco group `U-VSO-IN_ClosureReviewer`; gates `PATCH /findings/:findingId/closure-review` — see the finding lifecycle's closure gate above). Route/API authorization uses **any-role match** (user is authorized if `userRoles ∩ requiredRoles` is non-empty); unknown Alfresco groups grant no roles.
- **Roles come from Alfresco group membership**, mapped via the PostgreSQL table `alfresco_group_role_map` (group name → role, `is_active`, `priority`). There is no direct role assignment in the app — to change a user's roles, change their Alfresco group membership or the mapping table, and the user must **log out and back in** (roles are cached in the session and only refreshed on login or the periodic refresh interval). Setup walkthrough and troubleshooting: `compliance_web/docs/auth/ALFRESCO_ROLE_SETUP.md`.
- **Session policy**: idle timeout 30 min, absolute timeout 12 h (never extended), role-cache refresh every 15 min (falls back to cached roles for a grace period on IdP outage), session id rotates on login and privilege elevation.
- **Logout is CSRF-checked before the session cookie is cleared** — a CSRF mismatch returns 403 and leaves the session intact, rather than clearing first and validating after.
- `AUTH_TICKET_ENCRYPTION_KEY` is enforced at startup in production — the server refuses to start without it.
- Full endpoint contract: `compliance_web/docs/auth/AUTH_CHUNK1_API_SPEC.md`; route-to-role matrix: `compliance_web/docs/auth/AUTH_CHUNK1_ROUTE_AUTH_MATRIX.md`; pre-merge CI gate and outage/rollback runbook for anything touching auth: `compliance_web/docs/auth/AUTH_CHUNK8_OPERATIONAL_READINESS.md` (gate = `test:server`, `test:e2e`, `test:auth:all`, `build`, `load:auth:probe`, all passing).

## Working in each subproject

### compliance_web (Vue + Express)

```bash
cd compliance_web
npm install
npm run dev              # frontend dev server (:5173)
npm run server           # auth/session backend (:4000), separate terminal
npm run build             # production frontend build
npm run lint               # ESLint (also writes eslint-report.json)
npm run lint:fix
npm run test                # vitest, all frontend unit tests
npm run test:server         # vitest run tests/server
npm run test:e2e            # vitest run tests/e2e
npm run test:auth:all       # server + e2e + router/store auth-path tests
```

Run a single test file: `npx vitest run tests/server/<file>.test.js` (or any path under `tests/`).

Requires `DATABASE_URL` and `ALFRESCO_BASE_URL` env vars; `AUTH_TICKET_ENCRYPTION_KEY` is required in production (server refuses to start without it). Schema is applied via `npm run db:migrate` (`server/db/migrate.cjs`, `migrations/0001_initial_schema.sql`) — `AUTH_CHUNK1_SQL_DRAFT.sql` is the original draft, not the current bootstrap path. Docs live under `compliance_web/docs/{auth,checklist,shared/operations,archive}/` (the old phase-N doc layout is gone); `docs/endpoints.md` is a generated, CI-verified (`verify:endpoints`) manifest of all routes — treat it as authoritative over any hand-written route list.

**UI conventions** (read `compliance_web/docs/STYLE_GUIDE.md` before touching any view): always use `<BaseButton>`, `<StatusBadge>`, `<LoadingSpinner>` from `src/components/base/` instead of raw `<button>`/loading text/status CSS; never hardcode colors, spacing, or radii — use the `--color-*`/`--space-*`/`--radius-*` tokens in `style.css`; forms use a 2-column CSS Grid with named `grid-cellN` areas plus a `@media (max-width: 768px)` single-column collapse.

**Checklist Manager module** (`ChecklistManager.vue` + `TopicChecklistGroup.vue`) has two distinct Pinia stores that are easy to conflate: `checklistQuestionStore` (renamed from `protocolQuestionStore` in 2026-09, alongside the AtroCore `ProtocolQuestion` → `ChecklistQuestion` entity rename) holds the master, specialty-scoped question catalog (read-only from the app's perspective), while `inspectionQuestionStore` holds the actual per-inspection selections and is what gets mutated on save (save = delete-all-then-recreate for the specialty, not a diff). Details: `compliance_web/docs/checklist/CHECKLIST_MODULE_DOCS.md`.

### compliance_checklist (Electron desktop app)

```bash
cd compliance_checklist
npm install
npm run dev                 # Vite renderer only
npm start                   # full Electron app (after `npm run build`)
npm run build
npm test                    # vitest unit tests
npm run test:coverage
npm run e2e:setup           # one-time: install Playwright browsers
npm run build && npm run e2e   # e2e requires a fresh build first
npm run lint
npm run format
```

Run a single test file: `npx vitest run src/__tests__/<file>.test.js` (renderer) or under `electron/__tests__/`.

Runtime config (API hosts, fallback data) lives in `app.config.json` at the project root — required at runtime and at package time; it also carries an `identity` block (`requireOperator`, `inspectorsPath`) and `api.alfrescoHost` for the **operator identity** feature added 2026-09: workspaces confirm an inspector from `/inspectors` and require an Alfresco sign-in at upload time (password held in memory only, never persisted), stamping `declaredBy`/`inspectorId` onto checklists, findings, and follow-ups. `e2e/global-setup.mjs` temporarily rewrites `app.config.json` to point at local test ports during e2e runs.

### compliance_flow (Node-RED)

No `package.json`, but a real validation suite runs via plain `node`/`node --test` scripts: `validate-flows.mjs`, `verify-endpoints.mjs`, `verify-flow-logic.mjs` (flow-logic checks), `flows-files.test.mjs` (round-trip); plus local-only `smoke-flows.mjs` and `audit-error-envelope.mjs`. CI's `validate:flows` job fails the pipeline if `data/flows.json` and the per-file split (below) drift.

```bash
cd compliance_flow
docker network create backend_net alfresco_backend import-backend   # first time only
docker compose up -d
docker compose down
```

Editor at `http://localhost:1880` (login required — `adminAuth` is enabled). **`data/flows.json` is a generated artifact, not the hand-edited source** (as of 2026-09) — the real editing flow is: edit in the Node-RED editor → `scripts/split-flows.mjs` writes one file per tab/subflow under `flows/` → `scripts/assemble-flows.mjs` rebuilds `data/flows.json`; both `flows/` and `data/flows.json` are tracked and must stay in sync (CI-checked). Credentials are encrypted in `data/flows_cred.json` (never commit plaintext). REST endpoints are protected by `X-API-Key` when `API_KEY` is set — **this now ships enabled by default** (`.env.example`), with the same placeholder value expected in `compliance_web`'s `NODE_RED_API_KEY` and `compliance_import`'s `IMPORT_API_KEY`; it is a public value committed to the repo and must be rotated before any deployment reachable by anyone untrusted.

### compliance_import (FastAPI)

```bash
cd compliance_import
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --host 127.0.0.1 --port 8000     # Swagger at /docs
./run_dryrun.sh                                    # start API, post sample ZIP, stop
```

Tests (unittest, not pytest):

```bash
venv/bin/python -m unittest -v                                     # all tests
venv/bin/python -m unittest tests/test_main_api.py -v               # one file
venv/bin/python -m unittest tests.test_main_api.SomeTestClass.test_x -v  # one test
```

Payload/schema contracts for `inspection-import` and `followup-import` are documented in detail in `compliance_import/README.md` — read it before changing `transformer.py` or `schema/*.schema.json`, since the ZIP structure requirements (required files, evidence folder rules, filename sequencing) are load-bearing for `compliance_checklist` and `compliance_cmis`.

### compliance_cmis (Alfresco/ACS customization)

```bash
cd compliance_cmis
docker compose up -d
docker compose ps
curl -f http://localhost:8080/alfresco/api/-default-/public/alfresco/versions/1/probes/-ready-
npm run lint          # eslint webscripts/ scripts/
npm run lint:fix
```

Smoke tests (REST-based, not a JS test runner):

```bash
export BASE_URL="http://localhost:8080/alfresco/api/-default-/public/alfresco/versions/1"
export USERNAME=admin PASSWORD=admin PARENT_ID="<node-id>"
./scripts/run-model-smoke-tests.sh [--cleanup]
```

After editing `configs/model/vsoModel.xml`, **restart the repository container** to reload the model dictionary — changes are not picked up live. Sample payloads for every Web Script endpoint live under `example/`; update them when contracts change.

Note: `docker-compose.yml` falls back to weak default passwords (e.g. `alfresco`, `secret`) for several services when the corresponding env vars are unset — fine for local dev, but override them explicitly before any demo or public-facing deployment.

### atrocore-docker

```bash
cd atrocore-docker
cp .env.example .env    # set POSTGRES_PASSWORD, POSTGRES_PIM_USER/PASSWORD/DB
docker compose up -d --build   # or: make up
docker compose ps
```

## Cross-repo workflow conventions

Branching model is shared across the JS/Electron subprojects (`compliance_web`, `compliance_checklist`, and generally the others): `main` (stable) / `develop` (integration, MRs target this by default) / `feature/*`, `fix/*`, `hotfix/*`, `release/*`. Commit style favors conventional prefixes (`feat:`, `fix:`) per `compliance_web/CONTRIBUTING.md`.

**Required git workflow for any change to a subproject repo:**
1. Never commit directly to `develop`. Before making any change, check out a new branch from `develop` (`feature/*`/`fix/*`/`hotfix/*` per the pattern above), even if `develop` is the currently checked-out branch.
2. Commit messages and MR titles/descriptions must follow that specific repo's own `CONTRIBUTING.md` (commit-message convention, MR checklist/template, target branch, testing expectations) — don't assume they're identical across repos; read the file each time.
3. After an MR is merged, sync the local `develop` branch with the remote (`git checkout develop && git pull`) before starting any further work in that repo, so subsequent branches are cut from the merged state rather than stale local history.

When making a change that spans services (e.g., a new field on findings), expect to touch: the Alfresco model in `compliance_cmis/configs/model/vsoModel.xml`, the corresponding Web Script(s) in `compliance_cmis/webscripts/`, transform/validation logic in `compliance_import` (`transformer.py`, `schema/`), any Node-RED flow in `compliance_flow/data/flows.json` that surfaces the field, and consuming UI in `compliance_web`/`compliance_checklist`. Each of these is a separate git repo/commit.

# Compliance Platform — Production Architecture & Operations Plan

**Version**: 2.0-draft
**Audience**: Technical stakeholders, operations team, project sponsors
**Last substantive revision**: 2026-09-26 (re-planned against the current tree; supersedes the 2026-07-30 1.0-draft)

**Status**: **Design/roadmap — 0% implemented.** None of the components below (Vault, Keycloak,
PostgreSQL replication, Prometheus/Grafana/Loki, ClamAV, image scanning/signing) exist yet. The
actual running systems today are the single-host Docker Compose setups documented per-repo and the
`atrocore-docker` demo stack described in the root `CLAUDE.md`. This document is the **P3** milestone
plan. If you are adapting this platform for a different civil aviation authority before thinking
about production deployment, read `COUNTRY_ADAPTATION_GUIDE.md` first — this document assumes the
content/branding/specialty adaptation is already done and is about infrastructure, not configuration.

> **What changed in 2.0.** The 1.0 draft was written before the P0–P2 remediation cycles and before
> the September 2026 authorization work. It had drifted into being actively misleading: it named the
> wrong Alfresco image, proposed a pre-built AtroCore image whose licensing problem has since been
> deliberately engineered away, omitted four required containers from its sizing, and specified a
> three-VM topology whose networking cannot work as drawn. Version 2.0 corrects those against the
> tree as it stands on 2026-09-26, replaces the 90-day calendar with evidence-gated tiers, and
> assumes the work is done by one or two people with automation rather than a 2.5-FTE ops team.
> Section 11 records the corrections explicitly, so a reader of the old version can see what moved.

---

## 1. Executive Summary

This document defines the production deployment architecture for the Aviation Safety Compliance
Platform. The platform supports < 50 users with < 5 concurrent sessions, processing < 100 site
inspections per year at a single geographic site.

The deployment target is **one hardened on-premises host** running Docker Compose under systemd.
This is a change from the 1.0 draft's three-VM split — see **ADR-005** for why, and for the specific
technical precondition any future multi-host split has to solve first.

### Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Topology | Single host, Docker Compose + systemd | The platform's three shared Docker networks are single-host bridge networks created by three different repositories. Multi-host requires solving cross-host service discovery first (ADR-005). |
| Orchestrator | Docker Compose + systemd | Sufficient at < 5 concurrent users. K3s/Kubernetes deferred until scale demands it (ADR-001). |
| Hardware floor | 16 GB RAM / 8 vCPU | Measured, not estimated. See §3 and `FOOTPRINT_AUDIT.md`. |
| Identity provider | **Deferred.** Alfresco-backed auth for production v1 | Keycloak is not a login swap — application roles do not grant Alfresco repository permissions. Design spike first (ADR-002, revised). |
| Secrets | File-based secret precedence first, Vault second | `compliance_import` already resolves `*_FILE` → Docker secret → env. Generalising that seam makes Vault a drop-in with no application change. |
| Database HA | **Deferred** with the multi-host decision | Streaming replication to a standby is incoherent on a single host. Backup + verified restore carries the reliability burden instead. |
| TLS termination | `compliance_web`'s existing nginx | It already fronts the SPA and proxies `/api/` and `/nodered/`. Adding TLS there beats introducing a fourth proxy. |
| Email delivery | Alfresco folder rule + SMTP relay | Node-RED writes contact email to a document property; an Alfresco rule sends. |
| Monitoring | Prometheus + Grafana + Loki | Standard OSS stack. Alert thresholds derived from measured failure modes (§5.5). |
| CI/CD | Git-driven deployment with image signing | `git pull` + `docker compose up -d`. SBOM via Syft, scanning via Trivy, signing via Cosign. |

### The one invariant

**The lean demo must keep working.** A clean clone plus `atrocore-docker/scripts/demo-quickstart.sh
--yes` must still produce a demonstrable system after every tier of this plan. The demo/production
distinction is expressed as **compose profiles and additive overrides**, never by replacing the demo
path with a hardened one. `demo:verify` is the per-tier regression gate. See §6.1.

---

## 2. Architecture Overview

### 2.1 Single-host topology (the target)

```
                        ┌─────────────────────────────────┐
                        │      Internal network / WAN      │
                        └────────────────┬────────────────┘
                                         │ TLS 1.2+ (443 only)
        ┌────────────────────────────────┴────────────────────────────────┐
        │                     Single host — 16 GB / 8 vCPU                │
        │                                                                 │
        │   ┌──────────────────────────────────────────────────────────┐  │
        │   │  compliance_web frontend-prod (nginx)  — TLS termination │  │
        │   │  /  → SPA        /api/ → backend:4000                    │  │
        │   │                  /nodered/ → backend:4000 (session +     │  │
        │   │                  API key + Alfresco ticket injected)     │  │
        │   └───────────────────────────┬──────────────────────────────┘  │
        │                               │                                  │
        │   ┌───────────────────────────┴──────────────────────────────┐  │
        │   │  compliance_web backend (Express, :4000, internal)        │  │
        │   └───────────┬───────────────────────────┬──────────────────┘  │
        │               │                           │                      │
        │   ┌───────────┴──────────┐   ┌────────────┴─────────────┐       │
        │   │ PostgreSQL           │   │ compliance_flow          │       │
        │   │ (compliance)         │   │ Node-RED :1880           │       │
        │   └──────────────────────┘   └──────┬──────────┬────────┘       │
        │                                      │          │                │
        │   ┌──────────────────────────────────┴───┐  ┌───┴─────────────┐ │
        │   │  Alfresco stack (compliance_cmis)    │  │ atrocore-docker │ │
        │   │  ├─ alfresco (governance repo 25.2)  │  │ ├─ atro-web     │ │
        │   │  ├─ solr6 (search-services 2.0.16)   │  │ │  (PHP 8.4)    │ │
        │   │  ├─ share                            │  │ └─ PostgreSQL   │ │
        │   │  ├─ transform-core-aio               │  └─────────────────┘ │
        │   │  ├─ activemq          ← REQUIRED     │                      │
        │   │  ├─ PostgreSQL 16.5                  │  ┌─────────────────┐ │
        │   │  └─ traefik (internal routing)       │  │ compliance_     │ │
        │   └──────────────────────────────────────┘  │ import :8000    │ │
        │                                              └─────────────────┘ │
        │   ┌──────────────────────────────────────────────────────────┐  │
        │   │  Observability + ops: Prometheus, Grafana, Loki, Vault,  │  │
        │   │  SMTP relay, backup target                                │  │
        │   └──────────────────────────────────────────────────────────┘  │
        └─────────────────────────────────────────────────────────────────┘

compliance_checklist (Electron, offline-first) reaches :1880 and :8000 from inspector
laptops — via the TLS edge, the only two services with an external non-browser consumer.
```

### 2.2 Why not three VMs

The 1.0 draft specified VM1 (Alfresco + DB), VM2 (AtroCore + Node-RED + web + import + DB) and
VM3 (proxy + observability + standbys). That diagram cannot be deployed as drawn, for a reason the
document never addressed: **the three shared Docker networks are single-host bridge networks.**

| Network | Created by | Consumed as `external: true` by |
|---|---|---|
| `backend_net` | `atrocore-docker/docker-compose.yaml` | `compliance_flow` |
| `alfresco_backend` | `compliance_cmis/docker-compose.yml` | `compliance_flow`, `compliance_import`, `compliance_web` |
| `import-backend` | `compliance_import/docker-compose.yml` | `compliance_flow` |

Every service-to-service hop in §2.3 resolves a container name on one of those bridges. Splitting
the services across hosts breaks all of them at once, and the 1.0 draft declared no networks at all,
proposed no overlay, and specified no host-routable addressing. Solving that is a real workstream —
not a deployment detail — so it is deferred to **ADR-005** rather than assumed away.

### 2.3 Network policy

Corrected for the September 2026 authorization work, which **removed** the browser's direct access
to the gateway. Since the September 2026 proxy lock-down, no browser reaches Node-RED:
`docker/nginx/default.conf` routes `/nodered/` to `backend:4000`, which attaches the session, the
gateway API key and the session's own Alfresco ticket, and refuses writes outside the session's
specialty scope. This materially shrinks the surface the 1.0 plan was designed around.

| Source | Destination | Port | Purpose |
|---|---|---|---|
| Internet/LAN | nginx (TLS edge) | 443 | The only externally published port |
| nginx | `compliance_web` backend | 4000 | SPA API **and** all gateway traffic |
| `compliance_web` backend | Node-RED | 1880 | Entity CRUD, plan/report — session-scoped |
| `compliance_web` backend | Alfresco | 8080 | Login, tickets, findings |
| `compliance_web` backend | PostgreSQL (compliance) | 5432 | Sessions, audit, notifications |
| `compliance_checklist` | Node-RED (via edge) | 443→1880 | Reads: checklist, findings, specialties |
| `compliance_checklist` | `compliance_import` (via edge) | 443→8000 | ZIP upload |
| `compliance_checklist` | Alfresco (via edge) | 443→8080 | Operator sign-in at upload time |
| Node-RED | AtroCore | 80 | AtroCore API |
| Node-RED | Alfresco | 8080 | Content operations |
| Node-RED | `compliance_import` | 8000 | Import triggers |
| `compliance_import` | Alfresco | 8080 | CMIS uploads |
| Alfresco | Solr | 8983 | Search index |
| Alfresco | ActiveMQ | 61616 | Async work — **required**, see §5.5 |
| Alfresco | transform-core-aio | 8090 | PDF rendering |
| Alfresco | SMTP relay | 25/587 | Email delivery |
| Prometheus | all services | various | Metrics scraping |
| Ops | host | 22 | SSH, key-only |

**Nothing else is published to the host.** Every port below is published today and must be closed
or bound to localhost in the production profile (§6.5):

| Port(s) | Service | Published by |
|---|---|---|
| `80` | **AtroCore admin UI** | `atrocore-docker` |
| `8080`, `8888` | Traefik routing + **unauthenticated dashboard** (§4.6) | `compliance_cmis/commons/base.yaml` |
| `8083` | Solr admin | `compliance_cmis` |
| `8161`, `5672`, `61616`, `61613` | ActiveMQ (console + AMQP + OpenWire + STOMP) | `compliance_cmis` |
| `8090` | transform-core-aio | `compliance_cmis` |
| `5432` | PostgreSQL (Alfresco) | `compliance_cmis` |
| `5433` | PostgreSQL (compliance) | `compliance_web` dev override — must not be used in production |
| `3000` | Vite dev server | `compliance_web` dev profile — prod profile publishes `8080:80` instead |
| `4000` | Express backend | `compliance_web` dev override only |

`1880` (Node-RED) and `8000` (import) stay reachable, but only through the TLS edge, because
`compliance_checklist` is an external consumer of both. AtroCore's port 80 is the most easily
overlooked of these: it is a full admin UI with no reverse proxy in front of it.

> **Blocking conflict on host port 8080.** `compliance_cmis`'s Traefik binds `8080:8080`, and
> `compliance_web`'s **`prod` profile** binds `8080:80`. On one host they cannot both start — the
> second fails with "port is already allocated". This has never surfaced because the demo and every
> documented bring-up run `compliance_web` in its **`dev`** profile on `3000`, so the production
> profile has never been started next to the Alfresco stack. Resolving this is a **precondition** of
> the single-host target, not a detail of it: the TLS edge takes `443`, Traefik moves to a
> localhost-bound port, and nothing else publishes `8080` at all. Tracked in §6.5.

---

## 3. Component Sizing

**These numbers are measured, not estimated.** Source: `FOOTPRINT_AUDIT.md` (2026-09-15, a 23-probe
matrix run against the live stack with one component stopped at a time) plus the `mem_limit` values
declared in the compose files as they stand today.

The 1.0 draft's sizing table listed only Alfresco, Solr and one PostgreSQL on VM1. It omitted
**Share**, **ActiveMQ**, **transform-core-aio** and the **Traefik proxy** — roughly 3.7 GiB of
declared limits — which is why its 8 GB VM1 could not have worked.

### 3.1 The Alfresco stack (`compliance_cmis`)

| Service | Declared `mem_limit` | Measured idle | Required? |
|---|---|---|---|
| `alfresco` (governance repo 25.2.0) | **2560m** | 1759–1799 MiB | Yes |
| `solr6` (search-services 2.0.16) | 2048m | 1482–1614 MiB | **Yes** — backs every AFTS query; the regulatory core |
| `share` | 1024m | 592–765 MiB | Droppable, with a real capability loss (the USOAP smart-folder evidence browser) |
| `transform-core-aio` | 1536m | 534–639 MiB | Conditional — plan/report generation fails cleanly without it; canonical import self-heals |
| `activemq` | 1024m | 212–336 MiB | **Yes** — and it has the worst failure mode of any component (§5.5) |
| `postgres` (16.5) | 512m | 107–114 MiB | Yes |
| `traefik` (internal routing) | 128m | 90–98 MiB | Yes |
| **Subtotal** | **8832m ≈ 8.6 GiB** | **≈ 4.8–5.4 GiB** | |

Note Alfresco's cap is already at **95–97% utilisation at idle**. It was raised 1900m → 2560m on
2026-09-17 for exactly this reason. Do not tighten it further without re-running the audit.

### 3.2 Everything else

| Service | Declared limit | Measured idle |
|---|---|---|
| `atro-web` (AtroCore, PHP 8.4) | none | 452–459 MiB |
| `postgres` (AtroCore, 15-alpine) | none | 60–62 MiB |
| `node-red` (4.1.10) | none | 122–133 MiB |
| `compliance_web` backend + frontend + `postgres` 16-alpine | none | ≈ 400 MiB combined |
| `compliance_import` (FastAPI) | none | ≈ 100 MiB |

### 3.3 The floor

| | RAM | vCPU | Verdict |
|---|---|---|---|
| Measured idle, full stack | ≈ 5.8–6.5 GiB | — | Before a single report is generated |
| Declared limits, full stack | ≈ 9.5–10 GiB | — | What the stack is allowed to consume |
| **Absolute minimum** | **8 GB** | 4 | Workable but tight; Alfresco at 95–97% of cap idle |
| **Production floor** | **16 GB** | **8** | Headroom for report generation and real document volume |

**The footprint is structural, not pruning-able.** Alfresco + Solr + two PostgreSQL instances is
~3.5 GiB before any of this platform's own code runs. Dropping both optional components (Share and
transform) saves only ~1.1–1.4 GiB. A 4 GB target is not achievable by configuration; it would
require replacing Alfresco as the document store, which is a 1,466-line content model and ten
Web Script areas of work.

### 3.4 Storage

| Component | Initial | Annual growth | 3-year total | Type |
|---|---|---|---|---|
| Alfresco content store | 50 GB | 5 GB | 65 GB | SSD |
| PostgreSQL (Alfresco) | 20 GB | 3 GB | 29 GB | SSD |
| Solr indexes | 10 GB | 2 GB | 16 GB | SSD |
| AtroCore DB | 10 GB | 2 GB | 16 GB | SSD |
| PostgreSQL (compliance) | 5 GB | 1 GB | 8 GB | SSD |
| Prometheus + Loki | 25 GB | 12 GB | 60 GB | HDD acceptable |
| Backups (30-day retention, four datasets) | 60 GB | 18 GB | 115 GB | HDD, **separate volume** |
| Docker images + volumes | 25 GB | — | 25 GB | SSD |
| **Total** | **205 GB** | **43 GB** | **~335 GB** | |

**Recommendation**: 300 GB SSD + 250 GB HDD (or a NAS mount) for backups. Backups must not share a
volume with the data they protect.

---

## 4. Security Model

### 4.1 Authentication & Authorization

| Component | Current | Production v1 | Later |
|---|---|---|---|
| User identity | Alfresco-backed login | **Unchanged** — Alfresco-backed | Keycloak OIDC, after the §6.8 spike |
| Role source | Alfresco groups → `alfresco_group_role_map` | Unchanged | Decided by the spike |
| Service-to-service | `X-API-Key` (shared gateway key) | Generated key, delivered as a file-based secret | mTLS or OAuth2 client credentials |
| Session management | PostgreSQL sessions | Unchanged | JWT if Keycloak lands |
| Repository permissions | Alfresco site/folder grants, provisioned separately | Group-level grant, not per-user (§6.4) | Unchanged — this is the hard part of any IdP migration |

**The dual authorization plane is the reason identity migration is deferred.** An application role
does not grant an Alfresco permission. `compliance_web` derives roles from Alfresco group membership,
but every writing role separately needs repository access provisioned (the site-Consumer +
folder-Contributor shape in `compliance_web/docs/auth/ALFRESCO_ROLE_SETUP.md`). An OIDC login does
not remove that requirement — it adds a second identity space that must be reconciled with it.
`internal/role-access-map.md` documents the current model in full.

What is already implemented and should be kept, not rebuilt:

- Any-role-match route authorization; unknown Alfresco groups grant no roles.
- Session policy: 30-minute idle, 12-hour absolute (never extended), 15-minute role-cache refresh
  with a cached-role grace period on IdP outage, session id rotation on login and privilege elevation.
- Logout is CSRF-checked **before** the cookie is cleared.
- `AUTH_TICKET_ENCRYPTION_KEY` enforced at startup in production — the server refuses to start.
- Secure/httpOnly/sameSite cookies, on by default in the compose production settings.
- A PostgreSQL-backed auth audit trail (`server/auth/pgAuditLogger.cjs`) and a PostgreSQL-backed
  login rate limiter with in-memory fallback.
- Session-level specialty scope, field-level and ownership-level gateway authorization.

### 4.2 Network Security

- One externally published port: 443 on the nginx edge.
- All inter-service traffic stays on the Docker bridge networks; no service but the edge publishes
  a host port.
- SSH key-only, no password authentication.
- Host firewall denies inbound by default.

### 4.3 Secrets Management

Sequenced so that Vault is the *last* step, not the first:

1. **Rotate what is public now.** The gateway key ships as the committed placeholder
   `demo-only-CHANGE-BEFORE-ANY-PUBLIC-DEPLOYMENT`, identical across `compliance_flow`'s `API_KEY`,
   `compliance_web`'s `NODE_RED_API_KEY` and `compliance_import`'s `IMPORT_API_KEY`. The demo
   identities and the `compliance_cmis` compose fallbacks (`DB_PASSWORD:-alfresco`,
   `SOLR_SECRET:-secret`) are in the same category.
2. **Generalise the file-based secret seam.** `compliance_import` already resolves credentials by
   `*_FILE` → Docker secret → plain env, in that order. Extend the same precedence to
   `compliance_flow` and `compliance_web` so every secret can arrive as a file.
3. **Then add Vault**, as an agent that writes those files. No application change is required at
   that point, which is what makes this ordering worth the extra step.
4. Rotation policy: database credentials every 90 days; signing keys with overlap windows.
5. Vault audit log shipped to the same place as the application audit trail.

Note that P0 already did the part the 1.0 draft's Month 1 assumed was outstanding: secrets are
untracked, ignored, rotated and **purged from git history** (verified — zero commits touching
`.env`, `flows_cred.json` or the database dumps remain in either GitLab project).

### 4.4 Container Security

Current state: **zero** `deploy.resources`, `user:`, `read_only:` or `cap_drop` in any of the six
compose files, and every image pinned by mutable tag with no digest anywhere. One exception worth
reusing as the reference: `compliance_import/Dockerfile` already does `USER appuser`.

Target: resource limits, non-root users, read-only root filesystems with explicit `tmpfs` mounts,
`cap_drop: [ALL]`, restart policies, digest-pinned images, and no Docker socket mounted into any
container that does not require it (§4.6).

**Expect friction here.** Three bootstrap scripts exist precisely because containers write into
bind mounts they do not own; adding `user:` collides with that directly. Harden one service per
commit, with `demo:verify` after each.

### 4.5 File Upload Security

- ZIP bomb controls — **already implemented**: max size, compression ratio, path traversal.
- Streaming to disk rather than buffering — already implemented (P0).
- ClamAV sidecar on `compliance_import` with a quarantine directory — outstanding.
- Immutable audit trail for uploaded evidence — partially present via Alfresco versioning.

### 4.6 Proxies already in the stack

The 1.0 draft proposed a new NGINX and never mentioned that the platform already runs two proxies:

1. **`compliance_cmis`'s Traefik** (`commons/base.yaml`) — an *active*, internal routing proxy for
   Alfresco/Share/control-center, running `traefik:3.6` with `--api.insecure=true`, publishing
   `8080:8080` and `8888:8888` to the host, with `/var/run/docker.sock` mounted read-only. **The
   unauthenticated dashboard on 8888 is a finding, not a design choice.** Drop `--api.insecure`,
   stop publishing 8888, and bind the web entrypoint to localhost.
2. **`atrocore-docker`'s Traefik template** (`traefik/*.example`) — a complete Let's Encrypt/ACME
   configuration that is **not referenced by any tracked compose file**. It is a usable starting
   point for the edge, currently inert.

The TLS edge should be `compliance_web`'s existing nginx (`docker/nginx/default.conf`), which
already terminates the SPA and proxies both `/api/` and `/nodered/`. It currently listens on port
80 only, with no HSTS and no CSP anywhere in the tree.

---

## 5. Reliability & Disaster Recovery

### 5.1 Availability Targets

| Component | Target | Strategy |
|---|---|---|
| `compliance_web` | 99.5% | systemd auto-restart + healthcheck |
| Node-RED | 99.5% | systemd auto-restart + healthcheck |
| AtroCore | 99.5% | systemd auto-restart + healthcheck |
| Alfresco | 99.0% | Daily backup; restore from backup on failure |
| PostgreSQL (both) | 99.5% | Daily dump + WAL archiving; verified restore |

### 5.2 Recovery Objectives

| Metric | Target |
|---|---|
| RPO | 15 minutes (WAL archiving) |
| RTO | 4 hours (core workflows, single host, restore from backup) |

> **These are targets, not measurements.** They remain unevidenced until the `restore:verify` job in
> §6.5 is green. The 1.0 draft's 2-hour RTO assumed a warm standby to promote; on a single host with
> restore-from-backup, 4 hours is the honest number until a drill proves otherwise. Do not quote
> either figure to a stakeholder as a commitment before the drill has run.

### 5.3 Backup Coverage — current state

**One of four datasets is covered today.** `atrocore-docker/scripts/backup-db.sh` and
`restore-db.sh` are real and working, but scoped to the AtroCore database only, and invoked
manually or as a CI non-emptiness assertion — there is no schedule.

| Dataset | Covered today | Frequency | Retention | Method |
|---|---|---|---|---|
| PostgreSQL (AtroCore) | **Yes**, manual | Daily full + WAL | 30 days | `pg_dump` + WAL archiving |
| PostgreSQL (Alfresco) | **No** | Daily full + WAL | 30 days | `pg_dump` + WAL archiving |
| PostgreSQL (compliance) | **No** | Daily full + WAL | 30 days | `pg_dump` + WAL archiving |
| Alfresco content store | **No** | Daily incremental, weekly full | 30 days | `rsync` to a separate volume |
| Vault data | n/a (not deployed) | Daily | 90 days | Vault snapshot |
| Compose configs + `.env` structure | Git | Continuous | Permanent | Git |

A database backup without the matching content store is not a restorable system: Alfresco's metadata
and its binaries must be restored from the same point in time.

### 5.4 Disaster Recovery Runbook (outline)

1. **Detect** — Prometheus alert (service down > 2 min, or the hang signatures in §5.5).
2. **Diagnose** — `docker compose ps`, container health, then `atrocore-docker/docs/COMPLIANCE_INTEGRATION_RUNBOOK.md` §8 (failure isolation).
3. **Restore databases** — all three, to a consistent point in time.
4. **Restore content** — the Alfresco content store from the matching snapshot.
5. **Reindex** — Solr may need a rebuild; it is derived state, not a backup target.
6. **Verify** — run the existing smoke matrix (runbook §6, 15 probes) plus `smoke-flows.mjs`.
7. **Notify** — per the communication plan.

### 5.5 Failure modes worth alerting on specifically

Generic "service down" alerting is not sufficient here, because the measured failure modes are
inconsistent and two of them are silent. From `FOOTPRINT_AUDIT.md`:

| Component stopped | Probes passing | Failure shape |
|---|---|---|
| **ActiveMQ** | 22/23 | **Indefinite hang, no error, no timeout.** The work completes — the PDF is written — and the response never returns. Restarting the broker clears it instantly. |
| **Solr** | 17/23 | Split: Web Scripts fail fast with a clean HTTP 500; the *gateway* endpoints hang with no response. |
| **transform-core-aio** | 20/23 | Clean HTTP 500; canonical import degrades gracefully and self-heals on a later render. |
| **Share** | 23/23 | Nothing breaks in the API path; loses the auditor-facing USOAP evidence browser. |

ActiveMQ is the priority alert: for an unattended deployment, an indefinite hang with no error is
the worst available failure mode, because nothing surfaces and no timeout fires.

---

## 6. Implementation Plan — evidence-gated tiers

This replaces the 1.0 draft's Month 1 / Month 2 / Month 3 calendar. The calendar implied a staffed
programme running to a date; this is a backlog running to **evidence**. Tiers are ordered by
risk reduction per unit of effort. Each has an **exit gate that is a command someone can run**, and
each gate becomes a CI job so it stays true afterwards.

Every item is a tracked, idempotent artifact in a repository — the pattern
`atrocore-docker/scripts/demo-quickstart.sh` already establishes. No item may be satisfied by a
hand-run step that leaves nothing behind.

Each tier is a separate branch and merge request **per repository**, cut from `develop`, following
that repository's own `CONTRIBUTING.md`.

### 6.1 The invariant: the lean demo survives every tier

A clean clone plus `demo-quickstart.sh --yes` must still produce a demonstrable system when all of
this is done. This is not automatic — three tiers break it unless designed not to.

| Tier | Risk | Required design |
|---|---|---|
| **6.3** Secrets | **Highest.** The demo depends on the placeholder key and the `DB_PASSWORD:-alfresco` / `SOLR_SECRET:-secret` fallbacks being defaults. A preflight that refuses live placeholders refuses the demo by construction. | `preflight-secrets.sh` takes a profile: `demo` permits placeholders and prints the existing warning banner; `production` refuses them. The quickstart **generates** `.env` files rather than relying on committed defaults — `demo-verify-ci.sh` already writes them for the five sibling repos. |
| **6.4** Hardening | **Likeliest silent breakage.** `user:` collides with the three bootstrap scripts that exist because containers write into bind mounts they do not own. `read_only` breaks anything writing its own rootfs. Alfresco idles at 95–97% of cap. | One service per commit, `demo:verify` after each. `atro-web` and `alfresco` are the hard cases; expect `tmpfs` for each `read_only` service. |
| **6.5** TLS / ports | `smoke-flows.mjs`, the quickstart's readiness probes and runbook §6 all hit plain HTTP on `:8080`, `:1880`, `:8000`, `:3000`. | TLS and port-unpublishing ship as a **production profile/override**. The plain-HTTP single-host demo path stays intact. Unpublishing Solr/ActiveMQ/transform/Postgres is demo-safe; unpublishing `:1880` is not. |
| **6.7** Field app | The packaged app defaults every host to `localhost`, which is what makes the one-machine demo work. | Signing and auto-update are additive; `localhost` stays the default in `app.config.json`. |

Tiers that **improve** the demo: 6.6 replaces the quickstart's `/specialties` health stand-in with a
real endpoint, and the parallel track (§6.9) scripts the last manual Share step and fixes the
closure-status naming drift.

**Exit criterion for P3 as a whole:** `demo:verify` green **and** a production-profile deployment
passing `preflight-secrets.sh --production`, from the same tree.

### 6.2 P3.0 — Correct this document
*Gate: every image, port and network named here appears in `docker compose config` output for all six repos.*

- Apply the §11 corrections (done — this revision).
- Record **ADR-005** (single host first) with the bridge-network constraint as the precondition for
  any future split.
- Re-derive §3 from `FOOTPRINT_AUDIT.md` and the declared `mem_limit`s (done).
- Regenerate Appendix A from the five `.env*.example` files; replace Appendix B's skeleton with a
  pointer to the real compose files — a hand-maintained skeleton is what produced four of the
  §11 errors.
- Update `RELEASE_READINESS_CHECKLIST.md`, `CLAUDE.md` and `internal/TECHNICAL_DEBT_ANALYSIS.md` §5
  to reference these tiers instead of "the existing roadmap."

### 6.3 P3.1 — Secrets that are actually secret — **DONE (2026-09-26)**
*Gate: a fresh production deployment starts with zero credentials that exist in any public repository.*

**Delivered**, as five merge requests. `compliance_flow/data/secrets.js`,
`compliance_web/server/config/secrets.cjs` and `compliance_import/secret_config.py` implement the
same precedence and each refuses published values at startup;
`compliance_cmis/docker-compose.yml` no longer carries weak fallbacks;
`compliance_checklist` flags the placeholder when it is typed in; and
`atrocore-docker/scripts/preflight-secrets.sh` is the gate, with a 19-check self-test in CI.
Vault itself is deliberately **not** deployed — the file-based seam is in place, which is what
makes adding it a no-op for application code. Remaining for a real deployment: generate and
distribute the actual values, and remove the demo identities.

- Generate and distribute a real gateway key across `compliance_flow`, `compliance_web`,
  `compliance_import` and `compliance_checklist`'s stored copy.
- Remove `compliance_cmis`'s `DB_PASSWORD:-alfresco` and `SOLR_SECRET:-secret` fallbacks; fail loudly
  instead, matching the `${AUTH_TICKET_ENCRYPTION_KEY:?}` pattern `compliance_web` already uses.
- Extend `compliance_import`'s `*_FILE` → Docker secret → env precedence to `compliance_flow` and
  `compliance_web`.
- Remove or rotate the demo identities (`demo.inspector1`, `closure.reviewer`, `ci_admin`).
- New `atrocore-docker/scripts/preflight-secrets.sh`, profile-aware per §6.1, wired into CI.
- Only then: Vault, as an agent writing the secret files.

### 6.4 P3.2 — Container hardening and supply chain
*Gate: `docker compose config` shows limits, non-root and read-only rootfs on every service; CI fails on a HIGH CVE.*

- `deploy.resources.limits`, `user:`, `read_only:` + `tmpfs`, `cap_drop: [ALL]` and `restart:` across
  all six compose files plus `compliance_cmis/commons/base.yaml`.
- Harden the Traefik finding in §4.6: drop `--api.insecure=true`, stop publishing `:8888`.
- Constrain `compliance_import/requirements.txt` — currently five bare package names with no
  versions, no lockfile and no hashes. `pip-compile` to a hash-pinned lockfile.
- Digest-pin every image; there are zero `@sha256` references in the tree today.
- Add Trivy (image + filesystem), Syft (SBOM) and Cosign (signing) to all six pipelines. **No
  repository has any security-scanning job today.**
- Fold in the reviewer-group grant: `seed-demo-identities.sh` still grants each demo user
  membership directly, which is broader than the intended `SiteConsumer` + `Contributor` shape.

### 6.5 P3.3 — TLS and the network edge
*Gate: every externally reachable port is TLS-only; nothing else is published to the host.*

- **Resolve the host-port-8080 conflict first** (see §2.3). `compliance_cmis`'s Traefik and
  `compliance_web`'s `prod` profile both claim it, so the production profile cannot currently start
  next to the Alfresco stack at all. Traefik moves to a localhost-bound port; the edge takes 443.
  This blocks the rest of the tier.
- Add `listen 443 ssl`, HSTS and a CSP to `compliance_web/docker/nginx/default.conf`. None of
  `helmet`, HSTS or CSP exists anywhere in the tree today.
- Certificates via the Let's Encrypt config already written at `atrocore-docker/traefik/*.example`,
  or an enterprise CA.
- Unpublish every port in the §2.3 list. `:1880` and `:8000` stay reachable, but only through the
  edge, because `compliance_checklist` needs them.
- Set `trust proxy` correctly for the new edge and re-verify secure-cookie behaviour end to end.

### 6.6 P3.4 — Backup, restore, and a drill that actually ran
*Gate: a scripted restore into a blank host reproduces a working system, proven in CI.*

- Extend `backup-db.sh`/`restore-db.sh` to all three databases **and** the Alfresco content store.
- WAL archiving; a retention policy; a systemd timer that is itself a tracked artifact.
- Backups land on a volume separate from the data they protect.
- **`restore:verify` CI job**, modelled on `demo:verify`: empty checkout → restore → run the existing
  smoke matrix. This is the only honest evidence for §5.2, and until it is green those numbers stay
  labelled as targets.
- PostgreSQL streaming replication stays deferred with ADR-005.

### 6.7 P3.5 — Observability and health
*Gate: every service exposes health; one dashboard covers the stack; killing any container fires an alert.*

- Add `/health` to **`compliance_flow`** (a new `http in` node — edit under `flows/`, then re-assemble
  `data/flows.json` via `scripts/assemble-flows.mjs`; never hand-edit the generated file) and to
  **`atrocore-docker`**. Then retire the quickstart's `/specialties` stand-in.
- Add compose `healthcheck:` blocks to `compliance_flow`, `compliance_import`, `atrocore-docker` and
  `compliance_web`'s `backend` — today only `compliance_cmis` (5) and `compliance_web`'s
  `db`/`frontend-*` (3) have any.
- Prometheus + Grafana + Loki; scrape container metrics and the health endpoints.
- Alert on the **measured** failure modes in §5.5, especially the ActiveMQ hang and the Solr
  gateway hang — not just process liveness.
- Ship the existing auth audit trail (`pgAuditLogger.cjs`) and the six metrics already named in
  `compliance_web/docs/auth/AUTH_CHUNK8_OPERATIONAL_READINESS.md` §6. Do not invent a new scheme.
- Structured logging: `compliance_import` and `compliance_web` both emit unstructured text today.

### 6.8 P3.6 — Field-app distribution
*Gate: an inspector installs a signed build and receives an update without a manual re-download.*

`compliance_checklist` currently ships as an **unsigned portable executable** with the code-signing
block commented out and **no `publish:` target at all** — no auto-update, no distribution channel.
For a binary handed to inspectors in the field, that is a production gap.

- Enable code signing in `electron-builder.config.js`; obtain certificates.
- Add a `publish:` target and `electron-updater`; choose the channel.
- Provide a provisioning path for the four `app.config.json` hosts (`host`, `importHost`,
  `uploadHost`, `alfrescoHost`), all of which default to `localhost`. The packaged build reads a
  writable copy under `userData`, which is the natural seam.

### 6.9 P3.7 — Identity: spike only
*Gate: a written decision, not an implementation.*

Production v1 ships on Alfresco-backed auth. Produce a design spike that answers three questions
before any migration work is scheduled:

1. What is the role source of truth — Alfresco groups, Keycloak groups, or the mapping table?
2. How does an OIDC identity receive its **Alfresco repository grants**? This is the hard part; see
   §4.1. An OIDC login does not provision repository access.
3. What replaces `compliance_checklist`'s sync-time Alfresco password prompt? Alfresco tickets are
   short-lived and there is no refresh token — this is the concrete driver for the migration.

Then revisit **ADR-002**.

### 6.10 Parallel track — open correctness items

Tracked in `internal/TECHNICAL_DEBT_ANALYSIS.md` §4.8. Not infrastructure, but in scope for the same
push, because most of them are things an adopter meets in the first hour.

| Item | Home |
|---|---|
| Share smart folders documented but not scripted | Script against Share's API, or accept as a documented setup step |
| Reviewer group grant is per-user in the seed | Folded into §6.4 |
| Operator attribution dropped on the standalone follow-up path | `compliance_cmis` — a traceability gap; treat as security-adjacent |
| `inspectorRoles` / `findingClass` lack `es_DO` labels | `atrocore-docker` — cosmetic, cheap |
| `Pending Closure Review` vs `Pending Closure Approval` drift | `compliance_checklist` schema vs. the server; the server is authoritative |
| Closure walkthrough unverified in the UI | Add an e2e case |
| Dead `fodt to odt` Share rule on provisioned instances | Document or delete |
| `demo:verify` has no schedule | Schedule it nightly |

**Explicitly out of scope:** the follow-up evidence-review redesign and the
`vso:closureRejectionReason` erasure question. Both are product decisions, not P3 work.

---

## 7. Resource Requirements

### 7.1 Hardware

| Resource | Specification |
|---|---|
| Host | 8 vCPU, **16 GB RAM**, 300 GB SSD |
| Backup volume | 250 GB, separate physical volume or NAS mount |
| Network | 1 Gbps LAN |

Absolute minimum is 4 vCPU / 8 GB, which runs but leaves Alfresco at 95–97% of its memory cap at
idle. See §3.3.

### 7.2 Software & Licences

| Component | Licence | Cost |
|---|---|---|
| Ubuntu Server LTS | Free | $0 |
| Docker CE + Compose | Free | $0 |
| Alfresco Governance Repository Community 25.2.0 | LGPL-3.0 family | $0 |
| AtroCore | **GPL-3.0-only** (core). Installed at container bootstrap, never baked into an image — see `atrocore-docker/THIRD_PARTY_LICENSES.md` | $0 |
| Keycloak (if adopted later) | Apache 2.0 | $0 |
| HashiCorp Vault | BUSL-1.1 for current releases; MPL-2.0 for ≤ 1.14. **Verify the licence of the version you deploy** | $0 |
| Prometheus + Grafana + Loki | Apache 2.0 / AGPL-3.0 (Grafana ≥ 9, Loki) | $0 |
| Postfix | IBM Public License | $0 |
| TLS certificate | Let's Encrypt or enterprise CA | $0–$500/yr |
| ClamAV | GPL-2.0 | $0 |

Licence questions for the platform's own distribution are tracked separately in W1 of
`RELEASE_READINESS_CHECKLIST.md`, with the engineering-side analysis in the two
`THIRD_PARTY_LICENSES.md` files. That review gates **publication**, not this deployment work.

### 7.3 Who does the work

The 1.0 draft budgeted 2.5 FTE across a DevOps engineer, a security engineer and a platform
developer. That is not the shape of this team, and the plan has been rewritten accordingly: every
tier in §6 is a repository artifact with a runnable gate rather than a task assigned to an ops
function. The practical constraint is not headcount but that **nothing may be satisfied by a
hand-run step that leaves nothing behind** — otherwise it will not survive the next clean clone.

---

## 8. Operations Runbook (outline)

### 8.1 Daily
- Grafana: all services green, no active alerts.
- Disk usage < 80%, on both the data and backup volumes.
- Backup jobs completed (check the timer's exit status, not just that the file exists).

### 8.2 Weekly
- Review trends: CPU, memory, request latency. Watch Alfresco's headroom specifically.
- Rotate service logs.

### 8.3 Monthly
- **Test a restore.** The backup is not verified until it has been restored.
- Apply OS and image security patches; re-run Trivy.
- Review firewall rules and access logs.
- Rotate database credentials (90-day cycle).

### 8.4 Alert Response

| Alert | Severity | Response |
|---|---|---|
| ActiveMQ down | **Critical** | Restart the broker immediately. Symptom is hung requests with no error — see §5.5. |
| Solr down | **Critical** | Gateway endpoints hang, Web Scripts 500. Restart; check index integrity. |
| Service down | Critical | Check container status and restart. Escalate if > 5 min. |
| transform-core-aio down | Warning | Plan/report generation fails cleanly; canonical import self-heals. Not an emergency. |
| Alfresco memory > 97% | Warning | Expected at idle. Alert on sustained OOM-kill, not utilisation. |
| Disk > 85% | Warning | Clean old logs and archives. |
| Backup failure | **Critical** | Investigate and re-run. A silent backup failure is how data is actually lost. |

---

## 9. Risk Register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Single Alfresco instance failure | Medium | High | Daily backup + verified restore. RTO 4 h. Acceptable at < 100 inspections/year. |
| R2 | Single-host failure takes down everything | Low | **Critical** | Accepted consequence of ADR-005. Mitigated only by backup + restore to new hardware. Revisit if the authority's tolerance changes. |
| R3 | Demo credentials reach a real deployment | **High** | **Critical** | §6.3, and `preflight-secrets.sh --production` as a hard gate. This is the single most likely way this platform gets compromised. |
| R4 | Backups have never been restored | **High** | **Critical** | §6.6's `restore:verify`. An untested backup is not a backup. |
| R5 | Container hardening breaks the stack silently | Medium | Medium | One service per commit, `demo:verify` after each (§6.1). |
| R6 | ActiveMQ failure goes unnoticed | Medium | High | Dedicated alert (§5.5). The failure mode is silence. |
| R7 | Unsigned field-app binary | Medium | Medium | §6.8. Also a trust problem, not only a security one. |
| R8 | Unpinned Python dependencies pull a bad version | Medium | Medium | §6.4 hash-pinned lockfile. |
| R9 | OIDC migration breaks auth | Medium | High | Deferred; spike first (§6.9). Not a v1 risk. |
| R10 | Insufficient resources under load | Low | Low | < 5 concurrent users; 16 GB provides real headroom. |

---

## 10. Decision Log (ADR format)

### ADR-001: Docker Compose over Kubernetes
**Status**: Accepted · **Date**: 2026-07-30
**Decision**: Docker Compose with systemd units.
**Rationale**: Kubernetes adds operational overhead not justified at < 5 concurrent users. systemd
provides auto-restart equivalent to pod restart. A K3s path exists if scale changes.
**Consequences**: No auto-scaling (not needed); manual rolling updates (acceptable).

### ADR-002: Keycloak for OIDC — **revised 2026-09-26**
**Status**: **Deferred** (was: Accepted) · **Date**: 2026-07-30, revised 2026-09-26
**Context**: The original decision treated identity as a login mechanism. It is not. `compliance_web`
derives roles from Alfresco group membership, and an application role does not grant an Alfresco
repository permission — every writing role needs repository access provisioned separately.
**Decision**: Production v1 ships on Alfresco-backed authentication. Keycloak is reduced to a design
spike (§6.9) that must answer the role-source and repository-grant questions before any migration is
scheduled.
**Rationale**: Migrating identity without solving the dual authorization plane would produce a system
where users can log in and cannot write. The concrete driver for eventually doing this work is
`compliance_checklist`'s sync-time password prompt, not the login flow itself.
**Consequences**: No OIDC at go-live. The existing, tested auth path carries production.

### ADR-003: Backup-and-restore over streaming replication — **revised 2026-09-26**
**Status**: **Revised** · **Date**: 2026-07-30, revised 2026-09-26
**Context**: The original decision specified PostgreSQL streaming replication with standbys on a
third VM. ADR-005 removes the third VM.
**Decision**: Reliability rests on daily backups with WAL archiving and a **CI-verified restore**,
not on a warm standby.
**Rationale**: A standby on the same host protects against nothing that matters. A verified restore
protects against the failure modes that are actually likely (data corruption, bad deploy, hardware
loss). Replication returns when multi-host does.
**Consequences**: RTO moves from 2 h to 4 h. Monthly restore drill becomes mandatory, not optional.

### ADR-004: Defer Kafka/RabbitMQ
**Status**: Accepted · **Date**: 2026-07-30
**Decision**: No *application-level* message broker.
**Rationale**: < 100 inspections/year; plan generation and canonical import complete synchronously.
**Consequences**: Revisit beyond ~500 inspections/year.
**Clarification (2026-09-26)**: This ADR concerns application messaging only. **The stack is not
broker-free** — Alfresco depends on ActiveMQ, which is a required component with the worst failure
mode of anything in the stack (§5.5). Do not read this ADR as permission to drop it.

### ADR-005: Single host first — **new 2026-09-26**
**Status**: Accepted · **Date**: 2026-09-26
**Context**: The 1.0 draft specified three VMs. That topology cannot be deployed as drawn: the
platform's three shared Docker networks (`backend_net`, `alfresco_backend`, `import-backend`) are
single-host bridge networks, each created by a different repository and consumed as `external` by
others. Every service-to-service hop resolves a container name on one of them. The draft declared no
networks, proposed no overlay, and specified no host-routable addressing.
**Decision**: Deploy to one hardened host. Defer multi-host.
**Rationale**: At < 5 concurrent users and < 100 inspections/year, the split bought availability the
platform does not need, at the cost of a networking problem nobody had scoped. Hardening, TLS,
backups and observability all deliver value on one host and are prerequisites for a split anyway.
**Consequences**: No component redundancy — R2 is accepted. Streaming replication is deferred with
it (ADR-003).
**Precondition for revisiting**: A multi-host split must first replace the three bridge networks with
host-routable addressing (or an overlay network), and re-verify every hop in §2.3. That is the
workstream, not the VM provisioning.

---

## 11. Corrections applied in version 2.0

Recorded so a reader of the 1.0 draft can see what moved and why. Each was verified against the tree
on 2026-09-26.

| # | 1.0 said | Reality | Severity |
|---|---|---|---|
| 1 | Appendix B: `atro-web: image: atrocrmenterprise/atrocrm:latest` | AtroCore is built locally and installed **at container bootstrap**, specifically so GPL-3.0 code never enters an image layer. Following the draft would reintroduce the distribution problem W5 closed. | **Harmful** |
| 2 | `alfresco-content-repository-community:23.x` | `alfresco-governance-repository-community:25.2.0` — different variant, two majors on | **Harmful** |
| 3 | Three VMs | Three single-host bridge networks make the split undeployable. ADR-005. | **Harmful** |
| 4 | VM1 = Alfresco + Solr + Postgres in 8 GB | Omits Share, ActiveMQ, transform-core-aio and Traefik — ~3.7 GiB of declared limits. The stack's limits total ~8.6 GiB. | **Harmful** |
| 5 | `postgres:15-alpine` throughout | Alfresco 16.5, `compliance_web` 16-alpine, AtroCore 15-alpine | Stale |
| 6 | `compliance_web` publishes `3000:3000, 4000:4000` | `dev` profile publishes `3000:3000`; `prod` publishes `8080:80`. 4000 is dev-override only. | Stale |
| 7 | Network policy routes browsers to Node-RED :1880 | `compliance_web` proxies the gateway behind its own app server; no browser reaches :1880. Surface is smaller than the draft assumed. | Stale (favourably) |
| 8 | Month 1: migrate credentials out of `.env`, remove hardcoded defaults | Largely done by P0 — secrets untracked, rotated and purged from history. What remains is the public placeholder key and two `compliance_cmis` compose fallbacks. | Stale |
| 9 | Month 2: add `/health` to all services | Done in `compliance_import` and `compliance_web`. Missing in `compliance_flow` (27 `http in` nodes, none is health) and `atrocore-docker`. | Partially done |
| 10 | Appendix A env var list | Missing roughly 25 variables that now exist | Stale |
| 11 | "Alfresco Community 23.x"; "AtroCore proprietary, TBD" | AtroCore core is GPL-3.0-only; both questions are answered in the `THIRD_PARTY_LICENSES.md` files | Stale |
| 12 | ADR-004 reads as "no broker needed" | ActiveMQ is a hard dependency with the worst failure mode in the stack | Misleading |
| 13 | Proposes a new NGINX; no mention of existing proxies | Two Traefik instances already exist; one publishes an **unauthenticated dashboard** on :8888 with the Docker socket mounted | **Omission** |
| 14 | No mention of field-app distribution | Unsigned portable exe, signing commented out, no publish target, no auto-update | **Omission** |
| 17 | Assumed the services co-exist on a host | `compliance_cmis`'s Traefik and `compliance_web`'s `prod` profile both bind host `8080`; they cannot both start. Never hit, because every documented bring-up uses the `dev` profile. | **Harmful** (found 2026-09-26) |
| 15 | 2.5 FTE across three roles; tasks owned by "Ops" | Rewritten as repository artifacts with runnable gates | Structural |
| 16 | RPO 15 min / RTO 2 h stated as targets | Unevidenced, and the 2 h assumed a standby to promote. Now 4 h, explicitly labelled until `restore:verify` is green. | Overstated |

---

## Appendix A: Environment Variables (Production)

Derived from the five tracked `.env*.example` files on 2026-09-26. `compliance_checklist` has no
`.env` — it is configured through `app.config.json` (see §6.8).

Values marked `<secret>` must arrive through the file-based precedence in §4.3
(`*_FILE` → Docker secret → env), never as a literal in a compose file.

```bash
# ── atrocore-docker ────────────────────────────────────────────────
SKELETON_VARIANT=            BUILD_VARIANT=
PRODUCTION_DOMAIN=           PRODUCTION_STABILITY=
TESTING_DOMAIN=              TESTING_STABILITY=
POSTGRES_PASSWORD=<secret>
POSTGRES_PIM_USER=           POSTGRES_PIM_PASSWORD=<secret>
POSTGRES_PIM_DB=             POSTGRES_PIM_DB_TEST=
LETS_ENCRYPT_EMAIL=
PROXY_PRODUCTION_ROUTER=     PROXY_TESTING_ROUTER=

# ── compliance_cmis (Alfresco stack) ───────────────────────────────
# Image tags. NOTE: only POSTGRES_TAG is actually consumed by the compose
# file today — the other five are documented here but hardcoded in the YAML.
# Reconciling that is part of the §6.4 digest-pinning work.
ALFRESCO_CE_TAG=25.2.0       SEARCH_CE_TAG=2.0.16
SHARE_TAG=25.2.0             POSTGRES_TAG=16.5
TRANSFORM_ENGINE_TAG=5.2.0   ACTIVEMQ_TAG=5.18-jre17-rockylinux8
METADATA_KEYSTORE_PASSWORD=<secret>
METADATA_KEYSTORE_METADATA_PASSWORD=<secret>
DB_PASSWORD=<secret>         # remove the ':-alfresco' compose fallback (§6.3)
SOLR_SECRET=<secret>         # remove the ':-secret'   compose fallback (§6.3)
SERVER_NAME=                 BIND_IP_NGINX=           BIND_IP_FTP=

# ── compliance_flow (Node-RED gateway) ─────────────────────────────
ALFRESCO_USERNAME=           ALFRESCO_PASSWORD=<secret>
ATROCORE_USERNAME=           ATROCORE_PASSWORD=<secret>
API_KEY=<secret>             # must match NODE_RED_API_KEY and IMPORT_API_KEY
ADMIN_USERNAME=              ADMIN_PASSWORD_HASH=<secret>
NODE_RED_CREDENTIAL_SECRET=<secret>
NODE_ENV=production
ATROCORE_BASE_URL=           ALFRESCO_BASE_URL=
HTTP_REQUEST_TIMEOUT_MS=     HTTP_MAX_RETRIES=        HTTP_RETRY_BACKOFF_MS=

# ── compliance_import (FastAPI ingestion) ──────────────────────────
ALFRESCO_URL=                ALFRESCO_CANONICAL_JSON_PATH=
IMPORT_API_KEY=<secret>      # same value as API_KEY
ALFRESCO_TIMEOUT_SECONDS=    ALFRESCO_RETRY_TOTAL=    ALFRESCO_RETRY_CONNECT=
ALFRESCO_RETRY_READ=         ALFRESCO_RETRY_STATUS=   ALFRESCO_RETRY_BACKOFF_SECONDS=
# Credentials already resolve *_FILE → Docker secret → env. This is the
# reference implementation for §4.3; generalise it, don't reinvent it.

# ── compliance_web (SPA + auth/session backend) ────────────────────
POSTGRES_DB=                 POSTGRES_USER=           POSTGRES_PASSWORD=<secret>
ALFRESCO_BASE_URL=
AUTH_TICKET_ENCRYPTION_KEY=<secret>   # server refuses to start without it
AUTH_NODE_ENV=production     AUTH_COOKIE_SECURE=true
NODE_RED_API_KEY=<secret>    # same value as API_KEY
ALFRESCO_JOB_USERNAME=       ALFRESCO_JOB_PASSWORD=<secret>
ROLE_RECIPIENT_CACHE_MS=     FINDING_OVERDUE_JOB_HOUR=
SITE_VISIT_SCHEDULING_JOB_HOUR=       SITE_VISIT_PLANNING_LEAD_DAYS=
SMTP_HOST=                   SMTP_PORT=               SMTP_SECURE=
SMTP_USER=                   SMTP_PASS=<secret>       SMTP_FROM=
INSPECTOR_NOTIFICATIONS_EMAIL=        CAP_ENTRY_NOTIFICATIONS_EMAIL=
PLANNER_NOTIFICATIONS_EMAIL=          CASE_ESCALATION_EMAIL=
BACKEND_BUILD_TARGET=prod
```

---

## Appendix B: Deployment manifests

**There is deliberately no compose skeleton here.** The 1.0 draft carried a hand-written one, and it
drifted into naming the wrong Alfresco image, the wrong AtroCore image, the wrong PostgreSQL
version, the wrong ports and none of the required networks — four of the five harmful errors in §11
came from that one appendix. A second copy of the compose files is a liability.

The deployment manifests **are** the tracked compose files:

| Repo | File | Creates network | Consumes (external) |
|---|---|---|---|
| `atrocore-docker` | `docker-compose.yaml` | `backend_net` | — |
| `compliance_cmis` | `docker-compose.yml` (+ `commons/base.yaml`) | `alfresco_backend` | — |
| `compliance_import` | `docker-compose.yml` | `import-backend` | `alfresco_backend` |
| `compliance_flow` | `docker-compose.yaml` | — | all three |
| `compliance_web` | `docker-compose.yml` (+ `docker-compose.dev.yml`) | — | `alfresco_backend` |

### Image inventory

The exact image references in the tree on 2026-09-26. `scripts/verify-production-doc.sh` asserts
this table against the compose files, so it cannot drift silently the way the 1.0 skeleton did.

| Service | Image reference | Pinning |
|---|---|---|
| Alfresco repository | `alfresco/alfresco-governance-repository-community:25.2.0` | tag |
| Share | `alfresco/alfresco-governance-share-community:25.2.0` | tag |
| Search | `alfresco/alfresco-search-services:2.0.16` | tag |
| Transform | `alfresco/alfresco-transform-core-aio:5.2.0` | tag |
| Broker | `alfresco/alfresco-activemq:5.18-jre17-rockylinux8` | tag |
| Alfresco DB | `postgres:${POSTGRES_TAG:-16.5}` | tag, env-overridable |
| Internal proxy | `traefik:3.6` | tag |
| Node-RED | `nodered/node-red:4.1.10` | tag |
| AtroCore | **built locally** from `php:8.4-apache-bookworm`; the application is installed at container bootstrap, never baked into a layer | — |
| AtroCore DB | `postgres:15-alpine` | tag |
| `compliance_web` backend | **built locally** (`compliance-web-backend:local`) | — |
| `compliance_web` DB | `postgres:16-alpine` | tag |
| `compliance_import` | **built locally** from `python:3.12-slim` | — |

Two things to carry into §6.4: **no image anywhere is digest-pinned** (zero `@sha256` references in
the tree), and `compliance_cmis/.env.example` documents `ALFRESCO_CE_TAG`, `SEARCH_CE_TAG`,
`SHARE_TAG`, `TRANSFORM_ENGINE_TAG` and `ACTIVEMQ_TAG` as if they were configurable when the compose
file hardcodes all five — only `POSTGRES_TAG` is actually wired through.

**Startup order follows from that table**, not from preference: `atrocore-docker`,
`compliance_cmis` and `compliance_import` must each come up at least once before `compliance_flow`
or `compliance_web` can start, because those two only ever consume the shared networks.

Production hardening lands as **additive overrides and compose profiles** on these files, never as a
parallel set. See `atrocore-docker/docs/COMPLIANCE_INTEGRATION_RUNBOOK.md` §2–§5 for the
authoritative bring-up sequence, and §6.1 for why the demo path must remain intact alongside.

---

## Appendix C: Glossary

| Term | Definition |
|---|---|
| ADR | Architecture Decision Record |
| AFTS | Alfresco Full Text Search — the query language behind `/checklist` and `/findings/open` |
| CMIS | Content Management Interoperability Services (Alfresco API) |
| IdP | Identity Provider |
| JWT | JSON Web Token |
| mTLS | Mutual TLS (client and server both authenticate) |
| P0–P3 | The platform's remediation phases. P0 security/correctness, P1 structural, P2 maintainability, **P3 production readiness — this document** |
| RPO / RTO | Recovery Point / Recovery Time Objective |
| SBOM | Software Bill of Materials |
| USOAP | ICAO Universal Safety Oversight Audit Programme |
| VSO | The Alfresco content model namespace for this platform |

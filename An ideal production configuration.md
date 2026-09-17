# Compliance Platform — Production Architecture & Operations Plan

**Version**: 1.0-draft  
**Audience**: Technical stakeholders, operations team, project sponsors  
**Status**: For discussion — **design/roadmap only, not the current state of any deployed environment.** None of the components below (Keycloak, Vault, PostgreSQL streaming replication, Prometheus/Grafana, the 3-VM topology) exist yet; the actual running systems today are the single-host Docker Compose setups documented per-repo and the `atrocore-docker` demo stack described in the root `CLAUDE.md`. P3/production-hardening is at 0% complete. If you're adapting this platform for a different civil aviation authority before thinking about production deployment, see `COUNTRY_ADAPTATION_GUIDE.md` (repo root) instead — this document assumes the content/branding/specialty adaptation is already done and is about infrastructure, not configuration.

---

## 1. Executive Summary

This document defines the production deployment architecture for the Aviation Safety Compliance Platform. The platform supports < 50 users with < 5 concurrent sessions, processing < 100 site inspections per year at a single geographic site. The deployment target is three on-premises VMs using Docker Compose with systemd orchestration.

### Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Orchestrator | Docker Compose + systemd | Sufficient at < 5 concurrent users. K3s/Kubernetes deferred until scale demands it. |
| Identity provider | Keycloak (Month 3) | OIDC standard. Replaces current Alfresco-backed auth. |
| Database HA | PostgreSQL streaming replication | Two-node setup (primary + standby) per database domain. |
| Secrets | HashiCorp Vault (Month 1) | Centralized secret store. Removes hardcoded defaults from all manifests. |
| Email delivery | Alfresco folder rule + SMTP relay | Node-RED writes contact email to document property; Alfresco rule sends. |
| Monitoring | Prometheus + Grafana | Standard OSS stack. Loki for logs, Tempo for traces (optional). |
| CI/CD | Git-driven deployment with image signing | Git pull + `docker compose up -d`. SBOM generation via Syft, image signing via Cosign. |

---

## 2. Architecture Overview

```
                              ┌─────────────────────────────────┐
                              │         Internet / WAN           │
                              └──────────────┬──────────────────┘
                                             │ TLS 1.2+
                                    ┌────────┴────────┐
                                    │   NGINX Reverse  │
                                    │   Proxy (VM3)    │
                                    │   :443 → backend │
                                    └────────┬────────┘
                                             │
              ┌──────────────────────────────┼──────────────────────────────┐
              │                              │                              │
    ┌─────────┴──────────┐        ┌─────────┴──────────┐        ┌─────────┴──────────┐
    │       VM1          │        │       VM2          │        │       VM3          │
    │   4 vCPU / 8 GB    │        │   4 vCPU / 4 GB    │        │   2 vCPU / 4 GB    │
    │   200 GB SSD       │        │   100 GB SSD       │        │   200 GB HDD       │
    │                    │        │                    │        │                    │
    │  ┌──────────────┐  │        │  ┌──────────────┐  │        │  ┌──────────────┐  │
    │  │ Alfresco     │  │        │  │ AtroCore     │  │        │  │ Prometheus   │  │
    │  │ Repo (8080)  │  │        │  │ (atro-web)   │  │        │  │ + Grafana    │  │
    │  └──────────────┘  │        │  └──────────────┘  │        │  └──────────────┘  │
    │  ┌──────────────┐  │        │  ┌──────────────┐  │        │  ┌──────────────┐  │
    │  │ Solr Search  │  │        │  │ Node-RED     │  │        │  │ Vault        │  │
    │  │ (8983)       │  │        │  │ (1880)       │  │        │  │ Secrets Mgr  │  │
    │  └──────────────┘  │        │  └──────────────┘  │        │  └──────────────┘  │
    │  ┌──────────────┐  │        │  ┌──────────────┐  │        │  ┌──────────────┐  │
    │  │ PostgreSQL   │  │        │  │ compliance_  │  │        │  │ NGINX Proxy  │  │
    │  │ (Alfresco)   │  │        │  │ web (3000)   │  │        │  │ + TLS Term   │  │
    │  │ Primary      │  │        │  └──────────────┘  │        │  └──────────────┘  │
    │  └──────┬───────┘  │        │  ┌──────────────┐  │        │  ┌──────────────┐  │
    │         │ stream   │        │  │ compliance_  │  │        │  │ PostgreSQL   │  │
    │  ┌──────┴───────┐  │        │  │ import (8000)│  │        │  │ (compliance) │  │
    │  │ PostgreSQL   │  │        │  └──────────────┘  │        │  │ Standby      │  │
    │  │ (Alfresco)   │  │        │  ┌──────────────┐  │        │  └──────────────┘  │
    │  │ Standby (VM3)│  │        │  │ compliance_  │  │        │  ┌──────────────┐  │
    │  └──────────────┘  │        │  │ web backend  │  │        │  │ Backup Store │  │
    │                    │        │  │ (4000)       │  │        │  │ (daily pg_   │  │
    │                    │        │  └──────────────┘  │        │  │  dump + WAL) │  │
    │                    │        │  ┌──────────────┐  │        │  └──────────────┘  │
    │                    │        │  │ PostgreSQL   │  │        │  ┌──────────────┐  │
    │                    │        │  │ (compliance) │  │        │  │ SMTP Relay   │  │
    │                    │        │  │ Primary      │  │        │  │ (Postfix or  │  │
    │                    │        │  └──────────────┘  │        │  │  cloud relay)│  │
    │                    │        │                    │        │  └──────────────┘  │
    └────────────────────┘        └────────────────────┘        └────────────────────┘

Network zones:
  dmz:      NGINX proxy (VM3) — only component exposed externally
  internal: All other services — no direct internet access
```

### Network Policy

| Source | Destination | Ports | Purpose |
|---|---|---|---|
| NGINX (VM3) | compliance_web (VM2) | 3000, 4000 | Frontend + API |
| NGINX (VM3) | Node-RED (VM2) | 1880 | Checklist app integrations |
| compliance_web (VM2) | Node-RED (VM2) | 1880 | Entity CRUD, plan/report |
| Node-RED (VM2) | AtroCore (VM2) | 80 | AtroCore API |
| Node-RED (VM2) | Alfresco (VM1) | 8080 | Content operations |
| Node-RED (VM2) | compliance_import (VM2) | 8000 | Import triggers |
| compliance_import (VM2) | Alfresco (VM1) | 8080 | CMIS uploads |
| Alfresco (VM1) | SMTP relay (VM3) | 25/587 | Email delivery |
| All | Prometheus (VM3) | 9090 | Metrics scraping |
| Ops access | All VMs | 22 | SSH (key-only, jump host) |

---

## 3. Component Sizing

### Compute & Memory

| Service | VM | vCPU | RAM | Justification |
|---|---|---|---|---|
| Alfresco Repository | VM1 | 2.0 | 4 GB | JVM-based. Memory for content caching. Single instance sufficient at < 100 docs/month. |
| Solr | VM1 | 1.0 | 2 GB | Full-text search index for Alfresco. |
| PostgreSQL (Alfresco) | VM1 | 0.5 | 1 GB | Alfresco metadata DB. ~30 GB expected. |
| AtroCore/AtroCRM | VM2 | 2.0 | 2 GB | CRM backend. PHP-based. Single instance. |
| Node-RED | VM2 | 0.5 | 512 MB | Integration middleware. Low CPU, event-driven. |
| compliance_web (Vite + Express) | VM2 | 0.5 | 512 MB | Vue SPA static files + Express auth backend. |
| compliance_import | VM2 | 0.5 | 256 MB | FastAPI ZIP import service. Burst CPU during uploads. |
| PostgreSQL (compliance) | VM2 | 0.5 | 1 GB | Auth sessions, small dataset. |
| **VM2 subtotal** | | **4.0** | **~4.3 GB** | |
| PostgreSQL (Alfresco standby) | VM3 | 0.5 | 1 GB | Streaming replica. |
| PostgreSQL (compliance standby) | VM3 | 0.5 | 1 GB | Streaming replica. |
| NGINX + certbot | VM3 | 0.5 | 512 MB | TLS termination, reverse proxy. |
| Prometheus + Grafana | VM3 | 0.5 | 1 GB | Metrics collection. 30-day retention. |
| Loki (optional) | VM3 | 0.5 | 1 GB | Log aggregation (deferred to Month 2). |
| Vault | VM3 | 0.5 | 512 MB | Secrets management. |
| SMTP relay (Postfix) | VM3 | 0.2 | 256 MB | Outbound email only. |
| Backup storage | VM3 | — | — | Daily pg_dump archives. |
| **VM3 subtotal** | | **3.2** | **~5.3 GB** | |
| **Grand Total** | | **10.2** | **~16.6 GB** | |

**Recommendation**: Provision 10 vCPU / 20 GB RAM total across the 3 VMs for headroom.

### Storage

| Component | Initial | Annual Growth | 3-Year Total | Type |
|---|---|---|---|---|
| Alfresco content store | 50 GB | 5 GB | 65 GB | SSD (low latency for doc access) |
| PostgreSQL (Alfresco DB) | 20 GB | 3 GB | 29 GB | SSD |
| Solr indexes | 10 GB | 2 GB | 16 GB | SSD |
| AtroCore DB | 10 GB | 2 GB | 16 GB | SSD |
| PostgreSQL (compliance) | 5 GB | 1 GB | 8 GB | SSD |
| Prometheus metrics | 20 GB | 10 GB | 50 GB | HDD (acceptable latency) |
| Backups (daily, 30-day retention) | 50 GB | 15 GB | 95 GB | HDD |
| Docker images + volumes | 20 GB | — | 20 GB | SSD |
| **Total** | **185 GB** | **38 GB** | **~300 GB** | |

**Recommendation**: 500 GB usable storage (200 GB SSD + 200 GB HDD + 100 GB margin).

---

## 4. Security Model

### 4.1 Authentication & Authorization

| Component | Current (Dev) | Production (Month 3) |
|---|---|---|
| User identity | Alfresco-backed login | Keycloak OIDC |
| Service-to-service | Basic auth / API keys | mTLS or OAuth2 client credentials |
| Session management | PostgreSQL sessions | JWT (short-lived access + refresh tokens) |
| Role mapping | Alfresco groups | Keycloak groups + OIDC claims |

### 4.2 Network Security

- Single NGINX reverse proxy on VM3 exposed on port 443 only
- All inter-service traffic on internal VLAN (RFC 1918)
- SSH access via jump host with key-only authentication
- Firewall rules restrict each VM to only the ports listed in Section 2

### 4.3 Secrets Management

- HashiCorp Vault on VM3 (dev mode initially, HA later)
- All credentials migrated from `.env` files and hardcoded defaults to Vault
- Rotation policy: database credentials every 90 days, signing keys with overlap windows
- Vault audit log shipped to SIEM

### 4.4 Container Security

- All containers run as non-root users
- Read-only root filesystems where possible
- Docker socket protected (no mount in containers)
- Images scanned for CVEs in CI pipeline (Trivy or Grype)
- SBOM generated per build (Syft)

### 4.5 File Upload Security

- ClamAV sidecar on compliance_import for malware scanning
- ZIP bomb controls (already implemented: max size, compression ratio, path traversal)
- Quarantine directory for suspicious uploads
- Immutable audit trail for all uploaded evidence

---

## 5. Reliability & Disaster Recovery

### 5.1 Availability Targets

| Component | Target | Strategy |
|---|---|---|
| compliance_web | 99.5% | systemd auto-restart |
| Node-RED | 99.5% | systemd auto-restart |
| AtroCore | 99.5% | systemd auto-restart |
| Alfresco | 99.0% | Weekly cold backup; restore from backup if failure |
| PostgreSQL (Alfresco) | 99.5% | Streaming replication to standby on VM3 |
| PostgreSQL (compliance) | 99.5% | Streaming replication to standby on VM3 |

### 5.2 Recovery Objectives

| Metric | Target |
|---|---|
| RPO (Recovery Point Objective) | 15 minutes (WAL streaming) |
| RTO (Recovery Time Objective) | 2 hours (core workflows) |

### 5.3 Backup Schedule

| Dataset | Frequency | Retention | Method |
|---|---|---|---|
| PostgreSQL (Alfresco) | Daily full + continuous WAL | 30 days | `pg_dump` + WAL archiving |
| PostgreSQL (compliance) | Daily full + continuous WAL | 30 days | `pg_dump` + WAL archiving |
| Alfresco content store | Daily incremental, weekly full | 30 days | `rsync` to backup dir |
| AtroCore data | Daily full | 30 days | AtroCore export or `pg_dump` |
| Vault data | Daily | 90 days | Vault snapshot |
| Docker Compose configs | Git (continuous) | Permanent | Git repository |

### 5.4 Disaster Recovery Runbook (Outline)

1. **Detect**: Prometheus alert fires (service down > 2 min)
2. **Diagnose**: Check systemd status on affected VM. Review logs via Loki/journald.
3. **Restore database**: Promote standby to primary. Point services to new primary.
4. **Restore content**: If Alfresco content store lost, restore from latest rsync snapshot.
5. **Verify**: Run smoke tests (health endpoint, sample inspection query, document retrieval).
6. **Notify**: Update status page, notify stakeholders per communication plan.

---

## 6. Implementation Roadmap (90 Days)

### Month 1: Security & Foundation (Days 1–30)

| Week | Tasks | Owner |
|---|---|---|
| 1 | Provision 3 VMs with OS (Ubuntu 22.04 LTS), Docker + Docker Compose, internal DNS, firewall rules | Ops |
| 1 | Deploy NGINX reverse proxy with self-signed TLS on VM3 | Ops |
| 2 | Install Vault on VM3. Migrate all credentials from `.env` files to Vault. Remove hardcoded defaults from all `docker-compose.yml` files. | Ops + Dev |
| 2 | Generate new database passwords, Alfresco admin password, AtroCore credentials. Store in Vault. | Ops |
| 3 | Deploy ClamAV sidecar alongside compliance_import. Configure quarantine directory. | Ops |
| 3 | Harden containers: non-root users, read-only filesystems, resource limits. | Dev |
| 4 | Security review: penetration test basic auth endpoints, verify firewall rules, validate Vault access controls. | Ops + Security |

### Month 2: Reliability (Days 31–60)

| Week | Tasks | Owner |
|---|---|---|
| 5 | Set up PostgreSQL streaming replication for both DB domains. Verify failover procedure. | Ops |
| 5 | Configure automated backups: pg_dump daily, WAL archiving continuous, rsync for content store. | Ops |
| 6 | Deploy Prometheus + Grafana on VM3. Configure dashboards: service health, DB replication lag, disk usage, request latency. | Ops |
| 6 | Set up alerting rules: service down, high CPU/memory, low disk, replication lag > 5 min. | Ops |
| 7 | Performance testing: simulate 5 concurrent users, 10 inspections/day. Validate resource usage. | Dev + Ops |
| 7 | Backup restore drill: restore PostgreSQL from backup, verify Alfresco content integrity. | Ops |
| 8 | Health check endpoints: add `/health` to all services. Configure systemd health checks. | Dev |
| 8 | Document runbook: backup procedures, restore procedures, failover steps. | Ops |

### Month 3: Control Plane Maturity (Days 61–90)

| Week | Tasks | Owner |
|---|---|---|
| 9 | Deploy Keycloak. Configure OIDC realm, client applications, role mapping. | Dev + Ops |
| 9 | Migrate authentication: compliance_web → Keycloak. Backward-compatible period (dual auth). | Dev |
| 10 | Set up Git-driven deployment: Git repo for docker-compose configs, `git pull && docker compose up -d` workflow. | Dev + Ops |
| 10 | CI/CD pipeline: build Docker images, scan with Trivy, generate SBOM with Syft, sign with Cosign, push to registry. | Dev |
| 11 | SIEM integration: ship Vault audit logs, auth events, and compliance workflow events to SIEM. | Ops |
| 11 | Configure NGINX with production TLS certificate (Let's Encrypt or enterprise CA). | Ops |
| 12 | Final security review: OIDC flow, mTLS for service-to-service, penetration test. | Ops + Security |
| 12 | Production go-live: cut over from development environment, smoke test, monitor for 48 hours. | Ops + Dev |

---

## 7. Resource Requirements Summary

### Hardware

| Resource | Specification | Quantity |
|---|---|---|
| VM1 | 4 vCPU, 8 GB RAM, 200 GB SSD | 1 |
| VM2 | 4 vCPU, 4 GB RAM, 100 GB SSD | 1 |
| VM3 | 2 vCPU, 4 GB RAM, 200 GB HDD + 100 GB SSD | 1 |
| Network | 1 Gbps internal LAN, VLAN segmentation | — |
| Backup storage | External NAS or additional disk (500 GB) | 1 |

### Software & Licenses

| Component | License | Cost |
|---|---|---|
| Ubuntu Server 22.04 LTS | Free | $0 |
| Docker CE + Docker Compose | Free (community) | $0 |
| Alfresco Community 23.x | LGPL v3 | $0 |
| AtroCore/AtroCRM | Proprietary (check license) | TBD |
| Keycloak | Apache 2.0 | $0 |
| HashiCorp Vault | MPL 2.0 (community) | $0 |
| Prometheus + Grafana | Apache 2.0 | $0 |
| Postfix (SMTP relay) | Free (IBM Public License) | $0 |
| TLS certificate | Let's Encrypt (free) or enterprise CA | $0–$500/yr |
| ClamAV | GPL v2 | $0 |

### Personnel

| Role | FTE (during implementation) | FTE (steady-state) |
|---|---|---|
| DevOps / Infrastructure Engineer | 1.0 | 0.5 |
| Security Engineer (shared) | 0.5 | 0.2 |
| Developer (platform) | 1.0 | 0.5 |
| **Total** | **2.5 FTE** | **1.2 FTE** |

---

## 8. Operations Runbook (Outline)

### 8.1 Daily Checks
- Prometheus dashboard: all services green, no active alerts
- Disk usage < 80% on all VMs
- PostgreSQL replication lag < 5 minutes
- Backup jobs completed successfully (check logs)

### 8.2 Weekly Checks
- Review Grafana dashboards for trends (CPU, memory, request latency)
- Verify Vault audit log integrity
- Rotate service logs (logrotate)

### 8.3 Monthly Checks
- Test backup restore on a staging environment
- Review and apply OS security patches
- Rotate database credentials (every 90 days after initial setup)
- Review firewall rules and access logs

### 8.4 Alert Response
| Alert | Severity | Response |
|---|---|---|
| Service down | Critical | Check systemd status, restart if needed. Escalate if > 5 min. |
| High CPU/Memory | Warning | Investigate process, consider scaling or restarting. |
| Disk > 85% | Warning | Clean old logs, archives. Expand disk if trend continues. |
| Replication lag > 5 min | Critical | Check network between primary and standby. Investigate WAL shipping. |
| Backup failure | Critical | Investigate and re-run backup. Escalate if persists. |

---

## 9. Risk Register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Single Alfresco instance failure | Medium | High | Weekly cold backup. Restore from backup RTO 2 hours. Acceptable for < 100 inspections/year. |
| R2 | PostgreSQL primary failure | Low | High | Streaming replication to standby on VM3. Automatic or manual failover. |
| R3 | Credential leak from .env files | High (pre-Vault) | Critical | Vault migration in Month 1. All credentials removed from manifests. |
| R4 | OIDC migration breaks auth | Medium | High | Dual-auth period during migration. Rollback plan: revert to Alfresco auth. |
| R5 | compliance_import ZIP bomb | Low | Medium | Existing ZIP bomb controls. Add ClamAV sidecar (Month 1). |
| R6 | Insufficient resources under load | Low | Low | < 5 concurrent users. Tested at 5 concurrent in Month 2. 20% headroom provisioned. |
| R7 | Data loss from missing Alfresco content backup | Medium | Critical | rsync-based content store backup in Month 2. Restore drill in Month 2. |
| R8 | On-premises hardware failure | Low | High | 3 VMs provide redundancy for critical components. Backup restore to new hardware possible. |

---

## 10. Decision Log (ADR Format)

### ADR-001: Docker Compose over Kubernetes
**Status**: Accepted  
**Date**: 2026-07-30  
**Context**: Need container orchestration for production. < 5 concurrent users, < 100 inspections/year.  
**Decision**: Docker Compose with systemd service files.  
**Rationale**: Kubernetes adds significant operational overhead (networking, storage, ingress) not justified at this scale. systemd provides auto-restart and health checks equivalent to pod auto-restart. Migration path to K3s exists if scale increases.  
**Consequences**: No auto-scaling (not needed). Manual rolling updates (acceptable for low-traffic window).

### ADR-002: Keycloak for OIDC
**Status**: Accepted  
**Date**: 2026-07-30  
**Context**: Current auth is Alfresco-backed with custom session management. Need centralized identity for multi-service platform.  
**Decision**: Deploy Keycloak as the identity provider with OIDC/OAuth2.  
**Rationale**: Open source, supports OIDC, user federation (LDAP/Alfresco), role mapping, service accounts. Industry standard for on-premises deployments.  
**Consequences**: Month 3 migration effort. Dual-auth period required. compliance_web, Node-RED, and checklist app need OIDC client integration.

### ADR-003: PostgreSQL Streaming Replication over Managed Service
**Status**: Accepted  
**Date**: 2026-07-30  
**Context**: On-premises deployment. Need database HA.  
**Decision**: PostgreSQL streaming replication with primary on VM1/VM2 and standby on VM3.  
**Rationale**: No managed cloud database available. Streaming replication provides RPO of seconds and RTO of minutes. Two separate PostgreSQL instances (one for Alfresco, one for compliance) for domain separation.  
**Consequences**: Manual failover required. Backup validation drill needed monthly.

### ADR-004: Defer Kafka/RabbitMQ
**Status**: Accepted  
**Date**: 2026-07-30  
**Context**: Original production document proposed a message broker for async processing.  
**Decision**: Defer message broker. Use Node-RED built-in async patterns and retry logic.  
**Rationale**: < 100 inspections/year. Plan generation and canonical import are already synchronous in the Node-RED flow and complete within acceptable time. No queue backlog expected.  
**Consequences**: If volume increases beyond 500 inspections/year, revisit. Migration path: insert RabbitMQ between import service and canonical processing.

---

## Appendix A: Environment Variables (Production)

```bash
# compliance_web
AUTH_SERVER_PORT=4000
AUTH_COOKIE_NAME=compliance_session_id
AUTH_TICKET_ENCRYPTION_KEY=<from-vault>
DATABASE_URL=postgresql://compliance:<from-vault>@vm2:5432/compliance
VITE_COMPLIANCE_API_BASE_URL=/api

# compliance_flow (Node-RED)
ATROCORE_USERNAME=<from-vault>
ATROCORE_PASSWORD=<from-vault>
ALFRESCO_USERNAME=<from-vault>
ALFRESCO_PASSWORD=<from-vault>
API_KEY=<from-vault>
NODE_RED_CREDENTIAL_SECRET=<from-vault>
ADMIN_USERNAME=<from-vault>
ADMIN_PASSWORD_HASH=<from-vault>

# compliance_import
ALFRESCO_URL=http://vm1:8080/alfresco/api/-default-/public/alfresco/versions/1
IMPORT_API_KEY=<from-vault>

# compliance_cmis (Alfresco)
DB_HOST=vm1
DB_PORT=5432
DB_NAME=alfresco
DB_USERNAME=alfresco
DB_PASSWORD=<from-vault>
SOLR_HOST=vm1

# SMTP Relay
SMTP_HOST=vm3
SMTP_PORT=25
```

---

## Appendix B: Docker Compose Skeleton (per VM)

### VM1 — docker-compose.yml (Alfresco + DB)
```yaml
services:
  postgres:
    image: postgres:15-alpine
    environment:
      POSTGRES_DB: alfresco
      POSTGRES_USER: alfresco
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    deploy:
      resources:
        limits: { cpus: '0.5', memory: 1G }
        
  alfresco:
    image: alfresco/alfresco-content-repository-community:23.x
    depends_on: [postgres, solr]
    environment:
      DB_URL: jdbc:postgresql://postgres:5432/alfresco
    ports: ['8080:8080']
    deploy:
      resources:
        limits: { cpus: '2.0', memory: 4G }
        
  solr:
    image: alfresco/alfresco-search-services:2.0.x
    deploy:
      resources:
        limits: { cpus: '1.0', memory: 2G }
```

### VM2 — docker-compose.yml (AtroCore + Node-RED + Web + Import + DB)
```yaml
services:
  postgres:
    image: postgres:15-alpine
    environment:
      POSTGRES_DB: compliance
      POSTGRES_USER: compliance
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    deploy:
      resources:
        limits: { cpus: '0.5', memory: 1G }
        
  atro-web:
    image: atrocrmenterprise/atrocrm:latest
    depends_on: [postgres]
    deploy:
      resources:
        limits: { cpus: '2.0', memory: 2G }
        
  node-red:
    build: ../compliance_flow
    ports: ['1880:1880']
    env_file: ../compliance_flow/.env
    deploy:
      resources:
        limits: { cpus: '0.5', memory: 512M }
        
  compliance-web:
    build: ../compliance_web
    ports: ['3000:3000', '4000:4000']
    env_file: ../compliance_web/.env
    deploy:
      resources:
        limits: { cpus: '0.5', memory: 512M }
        
  compliance-import:
    build: ../compliance_import
    ports: ['8000:8000']
    env_file: ../compliance_import/.env
    deploy:
      resources:
        limits: { cpus: '0.5', memory: 256M }
```

---

## Appendix C: Glossary

| Term | Definition |
|---|---|
| ADR | Architecture Decision Record |
| CMIS | Content Management Interoperability Services (Alfresco API) |
| HPA | Horizontal Pod Autoscaler (Kubernetes — not used in this plan) |
| IdP | Identity Provider (Keycloak) |
| JWT | JSON Web Token |
| mTLS | Mutual TLS (client and server both authenticate) |
| OIDC | OpenID Connect |
| PITR | Point-In-Time Recovery (PostgreSQL) |
| RPO | Recovery Point Objective |
| RTO | Recovery Time Objective |
| SBOM | Software Bill of Materials |
| SIEM | Security Information and Event Management |
| WAF | Web Application Firewall |
| WAL | Write-Ahead Log (PostgreSQL) |

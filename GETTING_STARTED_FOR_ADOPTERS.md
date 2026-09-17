# Getting Started for Adopters

You're a civil aviation authority (CAA) — or someone evaluating this platform on a CAA's
behalf — looking at this repository collection for the first time. This document is the
front door: what it takes to see the platform run, what you'll actually be looking at once
it does, and where to go next. It assumes no prior familiarity with this codebase.

If you're already past this stage and adapting the platform to your own authority, skip
ahead to [`COUNTRY_ADAPTATION_GUIDE.md`](COUNTRY_ADAPTATION_GUIDE.md). If you're evaluating
this for a real deployment rather than a demo, read [`An ideal production
configuration.md`](An%20ideal%20production%20configuration.md) once you're done here — it
is a roadmap document, not a description of what exists today, and that distinction matters
before you commit to anything.

## Hardware requirements — read this first

This is not a lightweight stack. It runs Alfresco Content Services, Solr, ActiveMQ, a
transform service, AtroCore/AtroPIM, Node-RED, and two Node/Express services together, and
several of them are JVM-based enterprise components with real memory floors of their own.

- **8 GB RAM / 4 vCPU** is the workable minimum, and it's tight — Alfresco's own memory cap
  sits at 95–97% utilization at idle, before any of this platform's code runs.
- **16 GB RAM / 6–8 vCPU** is comfortable, with headroom for report generation and realistic
  document volume.

Full measurement and per-service breakdown: `FOOTPRINT_AUDIT.md` (repo root). If you're
evaluating this for a resource-constrained authority, read that document before promising
anyone a lightweight footprint — it doesn't have one today.

## How long this actually takes

The automated CI job that runs this quickstart from an empty checkout (`atrocore-docker`'s
`demo:verify`) takes on the order of twenty minutes once it's running, because it's building
five projects and booting Alfresco, Solr, ActiveMQ, the transform service, Node-RED and two
Node services from cold. That number is the machine's time, not yours: budget **30–90
minutes** for your own first run, once first-time Docker image pulls, unfamiliarity with the
scripts, and the usual first-run friction are accounted for. Don't expect a five-minute demo.

## Prerequisites

- Docker and Docker Compose (a recent version — the stack uses `mem_limit` and multi-network
  Compose features that assume a current release).
- The RAM/vCPU floor above, actually available to Docker, not just present on the host. On
  Docker Desktop or Colima, check the VM's memory allocation setting explicitly — it
  defaults lower than most hosts' physical RAM.
- Enough disk space for six repository clones plus Docker image layers and volumes — budget
  at least 20 GB free to be safe.
- If you're on Docker Desktop or Colima specifically: be aware that `/tmp` on the host is not
  automatically shared with the Docker daemon on these platforms, which has caused real
  install failures in this project before (a script failing with a `can't stat` or "Not a
  directory" error touching a temp path is this exact issue). The known instances of
  this are already worked around in the current scripts; this note is here in case a new one
  surfaces.

## What you'll actually get

The quickstart seeds a **fictional** dataset: ICAO's own "unknown aerodrome" placeholder
airport, `ZZZZ`, with synthetic providers, inspectors, site visits and inspections, plus a
synthetic civil aviation regulation (`RAD-DEMO`) cross-referenced against **real** ICAO Annex
and USOAP Protocol Question reference data. Every demo-authored document ID is obviously
synthetic (`V-ZZZZ-2026-01`, `AV-ZZZZ-A-0001`, and similar). None of this is real jurisdiction
data — worth stating plainly if you're showing this to a regulator audience who might
otherwise wonder whose aviation authority `ZZZZ` belongs to (nobody's — that's the point).

What the quickstart walks you through, end to end: standing up the stack, seeding reference
and demo data, creating demo identities, importing a checklist and its findings, generating a
corrective action plan, submitting a follow-up report, and walking a finding through the
two-step closure review to `Closed`. That's the full lifecycle this platform is built around,
demonstrated on data that means nothing outside this demo.

## Running it

The full sequence — the same one CI runs — is documented in
[`atrocore-docker/docs/COMPLIANCE_INTEGRATION_RUNBOOK.md`](atrocore-docker/docs/COMPLIANCE_INTEGRATION_RUNBOOK.md)
§7 ("Demo Quickstart — clean clone to a demonstrable system"), and is executable directly as
`atrocore-docker/scripts/demo-quickstart.sh --yes` once the stack is up. Start with the
runbook's earlier sections (§2–§3) for network creation and startup order — the quickstart
script assumes a stack that is already running, not a cold `docker compose up`.

**Demo credentials are exactly that — demo credentials.** The API gateway key, seeded
identities, and default passwords the quickstart creates are public, committed values meant
for a local evaluation, not a deployment reachable by anyone you don't trust. Rotate every one
of them before putting this anywhere network-accessible. The quickstart's own output repeats
this warning at the end of the run; it's repeated here because it's the single most important
operational fact in this document.

## What this is not (yet)

This platform's production-hardening status (its "P3"
milestone, tracked internally) sits at **0% complete** — no Vault, no Keycloak, no observability stack, no database
replication exist yet. What you're running is a reference implementation and a demonstration
of the full workflow, configured today for one specific authority (the Dominican Republic's
IDAC), not a production-ready, multi-tenant product. See `An ideal production
configuration.md` for the target architecture this platform is working toward, and treat it
as a roadmap, not a checklist of what's already built.

## Where to go next

- **Adapting this to your own authority?** [`COUNTRY_ADAPTATION_GUIDE.md`](COUNTRY_ADAPTATION_GUIDE.md)
  walks through every substitution point (branding, specialty catalog, CAP-evaluation
  checklist, provider templates, regulation catalog, site/folder naming) with an effort
  estimate for each.
- **Evaluating this for a real deployment?** Read `An ideal production configuration.md`
  before committing to anything — the gap between
  "the demo runs" and "this is production-hardened" is real and currently unclosed.
- **Working in the code itself?** `CLAUDE.md` (repo root) is the dense, cross-referential
  technical reference this project's own contributors use day to day.

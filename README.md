# Compliance Platform

An aviation safety compliance/inspection platform for civil aviation authorities (CAAs),
covering ICAO USOAP-aligned inspection planning, field checklists, findings, corrective
action plans, follow-up verification, and finding-closure review.

This is a **reference implementation**, configured today for one specific authority (the
Dominican Republic's IDAC), built to be adapted by other CAAs — not a generic, ready-to-run
multi-tenant product out of the box.

## Start here

**New to this platform?** → [`GETTING_STARTED_FOR_ADOPTERS.md`](GETTING_STARTED_FOR_ADOPTERS.md)
covers hardware requirements, realistic setup timing, and what the demo actually shows you,
before you clone anything.

**Adapting this for your own authority?** → [`COUNTRY_ADAPTATION_GUIDE.md`](COUNTRY_ADAPTATION_GUIDE.md)
walks through every substitution point with an effort estimate for each.

**Evaluating this for a real deployment?** → [`An ideal production configuration.md`](An%20ideal%20production%20configuration.md)
is the target production architecture — read its status banner first; it's a roadmap, not
the current state.

**Working in the code?** → [`CLAUDE.md`](CLAUDE.md) is the dense, cross-referential technical
reference the project's own contributors use day to day.

**Checking release status?** → [`RELEASE_READINESS_CHECKLIST.md`](RELEASE_READINESS_CHECKLIST.md).

## The six component repositories

This is a collection of independent repositories, not a monorepo — each one below has its
own history, CI, versioning, and release cadence, and is cloned separately. This repository
is the front door that ties them together; it contains no code and no submodules.

| Repository | What it is | Stack |
|---|---|---|
| [atrocore-docker](https://gitlab.com/safety-app2/compliance_atrocore) | AtroCore/AtroPIM backend — entity store for inspections, inspectors, specialties, locations | Docker Compose, Apache+PHP 8.4, PostgreSQL 15 |
| [compliance_cmis](https://gitlab.com/safety-app2/compliance-cmis) | Alfresco Content Services customization — content model, Share forms, Web Scripts | Alfresco/ACS, JS Web Scripts, Docker Compose |
| [compliance_flow](https://gitlab.com/safety-app2/compliance_flow) | Node-RED integration middleware — the API gateway between the checklist app and AtroCore/Alfresco | Node-RED (flows.json-driven) |
| [compliance_import](https://gitlab.com/safety-app2/compliance_import) | ZIP ingestion service — validates and stores inspection/follow-up payloads into Alfresco | Python, FastAPI, uvicorn |
| [compliance_web](https://gitlab.com/safety-app2/compliance_web) | Web UI for inspection/compliance workflows plus auth/session backend | Vue 3 + Vite frontend, Express backend, PostgreSQL |
| [compliance_checklist](https://gitlab.com/safety-app2/compliance_app) | Offline-capable Electron desktop app for field inspectors | Electron, Vue 3, Node.js, Pinia |

See `CLAUDE.md`'s "Big-picture architecture" section for how data flows between them.

## Status

Pre-release. See `RELEASE_READINESS_CHECKLIST.md` for exactly what's still open before a
public launch — most notably, a legal review of third-party licensing terms is still pending
and is a hard blocking gate on any public promotion of this project.

## License

Apache License 2.0 for the original documentation in this repository — see
[LICENSE](LICENSE) and [NOTICE](NOTICE). Each of the six component repositories carries its
own licensing; see their individual `THIRD_PARTY_LICENSES.md` files.

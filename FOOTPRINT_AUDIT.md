# Footprint audit — what a "Starter" deployment can actually drop

**Date:** 2026-09-15 · **Stack:** the live dev stack (Alfresco 25.2 Community, AtroCore, Node-RED 4.1.10, PostgreSQL ×2)
**Method:** a fixed 23-probe matrix run against the running stack, then re-run with exactly one component stopped and restored afterwards. A probe that fails at baseline is not attributable, so only the baseline-passing set counts. Baseline **23/23**; after restoring everything **23/23** again (so no state was left behind).

Harness: `.footprint-audit/audit.mjs` (temporary, workspace root — not part of any repo). Raw results: `.footprint-audit/results-*.json`.

Probes: the 15 read-only gateway endpoints via `compliance_flow/scripts/smoke-flows.mjs`, the end-to-end `GET /inspectionPlan` through the gateway, the six Read/report Alfresco Web Scripts using their committed `example/` payloads, and the Alfresco readiness probe.

## Results

| Component stopped | Probes ok | What broke | Failure mode |
|---|---|---|---|
| **Share** | **23/23** | nothing | — |
| **Solr** | 17/23 | `/checklist`, `/findings/open` (gateway); `findings/open/query`, `checklist/prior-findings/open`, `providers/provider-history-report`, `usoap/ce-evidence-report` (Web Scripts) | Web Scripts: clean **HTTP 500** `Failed to execute search`. Gateway: **timeout** (no response) |
| **ActiveMQ** | 22/23 | `GET /inspectionPlan` end-to-end | **Hang — no error, no timeout.** All direct Web Scripts still fine |
| **transform-core-aio** | 20/23 | `/inspectionPlan` (gateway), `inspection/generate`, `inspection/report/generate` | Clean **HTTP 500** / `{"success":false,"error":"HTTP 500"}` |

## Verdict per component

**Share — droppable.** It is the admin/auditor web UI and nothing in the API path touches it. **Caveat:** Share is where the USOAP evidence "smart folder" navigation lives (see `compliance_cmis/docs/smart-folders-operational-map.md`), so dropping it removes the auditor-facing evidence browser, not just a redundant front end. That may be an acceptable Starter trade-off, but it is a real capability loss.

**Solr — required.** It backs every AFTS/Lucene query, and those queries are the regulatory core: retrieving the checklist for an inspection and listing open findings. Without it the two gateway endpoints the field app depends on stop responding *at all*, and four report Web Scripts 500. Note the two different failure modes: the Web Scripts fail fast and loudly, the gateway endpoints hang.

**ActiveMQ — required, and it has the worst failure mode.** Everything synchronous keeps working: reads, searches, CRUD, template rendering, and PDF transforms on documents that are new. What breaks is asynchronous work attached to existing nodes. Evidence:
- `GET /inspectionPlan` for an existing plan document hung: 45 s, then 60 s and 90 s on repeat, with no response at all.
- The same payload shape writing a **new** document name returned **HTTP 201 in 0.42 s**.
- The Alfresco log showed the webscript *did* its work (`[transformInspectionPlan] Updated existing PDF content: …AV-MDPP-A-0001.pdf`) — so the transformed PDF was produced and the response still never came back.
- Restarting the broker cleared it immediately: the previously hanging call returned **200 in 1.9 s**.

So the broker is not needed to *do* the work; it is needed to *finish* certain operations. A missing broker produces an indefinite hang instead of an error — for an unattended install in a low-resource State, that is the worst possible failure mode, because nothing surfaces and no timeout fires.

**transform-core-aio — conditionally droppable.** Without it, plan and report generation fail cleanly (500), and **the canonical import path degrades gracefully by design**: `replaceContentWithPdf()` in `import-canonical-models.post.js` is wrapped in a `try/catch`, logs `pdf-render skipped …`, returns `false`, and leaves the document with its `.json` name — the code comment documents that a later successful render **self-heals** the node to `.pdf`. So a "records first, documents later" Starter is coherent: import still works, PDFs appear once the transformer returns. *(Verified in code, not exercised live: the committed `example/import-canonical-checklist.sample.json` is rejected by the endpoint itself with `Missing required field: inspectionCode` even though it carries `checklist.inspectionCode` — so the sample and the endpoint disagree, and it cannot be used as a probe. See "Incidental findings".)*

## Footprint: what pruning actually buys

Measured per-container memory (MiB, `docker stats --no-stream`):

| Component | Idle | Limit set | Droppable? |
|---|---|---|---|
| alfresco | 1759–1799 | **1855** ← pinned | required |
| solr6 | 1482–1614 | 2048 | required |
| share | 592–765 | 1024 | yes (with caveat) |
| transform-core-aio | 534–639 | 1536 | conditional |
| atro-web (AtroCore) | 452–459 | — | required |
| activemq | 212–336 | 1024 | required |
| node-red | 122–133 | — | required |
| postgres (Alfresco) | 107–114 | 512 | required |
| proxy | 90–98 | 128 | required |
| postgres (AtroCore) | 60–62 | — | required |
| **Subtotal (10 containers)** | **≈ 5.3–6.0 GiB** | | |

Adding `compliance_web` and `compliance_import` (~0.5 GiB) gives **~5.8–6.5 GiB idle**. Dropping Share **and** transform saves only **≈1.1–1.4 GiB**.

**Conclusion: the footprint is structural, not pruning-able.** Alfresco + Solr + two PostgreSQL instances is ~3.5 GiB before a single line of this platform's own code runs. A "Starter" compose profile can honestly promise:

- **8 GB RAM / 4 vCPU** — workable single server (tight; Alfresco's 1.855 GiB cap is already 95–97% used at idle)
- **16 GB RAM / 6–8 vCPU** — comfortable, with headroom for report generation and real document volume

It **cannot** promise a 4 GB box. If the mission needs that, the lever is not a compose profile — it is whether Alfresco is the right document store for the Starter tier at all. That is a large decision: the VSO model is 1,466 lines / 168 type-aspect-property-association declarations across 10 Web Script areas.

## Actions this audit suggests

1. ~~Raise Alfresco's memory limit in any install profile.~~ — **done (2026-09-17).** `compliance_cmis/docker-compose.yml`'s `alfresco.mem_limit` raised `1900m` → `2560m`; applies on the next `docker compose up -d` (config-only change, does not force-restart a running container).
2. ~~Ship a minimum health check with the quickstart.~~ — **done (2026-09-17), partially.** `demo-quickstart.sh` already probed Alfresco/Node-RED/import/web/AtroCore over HTTP; it now also checks `docker compose ps` container health for Alfresco/Solr/ActiveMQ/transform-core-aio before proceeding, specifically to catch a dead broker before it causes a silent hang later rather than after. The `/health` endpoints P3 calls for (`compliance_flow`, `atrocore-docker`) are still open.
3. **Keep Solr, ActiveMQ and transform-core in the Starter profile**; drop only Share, and only if losing the auditor evidence browser is acceptable, or make it optional and documented.
4. ~~Reword the promise.~~ — **done in `CLAUDE.md` and the runbook (2026-09-17).** Both now state "8 GB minimum (tight), 16 GB recommended" rather than "modest hardware." A planned adopter-facing getting-started doc should lead with the same figure.
5. **Make one operational decision explicit:** a Starter without transform-core is viable only if plan/report generation is out of scope at that tier. That is a product decision, not a technical one.

## Incidental findings

- **`example/import-canonical-checklist.sample.json` did not satisfy the endpoint it documented. Fixed** in `compliance_cmis!68`: the endpoint answered `400 Missing required field: inspectionCode` because the two files listed as its example payloads were canonical *document* payloads (the `{ "checklist": … }` shape the importer writes and the endpoint reads back), not request bodies. They are now `canonical-{checklist,finding}-document.sample.json`, a real flat request sample exists (`import-canonical-request.sample.json`), and `validate-examples.cjs` rejects a request sample that is wrapped or lacks a root `inspectionCode`. Verified end-to-end: `success: true`, 6 documents created, 1 source processed. The broader gap stands — `validate-examples.cjs` still checks shape rather than endpoint acceptance, which is why this drifted for months.
- **`example/FollowUp H-MDPPA0001-AVIS-001 01.json` references finding `H-MDPPA0001-AVIS-001`, which does not exist in the current dataset** (404, correctly reported). Expected for a sample, but it cannot be a smoke test either.
- Sample payloads reference a different data vintage than the platform's own test data (`INSP-2026-0225` vs the Nomenclatura `AV-MDPP-A-0001`), so they exercise a path but not this deployment's records.
- **Failure modes are inconsistent across components** — Solr gives clean 500s from the Web Scripts but hangs at the gateway; ActiveMQ hangs; transform fails cleanly. For self-serve installs, error shape matters as much as uptime.

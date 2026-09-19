# Country Adaptation Guide

## 1. Overview

This platform is a **reference implementation**, not a generic multi-tenant product. It was built for one specific civil aviation authority — the Dominican Republic's IDAC (Instituto Dominicano de Aviación Civil) — and that authority's own branding, specialty taxonomy, CAP-evaluation checklist, and provider structure are baked into the code and seed data, not abstracted behind configuration.

Adapting it for a different CAA is a **configuration and data exercise, not a rewrite**: nothing here requires touching the domain model, the finding/CAP/follow-up lifecycle, the USOAP citation chain, or any webscript's business logic. But it does touch **all six repos**, and some of the substitutions below have real one-way consequences (see §3's warning about document IDs). Budget more than an afternoon — the effort table in §8 gives a per-item estimate, but plan on this being a multi-day project for a first adaptation, most of it in §4 (rebuilding the CAP checklist) and §6 (populating your own national regulation catalog).

The sections below are ordered easiest-to-hardest, so start at the top and stop whenever the remaining sections don't apply to your authority yet (e.g., you can run a fully working demo after §2 alone, with everything else still showing IDAC's data).

**What you get without touching anything**: the ICAO-standard parts. The USOAP Critical Elements (`CE-1`...`CE-8`), the Nomenclatura document-ID scheme's structure (ICAO 4-letter location codes), and — as of this platform's ICAO reference-data seed — the full catalog of ICAO Annex documents, Annex paragraphs, and USOAP Protocol Questions (15 documents / 1,890 paragraphs / 281 questions, `atrocore-docker/scripts/seed-icao-reference-data.sh`) are all genuinely CAA-independent and ship correctly for any authority out of the box. Nothing in this guide touches them.

---

## 2. Rebranding — `compliance_cmis/configs/entity-profile.json`

**Start here.** This is the one substitution point that's already fully built, parameterized, and requires no code changes — a good confidence-builder before the harder sections.

The file:

```json
{
  "entityName": "DEPARTAMENTO DE CONTROL DE VIGILANCIA SNA/AGA",
  "entityLogoBase64": "<base64-encoded image>",
  "docControlCodes": { "informeFinal": "DVSO-CS-F04", "planDeInspeccion": "DVSO-CS-F02" },
  "docControlVersion": "3.0"
}
```

It's bind-mounted into the Alfresco container (`docker-compose.yml`: `./configs/entity-profile.json:/usr/local/tomcat/shared/classes/alfresco/extension/entity-profile.json`) and read by `webscripts/common/vso-paths.lib.js`'s `loadEntityProfile()` at template-render time — every generated plan, inspection report, and finding/CAP/follow-up PDF picks these values up. If the file is missing or unreadable, it silently falls back to IDAC's own values (`ENTITY_PROFILE_FALLBACK` in the same file), so a broken edit degrades gracefully rather than breaking report generation.

**To adapt**: replace `entityName` with your authority's name, `entityLogoBase64` with your own logo (base64-encoded image data — any format the report templates' image handling accepts), and `docControlCodes`/`docControlVersion` with your own document-control numbering if you have one. Restart the Alfresco container to pick up the change (bind-mounted, but Alfresco doesn't watch the file for live reload).

**Effort: trivial.**

---

## 3. Replacing the specialty catalog

The 16 specialty codes (`APR`, `AVIS`, `FAU`, `PAV`, `SSEI`, `AIM`, `ATS`, `COM`, `ECNS`, `EMET`, `FIS`, `MET`, `NAV`, `SAR`, `SUR`, `DPR`) are **this authority's own internal reorganization taxonomy — not an ICAO standard.** Contrast with the USOAP Critical Elements `CE-1`...`CE-8`, which *are* ICAO-standard and need no change.

They're defined in two places that must be kept in sync:
- `atrocore-docker/sql/seed-nomenclatura-catalog.sql` — the authoritative seed, loaded into AtroCore's `Specialty` entity.
- `compliance_cmis/tools/smart-folder-catalog.json`'s `specialties` array — must match, per that file's own header comment, or the Share smart-folder navigation shows stale codes.

**Why this matters more than it looks**: the specialty code is the `EEE` segment of *every* generated Nomenclatura document ID (`LV-XXXXT####-EEE`, `H-XXXXT####-EEE-###`, etc. — see root `CLAUDE.md`'s "Nomenclatura document-ID scheme" section). **Changing specialty codes does not retroactively renumber IDs already generated under the old codes.** Decide your specialty taxonomy *before* seeding real inspection data, or accept that historical IDs will carry a code from a taxonomy you've since replaced.

**To adapt**: edit both files' code/name lists to match your authority's own specialty structure, re-run `atrocore-docker/scripts/seed-nomenclatura.sh`, and regenerate the smart-folder templates per `compliance_cmis/tools/`'s own tooling (`generate-smart-folder-templates.js`).

**Effort: moderate** — mechanical, but touches two repos and has the ID-stability caveat above.

---

## 4. Replacing the CAP-evaluation checklist

The 35-criterion `IDAC-PAC-EVAL-01` ("Evaluación del Plan de Acción Correctiva") checklist is hardcoded, in Spanish, and **duplicated verbatim in two files**:

- `compliance_web/src/utils/capEvaluationCriteria.js` (frontend display)
- `compliance_web/server/domain/capEvaluationCriteria.cjs` (backend validation)

Each file's own header comment says why there are two copies: Vite can't cleanly import the `.cjs` module from `src/`, so the 35-entry array (grouped into sections — `ADMIN`, `RCA`, `RISK`, `CONTAINMENT`, `ACTIONS`, and more) is maintained by hand in both places. **There is no shared spec file for this one** — unlike the Nomenclatura ID scheme, which centralizes into `compliance_cmis/domain-rules/nomenclatura.spec.json` and is vendored with conformance tests into the other repos. Editing only one copy will desync frontend display from backend validation.

The content itself is specific to IDAC's own corrective-action-plan review process (referencing `IDAC-NC-01 §7`) and is entirely in Spanish — a different authority almost certainly has a different CAP-review checklist, in whatever language it operates in.

**To adapt**: replace both files' criteria arrays with your own review checklist, in the same `{ code, section, kind, label }` shape (`kind` is `'binary'` for yes/no items, `'conclusion'` for a free-text inspector conclusion per section). Keep both files' array structurally identical — same codes, same order — since the backend validates against exactly what the frontend renders.

**Worth flagging for a future platform cycle, not something this guide asks you to build**: centralizing these into one shared spec (mirroring the Nomenclatura pattern) would remove this whole dual-maintenance risk. If your adaptation effort has spare capacity, doing that centralization *once* — as part of adapting it for your own use — would be a genuinely useful contribution back.

**Effort: involved** — not technically hard, but requires your own CAP-review process to already be well-defined, and touching two files correctly in lockstep.

---

## 5. Substituting provider/smart-folder templates

`compliance_cmis/tools/smart-folder-catalog.json` and the generated templates under `compliance_cmis/templates/pilot/` are keyed to IDAC's three named service-provider categories:

- `vigilancia-pilot-template-profile-idac.json` — IDAC's own oversight of ATS/CNS/navigation providers
- `vigilancia-pilot-template-profile-indomet.json` — INDOMET (the DR meteorological agency)
- `vigilancia-pilot-template-profile-aeropuertos.json` — airport operators
- `vigilancia-pilot-template-base-comun.json` — the shared base template all profiles extend

Each profile in the catalog's `profiles` array pins a real AtroCore `providers` node ID and a `specialtyCodes` subset (e.g., IDAC's profile covers `SUR, COM, NAV, ATS, SAR, FIS, AIM, ECNS, EMET, DPR`; INDOMET's covers just `MET`). This is how the Share "smart folder" navigation (CE × area × evidence-role/type, provider-profile-scoped — see `compliance_cmis/docs/smart-folders-operational-map.md`) knows which folder structure to generate for which provider.

**To adapt**: identify your own authority's service-provider categories (an airport operator, an ANS provider, a met service, etc. — however your oversight programme is actually organized), and replace the `profiles` array's provider IDs, titles, and `specialtyCodes` mappings accordingly. The `baseComun`/`sections` structure (checklist/finding/CAP/follow-up folder types) is generic and shouldn't need to change.

**Effort: moderate** — depends on how many provider categories your authority has; each is a mechanical template addition once you understand the pattern from IDAC's three.

---

## 6. Substituting the regulation catalog

This is the good news section: the `Normativa`/`AcapiteOACI` regulation-citation model is **already structurally generic** — plain `entityDefs` with `fields`/`links`/`indexes` only, no DR-specific schema (`atrocore-docker/metadata/entityDefs/Normativa.json`, `AcapiteOACI.json`).

Real DR national-regulation text was **never committed to this repository** — it lived only in gitignored database dumps, and the tracked demo seed (`atrocore-docker/sql/seed-demo-dataset.sql`) already uses a synthetic `"Demo Civil Aviation Regulation"` citation (`RAD-DEMO`), not real IDAC regulation text. There is nothing to remove.

Recall the citation chain from root `CLAUDE.md`: `UsoapProtocolQuestion → cites → AcapiteOACI (ICAO Annex paragraph) → Normativa (your national regulation article) → ChecklistQuestion`. The ICAO-standard half of that chain — the Annex documents and paragraphs — now ships pre-populated for every adopter via `atrocore-docker/scripts/seed-icao-reference-data.sh` (15 documents, 1,890 paragraphs, 281 Protocol Questions — see root `CLAUDE.md`). **You only need to add your own half**: `Normativa` rows citing your own country's aviation regulations, linked to the existing `AcapiteOACI` paragraphs they implement.

**To adapt**: populate `Normativa` with your own national regulation articles, linking each to the relevant pre-seeded `AcapiteOACI` row. The quickest route is `atrocore-docker/data-packs/Normativa.csv`: it is a plain CSV template whose `RegulationID` column points at your `Reglamento` row and whose `AnnexParagraphID` column (left empty in the template) takes the `AcapiteOACI` id — import it with `make import-data-packs PACK=normativa`, and re-importing after an edit updates the rows in place. The AtroCore admin UI and a hand-written seed script both work too. This is new data entry, not a schema or code change.

**Effort: low** (per-article data entry effort scales with how much of your regulatory corpus you want cited from day one — the *mechanism* is zero-effort).

---

## 7. Rebranding the Alfresco site/folder structure

The Alfresco Share site itself is named `vigilancia-de-la-so`, with Spanish subfolder names (`Vigilancia/{Inspecciones, Datos de campo, Hallazgos, Template data}`, `Documentos/Formatos`). This is hardcoded in **more than one place, with inconsistent parameterization**:

- `compliance_cmis/scripts/bootstrap-site-content.sh` — **already parameterized**: `SITE_SHORT_NAME="${SITE_SHORT_NAME:-vigilancia-de-la-so}"`. Setting this env var before running the script changes the *site name* it creates.
- `compliance_cmis/webscripts/common/vso-paths.lib.js` — **not parameterized**. Its `__VSO_PATHS` defaults hardcode the full `Sites/vigilancia-de-la-so/documentLibrary/...` paths directly. Per root `CLAUDE.md`, this file is meant to be *the* single source of truth for Alfresco folder paths — update it here first.
- `compliance_cmis/webscripts/canonical-model-import/import-canonical-models.post.js` — **inlines its own copy** of the same defaults (`resolveVsoPaths()`'s fallback object), because — per that file's own comment — `importScript()` is unavailable in that webscript's execution context and it can't reliably load `vso-paths.lib.js`. If you change the paths, grep for the literal string `vigilancia-de-la-so` across `webscripts/` to catch this and any other inlined copy; don't assume editing `vso-paths.lib.js` alone is sufficient.

The folder *names in Spanish* (`Inspecciones`, `Hallazgos`, etc.) are separate from the *site name* — translating them to another language, if your authority doesn't operate in Spanish, means touching the same set of files plus every webscript that references a specific subfolder by its Spanish name.

**To adapt**: decide your site/folder naming, update `vso-paths.lib.js`'s defaults, grep for and update every inlined copy, and set `SITE_SHORT_NAME` (or hardcode your new default) when running `bootstrap-site-content.sh` on a fresh instance. Existing deployments with data already under the old site name would need a repository-level move/rename, which this guide doesn't cover (that's a live-migration problem, not a fresh-adaptation one).

**Effort: involved** — the inconsistent parameterization across files is the main risk; budget time for the grep-and-verify pass, not just the edits themselves.

---

## 8. Summary table

| # | What | File(s) | Repo | Effort |
|---|---|---|---|---|
| 2 | Rebranding (name, logo, doc-control codes) | `configs/entity-profile.json` | compliance_cmis | Trivial |
| 3 | Specialty catalog | `sql/seed-nomenclatura-catalog.sql`; `tools/smart-folder-catalog.json` | atrocore-docker; compliance_cmis | Moderate (ID-stability caveat) |
| 4 | CAP-evaluation checklist | `src/utils/capEvaluationCriteria.js`; `server/domain/capEvaluationCriteria.cjs` | compliance_web | Involved (two files, no shared spec) |
| 5 | Provider/smart-folder templates | `tools/smart-folder-catalog.json`; `templates/pilot/*.json` | compliance_cmis | Moderate |
| 6 | Regulation catalog | `Normativa`/`Reglamento` entity data via `data-packs/{Reglamento,Normativa}.csv` (or the admin UI; no schema change) | atrocore-docker | Low (mechanism), scales with corpus size |
| 7 | Site/folder naming | `scripts/bootstrap-site-content.sh`; `webscripts/common/vso-paths.lib.js`; inlined copies (grep `vigilancia-de-la-so`) | compliance_cmis | Involved (inconsistent parameterization) |

A CAA's technical lead can scope their own adaptation project from this table alone, without reading all six repos first.

---

## See also

- `An ideal production configuration.md` (repo root) — the target production architecture (Vault, Keycloak, PostgreSQL replication, container hardening). None of it exists yet; read it once your adaptation is working and you're planning a real deployment, not before.
- Several of the demo's known open items are relevant to an adaptation effort — most notably, the Share smart-folder creation step is still manual (§7.9 of the runbook). See `RELEASE_READINESS_CHECKLIST.md` (repo root) and `CLAUDE.md`'s known-limitations summary for the full list.
- `FOOTPRINT_AUDIT.md` (repo root) — hardware sizing (8 GB RAM minimum, 16 GB recommended) before you provision anything.

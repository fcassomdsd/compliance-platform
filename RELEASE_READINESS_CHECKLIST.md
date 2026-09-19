# Release-Readiness Checklist

**Last updated:** 2026-09-18.

One line per open-source release workstream. This tracks the same scoping plan referenced
in `CLAUDE.md` and `COUNTRY_ADAPTATION_GUIDE.md` — see those for detail. Update this file as
items close; it's the single place to check "are we ready to publish" without re-reading
every workstream's full writeup.

- [x] **(W0) Repo-publishing structure decided and built.** Chosen: six independently
  published component repos plus this thin umbrella meta-repo (docs/quickstart only, no
  submodules) — [`compliance-platform`](https://gitlab.com/safety-app2/compliance-platform),
  public, `main`/`develop` model matching the other six repos. Workstream 5 is now unblocked.
- [ ] **(W1) Legal review complete — hard blocking gate.** Independent of every other
  workstream's progress, this must close before any public push. Two questions for counsel:
  (a) does publishing Compose files that *reference* Alfresco's LGPLv3-family images (ACS,
  Share, Transform Service, Search Services, ActiveMQ) count as "distribution" under LGPLv3,
  and does the clean-room-extension-vs-derivative-work distinction on `compliance_cmis`'s
  customizations matter; (b) AtroCore's own application core (`atrocore/core` and five sibling
  packages) is GPL-3.0-only — historically the bigger constraint of the two, because it was
  compiled into the built `atro-web` image, though the image no longer contains it (see W5).
  Record the outcome in a new `LICENSING_REVIEW_OUTCOME.md`. **Engineering-side preparation is
  done**: `compliance_cmis/THIRD_PARTY_LICENSES.md` and
  `atrocore-docker/THIRD_PARTY_LICENSES.md` each carry a best-faith worst-case walkthrough of
  the two questions for counsel (both converging on notice/license-text compliance rather than
  relicensing), plus the standing constraint "never build or publish a modified Alfresco
  image". The review itself has not started and needs a human legal reviewer to commission;
  nothing further to do here without one.
- [x] **(W1) `THIRD_PARTY_LICENSES.md` populated in all six repos**, each backed by an actual
  dependency/license scan (`license-checker` for the three npm repos, `pip-licenses` for
  `compliance_import`, manual `LICENSE.txt` inspection for `atrocore-docker`'s Composer
  packages). No copyleft found in any npm/pip dependency tree.
- [x] **(W2) Gateway `API_KEY` on by default** in all published `.env.example` files —
  `compliance_flow!40`, `compliance_web!71`, `compliance_import!42`, `atrocore-docker!57`.
- [x] **(W2) Demo-credentials warning present** in the runbook, the quickstart script's own
  output, and the adopter-facing getting-started doc.
- [x] **(W2) Alfresco memory limit right-sized** (`compliance_cmis!80`, 1900m → 2560m) and a
  minimal service-up healthcheck shipped with the quickstart (Alfresco/Solr/ActiveMQ/
  transform-core-aio container-health preflight, so a dead broker fails loudly instead of
  hanging silently).
- [x] **(W3) ICAO reference data seeded.** Extracted from the legacy standalone dump into a
  tracked, idempotent seed (`atrocore-docker/sql/seed-icao-reference-data.sql` — 15 documents,
  1,890 paragraphs, 281 protocol questions, 439 citations), wired into the quickstart and CI.
  Merged (`atrocore-docker!56`); full whole-stack `demo:verify` run confirmed green end to end.
- [x] **(W3) `COUNTRY_ADAPTATION_GUIDE.md` published** at repo root, covering all six
  substitution points (rebranding, specialty catalog, CAP-evaluation checklist, provider
  templates, regulation catalog, site/folder naming) with a per-item effort estimate.
- [x] **(W4) `GETTING_STARTED_FOR_ADOPTERS.md` published** at repo root (hardware floor,
  realistic first-run timing, prerequisites, what the demo dataset actually is, the P3/
  production-hardening caveat). `CLAUDE.md` carries an adopter banner pointing to it, and all
  six repo READMEs link to it from their quickstart sections — merged to `develop` in all six
  repos (`atrocore-docker!59`, `compliance_cmis!82`, `compliance_flow!42`,
  `compliance_import!44`, `compliance_web!73`, `compliance_checklist!86`).
- [x] **(W5) Public release infrastructure.** W0 is resolved, unblocking this workstream; all
  five sub-items are now resolved (the last two on 2026-09-18):
  - [x] All six repos CalVer-tagged consistently — `atrocore-docker` and `compliance_import`
    each cut their first release (`2026-09-18`), matching the other four. **Update
    2026-09-18:** four repos could not actually produce a new CalVer tag from their branch —
    `compliance_web` and `compliance_checklist` had no `## [YYYY-MM-DD]` CHANGELOG section at
    all, and `compliance_cmis`/`compliance_flow`'s newest dated section was already tagged.
    All four now carry a dated `## [2026-09-18]` section and `scripts/release-tag.sh` computes
    a tag; `atrocore-docker`/`compliance_import` need `## [2026-09-18.2]` for a second
    same-day release. (`compliance_flow` also carries a legacy `2026-09-13` tag with no
    corresponding CHANGELOG section.)
  - [x] Pre-1.0 vs. 1.0.0 stance decided and documented: **"reference implementation,
    pre-1.0"** — see `README.md`'s Status section. No repo is labeled `1.0.0` for this
    launch; version numbers stay honest about P3 (production-hardening) sitting at 0%.
  - [x] Public CONTRIBUTING.md/CODE_OF_CONDUCT.md pass — all six component repos already had
    both; this umbrella repo was missing `CODE_OF_CONDUCT.md` (now added) and its
    `CONTRIBUTING.md` gained a response-time-expectations note.
  - [x] Public CI green from an empty checkout — **done 2026-09-18.** All six repositories now
    carry a GitHub Actions mirror of their GitLab validation jobs
    (`github.com/fcassomdsd/<repo>`), and `atrocore-docker`'s mirror also carries
    `demo-verify`. All six CI badges read **passing**. Caveat: `demo-verify` is
    `workflow_dispatch`/`schedule` only in both systems, so the badge proves the gated jobs;
    the whole-stack guard runs unattended on the weekly schedule.
  - [x] A decision on pre-built image publishing — **resolved, and the question became moot
    rather than answered.** The AtroCore application install moved from image-build time to
    container bootstrap, so the built `atro-web` image no longer contains GPL-3.0 code in any
    layer (verified by inspecting the built image). There is no longer a GPL-flavored
    pre-built image to publish, so the LGPLv3 analysis is unchanged and the "combined work"
    question is closed for these images. Recorded in
    `atrocore-docker/THIRD_PARTY_LICENSES.md`; W1's remaining questions are unaffected.
- [x] **(W6) Must-fix tech-debt items closed, plus a 2026-09-18 hardening pass.** The
  canonical-import search-index race (now a deterministic node lookup with search as fallback)
  and the `vso:evidenceReviewStatus` false-enforcement-gate doc claim are both fixed;
  `API_KEY`-off-by-default is covered by W2. A follow-up pass on 2026-09-18 closed the next
  tier of items from the internal technical-debt registry: the **CAP half** of the
  search-index race (`findCorrectiveActionByCapId` resolved only through search, now
  deterministic-first with a CI-visible drift guard on the declaration invariant), the
  **closure-declaration divergence** (`/api/follow-up/import` did not clear
  `vso:closureRejectionReason` like the canonical import), `compliance_import`'s
  `.dockerignore` credential-baking gap and unenforced schema `format` keywords,
  `compliance_checklist`'s dormant `save/read-alfresco-cred` IPC surface and last
  hard-coded developer path, and `compliance_web`'s unbounded `auth_session` growth (new
  cleanup job) and its four duplicated AFTS-escape copies. The remaining items ship as
  documented known limitations, not blockers — most consequentially, **P3
  production-hardening is at 0%** (no Vault, Keycloak, observability, or replication), which
  is stated prominently in both the adopter doc and the production-configuration doc's own
  banner. Detail: `internal/TECHNICAL_DEBT_ANALYSIS.md`.
- [x] **(W7) Adopter onboarding is installable, not hand-entered.** A fresh deployment used to
  present 32 entities with no menu entry pointing at most of them (AtroCore loads layout
  *content* from its `layout` table or its own module resources — never from the
  `metadata/layouts/` that `install-metadata.sh` writes) and no way to load the authority
  records needed to plan an inspection without reading SQL. Three rounds of work in
  `atrocore-docker`, all merged to `develop`:
  - **Navigation and layouts.** `scripts/install-layouts.sh` seeds a `default` layout profile
    whose menu covers 26 platform entities in 7 groups and materialises all 123 tracked layouts
    into it via AtroCore's own `PUT /<Entity>/layout/<view>` API (including 9 related-scope
    panels); the 29 dead `listDashlet` files were dropped. `FindingSeverity` is seeded (A/B/C)
    because `compliance_web` queries it live, and `scripts/enable-spanish-labels.sh` adds
    `es_DO` as an additional language and seeds the 8 vocabulary labels that were rendering in
    English in a Spanish-language product. Asserted by both `fresh-install` CI jobs
    (7 groups / 123 layouts / 8 labels).
  - **Placeholder authority data.** `sql/seed-starter-dataset.sql` +
    `scripts/seed-starter-dataset.sh` (`make db-seed-starter YES=1`): 13 clearly-marked
    `starter-` rows across 12 tables showing how a provider, contact, inspector, location
    service, inspection cadence, regulation and article connect, additive and
    `ON CONFLICT DO NOTHING` so an edit is never overwritten, with `--remove` to delete
    exactly those rows.
  - **The same records as editable CSV.** `data-packs/` + `scripts/import-data-pack.py`
    (`make import-data-packs`) drives AtroCore's own import module (`ImportFeed` +
    `ImportConfiguratorItem` + `easyCatalog`, no file upload), so an adopter who does not write
    SQL edits a spreadsheet and re-imports; rows upsert on `ID`. `scripts/validate-data-packs.py`
    asserts the packs and the SQL seed write exactly the same ids, and both `fresh-install` CI
    jobs now apply the seed and then import every pack, which is what caught the one real defect
    here — and it turned out to be a **data-model** defect, not a seeding one:
    `InspectionCadence.inspectedProvider` was a required link to the per-visit
    `InspectedProvider`, so a cadence could not exist until a site visit had been planned,
    even though a cadence is precisely what *causes* the first visit. The cadence was removed
    from both onboarding paths as a stopgap while the question was referred to the domain
    owner; it has since been **fixed at the model** — the link now points at
    `LocationService` (authority data, and the grain that also makes an impossible
    provider/location/specialty combination unrepresentable), with a migration, a unique
    index on the natural key, and the cadence restored to both onboarding paths. Two live
    defects in `compliance_web`'s scheduling job that the same confusion had hidden were
    fixed alongside. Detail: `data-packs/README.md`, `atrocore-docker/CHANGELOG.md`,
    `compliance_web/CHANGELOG.md`.
- [ ] **(W8) AtroCore decommissioning path** — explicitly **post-release**, not a gate on this
  launch. Direction agreed (Postgres + a custom lightweight admin UI + endpoints implemented
  directly for what Node-RED needs, migrated incrementally entity-by-entity, leaning on
  Node-RED's role as the integration hub to keep the swap low-disruption for
  `compliance_web`/`compliance_checklist`), but no implementation work has started.

## What's actually blocking a public release today

One thing, requiring action from the project owner rather than more unilateral engineering
work:

1. **Commission the legal review (W1)** — the hard gate. Everything else is ready: W0 and
   W2–W7 are closed, and W5's two sub-items that were waiting on W1 are resolved (the public
   CI mirror is green and the pre-built-image question became moot). The engineering-side
   preparation for counsel is done; the review itself still has to be commissioned and close
   first.

W8 (AtroCore decommissioning) is deliberately post-release and is not a gate. The remaining
known limitations — P3 production-hardening at 0%, the field app's hand-rolled ID regexes,
`compliance_import`'s partial write idempotency, the `compliance_flow` endpoints still without
a `catch`, and the deferred follow-up evidence-review redesign — are catalogued in
`internal/TECHNICAL_DEBT_ANALYSIS.md` and do not block publication.

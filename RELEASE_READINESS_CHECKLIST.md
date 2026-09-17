# Release-Readiness Checklist

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
  packages) is GPL-3.0-only and compiled into the built `atro-web` image — the bigger
  constraint of the two, since it's compiled in rather than referenced. Record the outcome in
  a new `LICENSING_REVIEW_OUTCOME.md`. Not started — needs a human legal reviewer to
  commission; nothing further to do here without one.
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
- [ ] **(W5) Public release infrastructure.** Blocked on W0. Needs: public CI green from an
  empty checkout under whichever repo structure W0 picks (GitHub Actions mirror of
  `demo:verify` above all — the single most convincing thing a prospective adopter can watch
  pass); all six repos CalVer-tagged consistently (`atrocore-docker` and `compliance_import`
  currently have zero tags despite the shared tooling already working elsewhere); a documented
  pre-1.0 vs. 1.0.0 stance (recommend "reference implementation, pre-1.0" given
  `compliance_web` is literally `0.0.0` and P3 is at 0%); a decision on pre-built image
  publishing, deferred to W1's outcome since it could change the LGPLv3 analysis; a public
  CONTRIBUTING.md/CODE_OF_CONDUCT.md pass.
- [x] **(W6) Must-fix tech-debt items closed.** The canonical-import search-index race (now a
  deterministic node lookup with search as fallback) and the `vso:evidenceReviewStatus`
  false-enforcement-gate doc claim are both fixed; `API_KEY`-off-by-default is covered by W2.
  The remaining eight items from the internal technical-debt registry ship as documented known
  limitations, not blockers — most consequentially, **P3 production-hardening is at 0%** (no
  Vault, Keycloak, observability, or replication), which is stated prominently in both the
  adopter doc and the production-configuration doc's own banner.
- [ ] **(W8) AtroCore decommissioning path** — explicitly **post-release**, not a gate on this
  launch. Direction agreed (Postgres + a custom lightweight admin UI + endpoints implemented
  directly for what Node-RED needs, migrated incrementally entity-by-entity, leaning on
  Node-RED's role as the integration hub to keep the swap low-disruption for
  `compliance_web`/`compliance_checklist`), but no implementation work has started.

## What's actually blocking a public release today

One thing, requiring action from the project owner rather than more unilateral engineering
work:

1. **Commission the legal review (W1)** — the hard gate. Everything else is ready or
   in progress, and this still has to close first.

Everything else on this list that's marked open (W5) is downstream of that gate, or
deliberately scoped out of this release (W8).

# Contributing Guide

Thank you for your interest in contributing to the **Compliance Platform** umbrella
repository. This repository holds cross-cutting, adopter-facing documentation for the whole
platform — it contains no code. If your change is about a specific component's behavior
(Node-RED flows, the Alfresco content model, the Electron app, etc.), it belongs in that
component's own repository instead; see the table in [README.md](README.md).

Please read [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) before participating.

---

## 1. Branch workflow

This repository follows the same **main / develop** model as every other repository in this
platform:

- `main` — stable.
- `develop` — active integration branch. **All merge requests target `develop`** unless
  maintainers specify otherwise.
- `feature/*` — new content or restructuring, for example `feature/add-faq-section`.
- `fix/*` — corrections, for example `fix/broken-adaptation-guide-link`.
- `hotfix/*` — urgent fixes to `main`.

```bash
git checkout develop
git pull
git checkout -b feature/awesome-improvement
git add .
git commit -m "docs: add awesome improvement"
git push origin feature/awesome-improvement
```

Then open a merge request targeting `develop`. Never commit directly to `develop` or `main`.

---

## 2. Commit convention

Use [Conventional Commits](https://www.conventionalcommits.org/). For a docs-only repository
this is almost always `docs:`, occasionally `fix:` (correcting something wrong) or `chore:`
(repo maintenance).

---

## 3. What belongs here vs. in a component repository

- **Here**: the adopter-facing front door (`README.md`, `GETTING_STARTED_FOR_ADOPTERS.md`),
  the country-adaptation guide, the release-readiness checklist, the production-architecture
  roadmap, cross-cutting technical reference (`CLAUDE.md`), and capacity-planning content.
- **In the relevant component repository**: anything about that component's own code,
  configuration, API contract, or tests — including that component's own README and
  `CONTRIBUTING.md`.
- When a change spans this repository and one or more component repositories, open a
  separate merge request in each and link them to each other.

---

## 4. Merge request checklist

- **Summary** — what changed and why.
- **Scope** — which documents are affected.
- Cross-check any file paths, links, or claims about component-repo behavior you're adding
  or changing — this repository has no CI today to catch drift automatically.

---

## 5. Licensing

This repository is licensed under the **Apache License 2.0** — see [LICENSE](LICENSE) and
[NOTICE](NOTICE). It contains only original documentation; it does not bundle or relicense
any component repository's code or third-party dependencies.

---

## 6. Reporting issues

For large or cross-cutting documentation restructuring, open an issue first to align on
scope before implementing. For a bug or gap in a specific component's behavior, file the
issue in that component's own repository instead.

**Response-time expectations.** This platform has a small maintainer team; there is no
guaranteed response time or SLA on issues or merge requests. Expect a best-effort response,
typically within a couple of weeks — sooner for security-relevant reports. If something
looks urgent (a security issue, a broken demo path, a licensing concern), say so explicitly
in the issue title so it doesn't get lost in a general backlog.

# Workflow Market — curation, sharing, and the community model

How the market is organized, how workflows are exchanged today, and the staged
plan for a community catalog. Decisions here came out of a design review
(reader-experience / information-architecture / security perspectives) and err
on the side of honesty: nothing in this file pretends a backend exists.

## Shelves (Phase 1, bundled)

Five functional categories, ordered by user value (`WorkflowMarketCategory`):

| id | name | what belongs here |
|---|---|---|
| `daily` | 定时情报 · Daily digests | built to run on a schedule: 论文晨报, Repo 晨报, Git 周报 |
| `review` | 代码评审 · Code review | read-only quality passes: uncommitted review, deep audit, biggest-risk |
| `fix` | 修复与构建 · Fix & build | changes files, gated by `verify`: fix failing tests, review→fix |
| `research` | 研究与写作 · Research | onboarding, arXiv mini-survey |
| `demo` | 入门演示 · Learn Pervio | each teaches ONE mechanic (fan-out, verify gate) |

Curation rules: an item must either be runnable with zero setup or carry loud
`〈改成你的:…〉` placeholders that fail VISIBLY when forgotten (a scheduled
template must never fail silently at 6am). Every scheduled template needs an
explicit empty-state path. Section order inside a shelf = editorial order in
the `featured` array — curation is the ranking; there are no scores.

## Exchange format (today)

One workflow = one JSON: the whole `WorkflowMarketItem` (title/summary/author/
tags/category/version + spec). On export the spec's `dir` is reset to `"~"`
(no local paths leak; the importer's project dir is substituted on use) and
absolute per-step dir overrides are dropped (`~`-relative state dirs like the
paper digest's are kept).

- **Export**: editor toolbar ⋯ → "Copy spec JSON"; a run's context menu in the
  workflow list; a market item's detail page.
- **Import**: Market → Import JSON → paste → structural validation → the SAME
  detail page as bundled items. The warnings engine runs locally on the pasted
  spec (never trusted from the file), bypass/full-access items additionally
  require an explicit "I've read every step" toggle, and nothing ever runs
  automatically — Use only prefills the editor.

## Phase 2 — remote catalog (not built; prerequisites below)

- A public repo (`pervio-workflows`) whose `index.json` is `[WorkflowMarketItem]`
  — the model is already `Codable` for this; zero app-model changes.
- The app fetches over HTTPS with ETag caching and falls back to the bundled
  catalog on failure.
- **Submission** = a PR adding `workflows/<id>.json`. CI checks schema, rejects
  `{{` inside `command`/`verify` (refs are never substituted there — a template
  relying on that is broken by design), and regenerates a risk table in the
  README using the same warnings derivation the app uses. **A maintainer's
  human review before merge is the only real quality and security gate** — CI
  catches format, not malicious prompts. Single-maintainer review is the
  throughput ceiling; that's accepted, not worked around.
- **Updates**: `version: Int` per item. Remote version > imported version →
  an "update available" badge → the user views a plain-text diff of the spec
  and applies it manually. Never silently auto-update: a workflow is executable
  instructions, and auto-updating those is a supply-chain attack surface.

### Ratings: deferred, deliberately

With no backend and no identity, any anonymous counter is trivially gameable
and the sample size would be single digits — fake scores destroy trust faster
than no scores. Decision:

1. Now: nothing. Ranking is editorial (array order).
2. Later (catalog > ~30 items with outside submitters): optionally display the
   GitHub 👍 reactions of each item's submission PR — read-only, cached,
   clearly labeled with its source, and **never used for sorting**.
3. A real rating system waits for a real backend, if ever.

### Phase 2 launch prerequisites (all four, or it doesn't ship)

1. Warnings are always computed locally from the spec; any risk field the
   remote index self-reports is ignored.
2. Remote items only prefill the editor; the detail page has no run entry.
3. The detail page shows author, source URL, and the catalog commit hash
   (traceable to the PR that introduced the item).
4. The app pulls only the fixed official repo — no third-party catalog URLs.

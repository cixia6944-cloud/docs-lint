[中文](README.md)

# docs-lint

`docs-lint` generates a fact pack for reviewer agents. The script checks structure, evidence, and maintainability; your agent decides what is useful.

It works with any Markdown library maintained over time. Rules are configuration-driven and are not tied to one repository layout.

## Five-Minute Start

```powershell
git clone https://github.com/cixia6944-cloud/docs-lint
cd docs-lint
cp docs-lint.config.example.json docs-lint.config.json
pwsh tools/audit-docs.ps1 -Repo ../your-project -Config docs-lint.config.json -FactPack facts.json
```

Replace `../your-project` with the path to the repository you want to audit.

`facts.json` is not meant to be read by a human — hand it, together with the project, to your reviewer agent.

Messages in the fact pack are currently emitted in Chinese.

This is a trimmed sample from a real run:

```json
{ "coverage": { "files_total": 10, "files_scanned": 10, "lines_scanned": 468, "categories": { "docs": 10 } },
  "findings": [ { "id": "7b42145551a8", "kind": "fact", "rule": "encoding-suspect", "severity": "error", "category": "docs", "file": "fixtures/bad/encoding-suspect.md", "line": 0, "message": "文件不是严格 UTF-8", "detail": "疑似其他编码；先转成 UTF-8，再让工具检查内容，避免乱码被静默当成合规", "fix": "把文件转成严格 UTF-8 后重新检查", "verify": null } ] }
```

- Use `-Baseline` with a previous `facts.json` to report added and fixed `findings`. For an existing repository, save a baseline first, then use `-FailOnNew` to block only new problems.
- `blockOn` defaults to `fact`: only fact errors block the run. Heuristic errors become warnings and remain in the fact pack for agent review.
- `datePolicy: sourced` is the strict mode: dates need contextual evidence. Start other projects with `free`, then tighten after reviewing the fact pack.

## Tools

### Audit Documentation

```powershell
pwsh -NoProfile -File tools/audit-docs.ps1 -Repo .
pwsh -NoProfile -File tools/audit-docs.ps1 -Repo . -Json
pwsh -NoProfile -File tools/audit-docs.ps1 -Repo . -Config path/to/config.json
```

The audit classifies Markdown files, then applies these rules:

1. Category matching by path glob.
2. Bad-word checks from `audit/rules.json`.
3. Date-source checks for `datePolicy: sourced`.
4. Evidence, TODO, and stale-reference checks.
5. Untracked Markdown checks.

`-FactPack` writes stable, diffable JSON containing `coverage`, `findings`, and `totals`. Repeated identical findings receive `-2`, `-3` suffixes, and insertion of lines does not change existing ids.

### Check Secrets

```powershell
pwsh -NoProfile -File tools/check-secrets.ps1 -Repo .
pwsh -NoProfile -File tools/check-secrets.ps1 -Staged
pwsh -NoProfile -File tools/check-secrets.ps1 -Exclude 'docs/security.md','fixtures/*'
```

The secret scan reports rule, file, and line only. It never prints the matching secret. It is a report, not a commit blocker.

### Run Self-Tests

```powershell
pwsh -NoProfile -File tools/selftest.ps1
```

The self-test builds temporary good and bad repositories and verifies that both passes and failures are reported correctly.

## Configuration

Use `docs-lint.config.json` at the repository root, or pass another file with `-Config`:

```json
{
  "categories": [
    { "name": "history", "match": ["history/*", "*/history/*"], "datePolicy": "free" },
    { "name": "current", "match": ["*"], "datePolicy": "sourced", "checkBadWords": true }
  ],
  "dateStyle": "warn",
  "blockOn": "fact",
  "untracked": "warn",
  "rulesFile": "audit/rules.json"
}
```

Categories are evaluated in order; the first match wins. Put the `*` catch-all last.

| Category field | Purpose |
|---|---|
| `name` | Category name used in `coverage` and `findings`. |
| `match` | PowerShell-style path globs using `/`. |
| `datePolicy` | `sourced`, `free`, or `ignore`. |
| `checkBadWords` | Enables regular-expression bad-word checks. |
| `warnIfNoDate` | Warns when a category has no dates. |
| `warnIfDateDense` | Warns when date count reaches `dateCap`. |

Use `datePolicy: free` for logs, archives, and new projects. Use `sourced` when a date must have contextual evidence. Use `ignore` for fixtures and meta-documents.

`dateStyle` controls suspicious date formats in `sourced` categories: `off`, `warn` (default), or `error`.

| Rule | Type | Default behavior |
|---|---|---|
| `claim-unsupported` | heuristic | Warns when completion language lacks an evidence anchor. |
| `todo-residue` | fact | Reports TODO markers left in prose. |
| `stale-reference` | fact | Reports missing files or out-of-range line references. |
| `badword` | heuristic | Reports configured narrative words. |
| `date-nosource` / `date-style` / `date-density` | heuristic | Reports date-source, format, and density risks. |
| `untracked` / `no-category` / `missing-on-disk` / `encoding-suspect` | fact | Reports repository and encoding failures. |

## Exit Codes

| Tool | 0 | 1 | 2 |
|---|---|---|---|
| `audit-docs.ps1` | Clean | Finding or invalid configuration | Environment failure |
| `check-secrets.ps1` | No suspected secret | Suspected secret or invalid configuration | Environment failure |
| `selftest.ps1` | All checks passed | Failed check | Environment failure |

## Requirements

- Windows PowerShell 7 (`pwsh`) is recommended.
- Git must be installed and the target must be a Git repository.
- No PowerShell modules are required.

Use `pwsh -NoProfile` for stable behavior. Keep scripts encoded as UTF-8 with BOM if Windows PowerShell 5.1 must be used.

## Design

The tool refuses to fall back silently. Missing configuration, empty rule lists, invalid regular expressions, and unmatched files fail loudly instead of producing a false green result.

Known limits: date checks are heuristics, category matching is path-based, only Markdown is audited, and the secret scan is regex-based. The tool reports findings; it does not rewrite files.

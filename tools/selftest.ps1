#Requires -Version 5.1
<#
.SYNOPSIS
    工具自测：喂一份干净样例和一份全是坑的样例，证明检查器会放行、也会拦。

.DESCRIPTION
    为什么要有这个：检查器改坏了，唯一的表现往往是「一直打 OK」——没人会立刻发现。
    这个脚本在 %TEMP% 下造一次性样例库，跑完删掉，不碰真实文档：

      1) 干净样例必须 exit 0
      2) 坏样例必须 exit 1，并且命中预期的那几条（违规词、无来源日期、date-style、encoding-suspect、未跟踪 .md）
      3) 配置/词表缺失、解析失败、为空、正则非法、没有匹配分类，都必须 exit 1，
         不允许静默退回内置规则
      4) check-secrets 必须能扫到中文文件名，且不把命中的原文打印出来
      5) tools/ 下所有 .ps1 必须是 UTF-8 with BOM

.PARAMETER KeepFixture
    跑完不删样例目录。只在自测报错、需要看现场时用。

.EXAMPLE
    pwsh -NoProfile -File tools/selftest.ps1
    pwsh -NoProfile -File tools/selftest.ps1 -KeepFixture

.NOTES
    退出码：0 全过；1 有失败项；2 环境问题（找不到 pwsh / git）。
#>
[CmdletBinding()]
param([switch]$KeepFixture)

$ErrorActionPreference = 'Stop'

try {
    if ([Console]::IsOutputRedirected) {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
} catch { }

$toolsDir = $PSScriptRoot
$repo = Split-Path -Parent $toolsDir

$psExe = $null
if (Get-Command pwsh -ErrorAction SilentlyContinue) { $psExe = 'pwsh' }
elseif (Get-Command powershell -ErrorAction SilentlyContinue) { $psExe = 'powershell' }
if (-not $psExe) { Write-Host "找不到 pwsh / powershell，自测跑不了。" -ForegroundColor Red; exit 2 }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Host "找不到 git，自测跑不了。" -ForegroundColor Red; exit 2 }

$script:passCount = 0
$script:failures = New-Object System.Collections.ArrayList

function Check([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) {
        $script:passCount++
        Write-Host ("  [√] {0}" -f $name) -ForegroundColor Green
    } else {
        [void]$script:failures.Add($name)
        Write-Host ("  [×] {0}" -f $name) -ForegroundColor Red
        if ($detail) { Write-Host ("      {0}" -f ($detail -replace "`r?`n", ' | ')) -ForegroundColor DarkGray }
    }
}

function Invoke-Native {
    param([string]$File, [string[]]$ArgList, [string]$WorkDir)
    $old = $ErrorActionPreference
    $oldEnc = try { [Console]::OutputEncoding } catch { $null }
    $ErrorActionPreference = 'Continue'
    try {
        if ($WorkDir) { Push-Location $WorkDir }
        try {
            try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
            $out = & $File @ArgList 2>&1
        } finally { if ($WorkDir) { Pop-Location } }
        [pscustomobject]@{
            Code = $LASTEXITCODE
            Text = ((@($out) | ForEach-Object { "$_" }) -join "`n")
        }
    } finally {
        if ($oldEnc) { try { [Console]::OutputEncoding = $oldEnc } catch { } }
        $ErrorActionPreference = $old
    }
}

function Invoke-Tool {
    param([string[]]$ArgList)
    Invoke-Native -File $psExe -ArgList (@('-NoProfile', '-File') + $ArgList)
}

function Invoke-Git {
    param([string]$WorkDir, [string[]]$ArgList)
    Invoke-Native -File 'git' -ArgList $ArgList -WorkDir $WorkDir
}

function Set-FixtureFile {
    param([string]$Root, [string]$Rel, [string]$Text)
    $full = Join-Path $Root $Rel
    $dir = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($full, $Text, (New-Object Text.UTF8Encoding $false))
}

function Write-JsonFile {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

function Write-Utf16Fixture {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.Encoding]::Unicode)
}

function Write-GbkFixture {
    param([string]$Path, [string]$Text)
    try {
        $encoding = [Text.Encoding]::GetEncoding(936)
        [IO.File]::WriteAllText($Path, $Text, $encoding)
    } catch {
        throw "当前 .NET 运行时没有注册 GB18030（codepage 936）：$($_.Exception.Message)"
    }
}

function New-FixtureRepo {
    param([string]$Root, [string]$Name)
    $p = Join-Path $Root $Name
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    Invoke-Git $p @('init', '-q') | Out-Null
    Invoke-Git $p @('config', 'user.email', 'selftest@example.invalid') | Out-Null
    Invoke-Git $p @('config', 'user.name', 'docs-lint selftest') | Out-Null
    Invoke-Git $p @('config', 'core.quotepath', 'false') | Out-Null
    Invoke-Git $p @('config', 'core.autocrlf', 'false') | Out-Null
    Invoke-Git $p @('config', 'core.excludesFile', $emptyGitExclude) | Out-Null
    return $p
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('docs-lint-selftest-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$emptyGitConfig = Join-Path $root 'empty-git-config'
$emptyGitExclude = Join-Path $root 'empty-git-exclude'
[IO.File]::WriteAllText($emptyGitConfig, '', (New-Object Text.UTF8Encoding $false))
[IO.File]::WriteAllText($emptyGitExclude, '', (New-Object Text.UTF8Encoding $false))
$oldGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
$env:GIT_CONFIG_GLOBAL = $emptyGitConfig
Write-Host ""
Write-Host "  样例目录：$root" -ForegroundColor DarkGray

$audit = Join-Path $toolsDir 'audit-docs.ps1'
$config = Join-Path $repo 'docs-lint.config.json'
$rules = Join-Path $repo 'audit/rules.json'

try {
    # ── 样例一：干净的库 ───────────────────────────────────────────
    $good = New-FixtureRepo $root 'good'
    Set-FixtureFile $good 'README.md' @'
# Sample library

- [Guide](guide.md)
- [History](history/2026-01-01-example.md)
'@
    Set-FixtureFile $good 'guide.md' @'
# Guide

> Updated: 2026-01-01

This behavior was verified on 2026-01-02.

| Check | Result |
|---|---|
| table dates are allowed | 2026-01-03 |
'@
    Set-FixtureFile $good 'history/2026-01-01-example.md' @'
# 2026-01-01 example

History notes may carry dates without further context.
'@
    Invoke-Git $good @('add', '-A') | Out-Null

    # ── 样例二：每个坑各一个文件 ───────────────────────────────────
    $bad = New-FixtureRepo $root 'bad'
    Set-FixtureFile $bad 'README.md' @'
# Bad sample

- [Guide](guide.md)
'@
    Set-FixtureFile $bad 'guide.md' @'
# Guide

2026-11-18 实测通过
2026-12-01 实测通过
2026-01-05 实测通过
2026年3月5日 实测通过

这一行故意写历史叙述词：曾经是这样的。

这一句故意带一个没有来源的日期：2026-03-05 改了配置。

| Item | Note |
|---|---|
| table dates are allowed | 2026-03-06 |
'@
    Set-FixtureFile $bad 'history/undated-note.md' @'
# Undated note

This history file has no date at all.
'@
    Set-FixtureFile $bad 'history/slash-date.md' @'
# Log excerpt

2026/10/30 从日志里抄来的记录。
'@
    Set-FixtureFile $bad 'date-style.md' @'
# Date style

已修复，但没有任何证据。

The current guide was verified on 03/05/2026.

2026/03/05 是无来源且写法不规范的日期。

行内代码里的 `2026/03/05` 不判。

```text
围栏里的 2026/03/05 不判。
```

~~~text
波浪围栏里的 2026/03/05 不判。
~~~
'@
    Set-FixtureFile $bad 'todo-residue.md' @'
# TODO residue

这段内容待补。
'@
    Set-FixtureFile $bad 'TODO.md' @'
# TODO

这里允许写：待补。
'@
    Set-FixtureFile $bad 'vps/README.md' @'
# VPS

Reference target.
'@
    Set-FixtureFile $bad 'stale-reference.md' @'
# Stale reference

引用了不存在的 vps/不存在.md。
真实的 vps/README.md:1。
vps/README.md:99999 行号越界。
跳过 https://example.com/vps/不存在.md 和 C:/tmp/不存在.md。
`<vps/不存在.md>` 是占位符。
'@
    Set-FixtureFile $bad 'claim-evidence.md' @'
# Evidence

迁移已完成。
这一节待补。
已修复：git log 里的 0123456789abcdef。
已修复：https://example.com/deploy-log
已修复：guide.md:3
已修复，下面是命令输出：
```text
ok
done
```
'@
    $encodingFile = Join-Path $bad 'encoding-suspect.md'
    Write-Utf16Fixture $encodingFile "This file is intentionally not UTF-8.`n"
    Set-FixtureFile $bad 'draft-untracked.md' @'
# Draft

这篇故意不 git add：内容里也写了一个曾经。
'@
    Invoke-Git $bad @('add', '-A') | Out-Null
    Invoke-Git $bad @('rm', '--cached', '-q', '--', 'draft-untracked.md') | Out-Null

    # ── 1) 干净样例必须放行 ───────────────────────────────────────
    Write-Host "`n  ── 干净样例（必须 exit 0，证明工具不是永远报错）──" -ForegroundColor Cyan
    $r = Invoke-Tool @($audit, '-Repo', $good, '-Config', $config)
    Check 'audit-docs：干净样例 exit 0' ($r.Code -eq 0) ("exit=$($r.Code) " + $r.Text)
    Check 'audit-docs：干净样例没有报违规' ($r.Text -match 'OK  分类与日期规则均合规') $r.Text

    # ── 2) 坏样例必须逐条报出来 ───────────────────────────────────
    Write-Host "`n  ── 坏样例（必须 exit 1，且命中预期的几条）──" -ForegroundColor Cyan
    $r = Invoke-Tool @($audit, '-Repo', $bad, '-Config', $config)
    Check 'audit-docs：坏样例 exit 1' ($r.Code -eq 1) ("exit=$($r.Code) " + $r.Text)
    Check 'audit-docs：报出违规词' ($r.Text -match '曾经') $r.Text
    Check 'audit-docs：报出无来源日期' ($r.Text -match '无来源的日期') $r.Text
    Check 'audit-docs：报出不支持的日期格式' ($r.Text -match 'date-style') $r.Text
    Check 'audit-docs：10-12 月规范日期不误报' ($r.Text -notmatch '2026-11-18|2026-12-01') $r.Text
    Check 'audit-docs：2026年3月5日不报' ($r.Text -notmatch '2026年3月5日') $r.Text
    Check 'audit-docs：date-style 给出可执行改写' ($r.Text -match '03/05/2026 → 2026-03-05') $r.Text
    Check 'audit-docs：行内代码与围栏里的可疑日期不报' ($r.Text -notmatch '行内代码里的|围栏里的') $r.Text
    Check 'audit-docs：波浪围栏里的可疑日期不报' ($r.Text -notmatch '波浪围栏里的') $r.Text
    Check 'audit-docs：free 分类里的斜杠日期不报' ($r.Text -notmatch '2026/10/30') $r.Text
    Check 'audit-docs：报出编码可疑的文件' ($r.Text -match 'encoding-suspect') $r.Text
    Check 'audit-docs：编码可疑文件不再当内容检查' ($r.Text -notmatch 'intentionally not UTF-8') $r.Text
    Check 'audit-docs：报出未跟踪的 .md' ($r.Text -match '未跟踪的 \.md') $r.Text
    Check 'audit-docs：未跟踪文件的内容也扫了' ($r.Text -match 'draft-untracked\.md') $r.Text
    Check 'audit-docs：历史缺日期给了提示' ($r.Text -match '没有任何日期') $r.Text
    Check 'audit-docs：表格里的日期没有误报' ($r.Text -notmatch 'table dates are allowed') $r.Text
    Check 'audit-docs：报出无证据的完成性表述' ($r.Text -match '这条声称「已修复」') $r.Text
    Check 'audit-docs：中文行文里的完成性表述也报' ($r.Text -match '这条声称「已修复」') $r.Text
    Check 'audit-docs：报出正文待办残留' ($r.Text -match 'todo-residue') $r.Text
    Check 'audit-docs：中文行文里的待办也报' ($r.Text -match '「待补」仍留在正文') $r.Text
    Check 'audit-docs：TODO.md 允许待办' ($r.Text -notmatch 'TODO\.md .*待补') $r.Text
    Check 'audit-docs：报出不存在的文件引用' ($r.Text -match 'vps/不存在\.md') $r.Text
    Check 'audit-docs：真实文件引用不报' ($r.Text -notmatch 'vps/README\.md:1') $r.Text
    Check 'audit-docs：报出引用行号越界' ($r.Text -match 'vps/README\.md:99999') $r.Text
    Check 'audit-docs：URL、绝对路径和占位符引用不报' ($r.Text -notmatch 'https://example\.com|C:/tmp|是占位符') $r.Text
    Check 'audit-docs：有证据的完成性表述不报' ($r.Text -notmatch 'git log 里的|deploy-log|guide\.md:3|下面是命令输出') $r.Text

    # ── 3) 配置/词表坏了必须 exit 1，不许假绿 ─────────────────────
    Write-Host "`n  ── 配置与判据失败（必须 exit 1，不许退回内置规则）──" -ForegroundColor Cyan

    $missingCfg = Join-Path $root 'missing-config.json'
    $r = Invoke-Tool @($audit, '-Repo', $good, '-Config', $missingCfg)
    Check '配置缺失 → exit 1' ($r.Code -eq 1 -and $r.Text -match '找不到配置文件') ("exit=$($r.Code) " + $r.Text)

    $brokenCfg = Join-Path $root 'broken-config.json'
    Write-JsonFile $brokenCfg '{ "categories": ['
    $r = Invoke-Tool @($audit, '-Repo', $good, '-Config', $brokenCfg)
    Check '配置解析失败 → exit 1' ($r.Code -eq 1 -and $r.Text -match '解析失败') ("exit=$($r.Code) " + $r.Text)

    $emptyRules = Join-Path $root 'empty-rules.json'
    Write-JsonFile $emptyRules '{"badWords":[]}'
    $r = Invoke-Tool @($audit, '-Repo', $good, '-Config', $config, '-Rules', $emptyRules)
    Check '词表为空 → exit 1' ($r.Code -eq 1 -and $r.Text -match 'badWords 是空的') ("exit=$($r.Code) " + $r.Text)

    $missingRules = Join-Path $root 'missing-rules.json'
    $r = Invoke-Tool @($audit, '-Repo', $good, '-Config', $config, '-Rules', $missingRules)
    Check '词表缺失 → exit 1' ($r.Code -eq 1 -and $r.Text -match '找不到规则文件') ("exit=$($r.Code) " + $r.Text)

    $badRegexRules = Join-Path $root 'bad-regex-rules.json'
    Write-JsonFile $badRegexRules '{"badWords":["("]}'
    $r = Invoke-Tool @($audit, '-Repo', $good, '-Config', $config, '-Rules', $badRegexRules)
    Check '词表正则非法 → exit 1' ($r.Code -eq 1 -and $r.Text -match '非法正则') ("exit=$($r.Code) " + $r.Text)

    $noCat = Join-Path $root 'no-category-config.json'
    Write-JsonFile $noCat '{"categories":[{"name":"history","match":["history/*"],"datePolicy":"free"}],"untracked":"ignore"}'
    $r = Invoke-Tool @($audit, '-Repo', $good, '-Config', $noCat, '-Rules', $rules)
    Check '没有匹配分类 → exit 1（不静默跳过）' ($r.Code -eq 1 -and $r.Text -match '没有匹配的分类') ("exit=$($r.Code) " + $r.Text)

    $dateStyleWarn = Join-Path $root 'date-style-warn.json'
    $dateStyleRepo = New-FixtureRepo $root 'date-style-only'
    Set-FixtureFile $dateStyleRepo 'date-style.md' "2026/03/05 实测通过`n"
    Invoke-Git $dateStyleRepo @('add', '-A') | Out-Null
    $configText = [IO.File]::ReadAllText($config, [Text.Encoding]::UTF8) -replace '"dateStyle"\s*:\s*"(?:off|warn|error)"', '"dateStyle":"warn"'
    $configText = $configText -replace '"rulesFile"\s*:\s*"audit/rules.json"', ('"rulesFile":"{0}"' -f ($rules -replace '\\', '\\'))
    Write-JsonFile $dateStyleWarn $configText
    $r = Invoke-Tool @($audit, '-Repo', $dateStyleRepo, '-Config', $dateStyleWarn)
    Check 'dateStyle=warn：可疑日期只提示且 exit 0' ($r.Code -eq 0 -and $r.Text -match '2026/03/05 → 2026-03-05') ("exit=$($r.Code) " + $r.Text)

    $dateStyleError = Join-Path $root 'date-style-error.json'
    $configText = [IO.File]::ReadAllText($config, [Text.Encoding]::UTF8) -replace '"dateStyle"\s*:\s*"(?:off|warn|error)"', '"dateStyle":"error"'
    $configText = $configText -replace '"rulesFile"\s*:\s*"audit/rules.json"', ('"rulesFile":"{0}"' -f ($rules -replace '\\', '\\'))
    Write-JsonFile $dateStyleError $configText
    $r = Invoke-Tool @($audit, '-Repo', $dateStyleRepo, '-Config', $dateStyleError, '-Json')
    Check 'dateStyle=error：可疑日期进 issues 并阻断' ($r.Code -eq 1 -and $r.Text -match '"rule":"date-style"' -and $r.Text -match '"ok":false') $r.Text

    # ── 4) -Json 结构 ────────────────────────────────────────────
    Write-Host "`n  ── JSON 输出 ──" -ForegroundColor Cyan
    $r = Invoke-Tool @($audit, '-Repo', $bad, '-Config', $config, '-Json')
    $lines = @($r.Text -split "`r?`n" | Where-Object { $_ })
    Check 'audit-docs：-Json 只输出一行' ($lines.Count -eq 1) ("行数=$($lines.Count) " + $r.Text)
    $obj = $null
    try { $obj = $lines[0] | ConvertFrom-Json } catch { }
    Check 'audit-docs：-Json 可解析' ($null -ne $obj) $r.Text
    Check 'audit-docs：-Json 的 ok/exit_code 与进程退出码自洽' ([bool]($obj -and (-not $obj.ok) -and $obj.exit_code -eq 1 -and $r.Code -eq 1)) $r.Text
    Check 'audit-docs：-Json 里带 issues 明细' ([bool]($obj -and @($obj.issues).Count -ge 3)) $r.Text

    # ── 4b) FactPack：稳定性 / id / 基线 / blockOn ─────────────────
    Write-Host "`n  ── FactPack ──" -ForegroundColor Cyan
    $fact1 = Join-Path $root 'facts-1.json'
    $fact2 = Join-Path $root 'facts-2.json'
    $r1 = Invoke-Tool @($audit, '-Repo', $bad, '-Config', $config, '-FactPack', $fact1)
    $r2 = Invoke-Tool @($audit, '-Repo', $bad, '-Config', $config, '-FactPack', $fact2)
    $hash1 = (Get-FileHash -LiteralPath $fact1 -Algorithm SHA256).Hash
    $hash2 = (Get-FileHash -LiteralPath $fact2 -Algorithm SHA256).Hash
    Check 'FactPack：同一仓库两次输出逐字节一致' ($r1.Code -eq $r2.Code -and $hash1 -eq $hash2) "$($r1.Code)/$($r2.Code) $hash1 $hash2"
    $facts = $null
    try { $facts = Get-Content -LiteralPath $fact1 -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    Check 'FactPack：schema_version=1 且 findings 排序稳定' ([bool]($facts -and $facts.schema_version -eq 1 -and $facts.tool -eq 'audit-docs')) $r1.Text
    Check 'FactPack：没有时间戳或耗时字段' ((Get-Content -LiteralPath $fact1 -Raw -Encoding UTF8) -notmatch 'generated_at|elapsed|duration') $fact1
    Check 'FactPack：coverage 与 totals 齐全' ([bool]($facts -and $facts.coverage.files_total -gt 0 -and $facts.coverage.lines_scanned -gt 0 -and $null -ne $facts.totals.by_severity.error)) $fact1

    $baseline1 = Join-Path $root 'baseline-1.json'
    $baseline2 = Join-Path $root 'baseline-2.json'
    Set-FixtureFile $bad 'baseline-new.md' "# Baseline`n`n这一句带一个没有来源的日期：2026-03-05。`n"
    Invoke-Git $bad @('add', '--', 'baseline-new.md') | Out-Null
    $rNew = Invoke-Tool @($audit, '-Repo', $bad, '-Config', $config, '-FactPack', $baseline1, '-Baseline', $fact1)
    $newObj = $null
    try { $newObj = Get-Content -LiteralPath $baseline1 -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    Check 'Baseline：新增 finding 正好 1 个' ($newObj -and $newObj.baseline.added.Count -eq 1) $baseline1

    Remove-Item -LiteralPath (Join-Path $bad 'baseline-new.md') -Force
    Invoke-Git $bad @('rm', '--cached', '-q', '--', 'baseline-new.md') | Out-Null
    $rFixed = Invoke-Tool @($audit, '-Repo', $bad, '-Config', $config, '-FactPack', $baseline2, '-Baseline', $baseline1)
    $fixedObj = $null
    try { $fixedObj = Get-Content -LiteralPath $baseline2 -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    Check 'Baseline：修复 finding 正好是刚才那条' ($fixedObj -and $fixedObj.baseline.fixed.Count -eq 1 -and $fixedObj.baseline.fixed[0] -eq $newObj.baseline.added[0]) $baseline2
    Check 'Baseline：现存数量与当前 findings 一致' ($fixedObj -and $fixedObj.baseline.remaining -eq @($fixedObj.findings).Count) $baseline2

    $blockFact = Join-Path $root 'block-fact.json'
    $blockAll = Join-Path $root 'block-all.json'
    $configText = [IO.File]::ReadAllText($config, [Text.Encoding]::UTF8) -replace '"blockOn"\s*:\s*"all"', '"blockOn":"fact"'
    $configText = $configText -replace '"rulesFile"\s*:\s*"audit/rules.json"', ('"rulesFile":"{0}"' -f ($rules -replace '\\', '\\'))
    Write-JsonFile $blockFact $configText
    $rFact = Invoke-Tool @($audit, '-Repo', $dateStyleRepo, '-Config', $blockFact, '-FactPack', (Join-Path $root 'block-fact-pack.json'))
    $factObj = $null
    try { $factObj = Get-Content -LiteralPath (Join-Path $root 'block-fact-pack.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    Check 'blockOn=fact：heuristic error 降级 warn 且 exit 0' ($rFact.Code -eq 0 -and $factObj -and @($factObj.findings | Where-Object { $_.kind -eq 'heuristic' -and $_.severity -eq 'warn' }).Count -gt 0) $rFact.Text
    $rJsonFact = Invoke-Tool @($audit, '-Repo', $dateStyleRepo, '-Config', $blockFact, '-Json')
    $jsonFact = $null
    try { $jsonFact = $rJsonFact.Text | ConvertFrom-Json } catch { }
    Check 'blockOn=fact：-Json 的 ok/exit/进程码一致为通过' ($rJsonFact.Code -eq 0 -and $jsonFact.ok -eq $true -and $jsonFact.exit_code -eq 0) $rJsonFact.Text
    $rAll = Invoke-Tool @($audit, '-Repo', $bad, '-Config', $config)
    Check 'blockOn=all：heuristic error 维持阻断' ($rAll.Code -eq 1) ("exit=$($rAll.Code) " + $rAll.Text)
    $configText = [IO.File]::ReadAllText($config, [Text.Encoding]::UTF8) -replace '"dateStyle"\s*:\s*"(?:off|warn|error)"', '"dateStyle":"error"'
    $configText = $configText -replace '"rulesFile"\s*:\s*"audit/rules.json"', ('"rulesFile":"{0}"' -f ($rules -replace '\\', '\\'))
    Write-JsonFile $blockAll $configText
    $rJsonAll = Invoke-Tool @($audit, '-Repo', $dateStyleRepo, '-Config', $blockAll, '-Json')
    $jsonAll = $null
    try { $jsonAll = $rJsonAll.Text | ConvertFrom-Json } catch { }
    Check 'blockOn=all：-Json 的 ok/exit/进程码一致为失败' ($rJsonAll.Code -eq 1 -and $jsonAll.ok -eq $false -and $jsonAll.exit_code -eq 1) $rJsonAll.Text

    $bPack = Join-Path $root 'rules-pack.json'
    $rB = Invoke-Tool @($audit, '-Repo', $bad, '-Config', $config, '-FactPack', $bPack)
    $bObj = $null
    try { $bObj = Get-Content -LiteralPath $bPack -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    $rulesRunText = @($bObj.coverage.rules_run) -join ','
    Check 'FactPack：三条新规则进入 rules_run' ($rulesRunText -match '(^|,)claim-unsupported(,|$)' -and $rulesRunText -match '(^|,)todo-residue(,|$)' -and $rulesRunText -match '(^|,)stale-reference(,|$)') $bPack
    Check 'FactPack：新规则有可执行 verify 和具体 fix' (@($bObj.findings | Where-Object { $_.rule -in @('claim-unsupported', 'todo-residue', 'stale-reference') -and ($_.verify -or $_.fix) }).Count -ge 3) $bPack

    # ── 5) check-secrets：中文名、值不外泄、-Staged、-Exclude ──────
    Write-Host "`n  ── check-secrets（编码 / 输出 / 范围）──" -ForegroundColor Cyan
    $sec = New-FixtureRepo $root 'secrets'
    New-Item -ItemType Directory -Force -Path (Join-Path $sec 'tools') | Out-Null
    Copy-Item (Join-Path $toolsDir 'check-secrets.ps1') (Join-Path $sec 'tools') -Force
    $secTool = Join-Path $sec 'tools/check-secrets.ps1'

    $fakePrivate = 'fake' + [guid]::NewGuid().ToString('N').Substring(0, 16)
    $fakeLabeled = 'Fake' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '7a'
    $fakeToken = 'fake' + [guid]::NewGuid().ToString('N').Substring(0, 16)
    Set-FixtureFile $sec '凭据/中文名.md' ("## sample`n`n" + '"privateKey": "' + $fakePrivate + '"' + "`n")
    Set-FixtureFile $sec '凭据/中文口令.md' ('口令 `' + $fakeLabeled + '`' + "`n")
    Set-FixtureFile $sec '凭据/域名引用.md' ('密码管理器（`example.com`）' + "`n")
    $gbkPath = Join-Path $sec '凭据/gbk-credential.md'
    Write-GbkFixture $gbkPath '登录密码 `Abc12345x``'
    Invoke-Git $sec @('add', '-A') | Out-Null
    Invoke-Git $sec @('commit', '-q', '-m', 'fixture') | Out-Null

    $r = Invoke-Tool @($secTool)
    Check 'check-secrets：中文名文件真被扫到' (($r.Code -eq 1) -and ($r.Text -match '中文名\.md')) ("exit=$($r.Code) " + $r.Text)
    Check 'check-secrets：不打印命中原文' ($r.Text -notmatch [regex]::Escape($fakePrivate)) $r.Text
    Check 'check-secrets：中文标签后的真口令被报出' (($r.Code -eq 1) -and ($r.Text -match '中文口令\.md')) ("exit=$($r.Code) " + $r.Text)
    Check 'check-secrets：域名引用不误报' ($r.Text -notmatch '域名引用\.md') $r.Text
    Check 'check-secrets：GBK 文件既报编码可疑也扫出口令' (($r.Code -eq 1) -and ($r.Text -match 'gbk-credential\.md') -and ($r.Text -match 'encoding-suspect') -and ($r.Text -match '已按 GB18030 解码')) $r.Text

    Set-FixtureFile $sec '凭据/staged.md' ('token=' + $fakeToken + "`n")
    Invoke-Git $sec @('add', '--', '凭据/staged.md') | Out-Null
    $r = Invoke-Tool @($secTool, '-Staged')
    Check 'check-secrets：-Staged 只扫暂存区并报出文件' (($r.Code -eq 1) -and ($r.Text -match 'staged\.md')) ("exit=$($r.Code) " + $r.Text)

    $r = Invoke-Tool @($secTool, '-Exclude', '凭据/*')
    Check 'check-secrets：-Exclude 能排掉误报' (($r.Code -eq 0) -and ($r.Text -match '未发现疑似凭据')) ("exit=$($r.Code) " + $r.Text)

    $r = Invoke-Tool @($secTool, '-Repo', $good)
    Check 'check-secrets：干净样例 exit 0' (($r.Code -eq 0) -and ($r.Text -match '未发现疑似凭据')) ("exit=$($r.Code) " + $r.Text)

    # ── 6) 硬约束：tools/ 下所有 .ps1 都得是 UTF-8 with BOM ───────
    Write-Host "`n  ── 硬约束（BOM）──" -ForegroundColor Cyan
    $noBom = @()
    $psFiles = @(Get-ChildItem $toolsDir -Recurse -File -Filter '*.ps1')
    foreach ($f in $psFiles) {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
            $noBom += $f.Name
        }
    }
    Check ("tools/ 下 {0} 个 .ps1 全部 UTF-8 with BOM" -f $psFiles.Count) ($noBom.Count -eq 0) ($noBom -join ', ')

    Write-Host ""
    if ($script:failures.Count -gt 0) {
        Write-Host ("失败 {0} 项 / 通过 {1} 项" -f $script:failures.Count, $script:passCount) -ForegroundColor Red
        exit 1
    }
    Write-Host ("全部通过：{0} 项" -f $script:passCount) -ForegroundColor Green
    exit 0
} finally {
    $env:GIT_CONFIG_GLOBAL = $oldGitConfigGlobal
    if ($KeepFixture) {
        Write-Host "  样例保留：$root" -ForegroundColor DarkGray
    } elseif (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

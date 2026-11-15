#Requires -Version 5.1
<#
.SYNOPSIS
    一条命令看效果：把 fixtures/good、fixtures/bad 复制到临时目录，各建一个 git 仓库，
    然后跑分类检查和凭据自查。

.DESCRIPTION
    样例要放到临时目录再 git init，是因为工具用 git 区分已跟踪/未跟踪文件；
    直接对 fixtures/ 子目录跑，看到的不是真实仓库状态。

    预期结果：
      good   -> exit 0
      bad    -> exit 1（违规词 + 无来源日期 + 未跟踪草稿）
      secrets-> exit 1（fixtures/bad 里的假口令）

.PARAMETER Keep
    跑完不删临时目录，方便看现场。

.EXAMPLE
    pwsh -NoProfile -File tools/demo.ps1
    pwsh -NoProfile -File tools/demo.ps1 -Keep
#>
[CmdletBinding()]
param([switch]$Keep)

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
if (-not $psExe) { Write-Host "找不到 pwsh / powershell。" -ForegroundColor Red; exit 2 }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Host "找不到 git。" -ForegroundColor Red; exit 2 }

$config = Join-Path $repo 'docs-lint.config.json'
$audit = Join-Path $toolsDir 'audit-docs.ps1'
$secrets = Join-Path $toolsDir 'check-secrets.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('docs-lint-demo-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

function New-DemoRepo {
    param([string]$Name)
    $src = Join-Path (Join-Path $repo 'fixtures') $Name
    $dst = Join-Path $root $Name
    Copy-Item -LiteralPath $src -Destination $dst -Recurse
    Push-Location $dst
    try {
        & git init -q
        & git config user.email 'demo@example.invalid'
        & git config user.name 'docs-lint demo'
        & git config core.quotepath false
        & git config core.autocrlf false
        & git add -A
        # 故意留一个未跟踪文件，演示「内容照扫 + 单独报 untracked」
        if (Test-Path -LiteralPath 'draft-untracked.md') {
            & git rm --cached -q -- 'draft-untracked.md'
        }
    } finally { Pop-Location }
    return $dst
}

try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $good = New-DemoRepo 'good'
    $bad = New-DemoRepo 'bad'

    # 凭据样例在运行时生成，仓库里不存任何像凭据的字面量
    $demoPass = 'demo-' + [guid]::NewGuid().ToString('N').Substring(0, 16)
    $notesDir = Join-Path $bad 'notes'
    New-Item -ItemType Directory -Force -Path $notesDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $notesDir 'credential-demo.md'), ('password = "' + $demoPass + '"' + "`n"), (New-Object Text.UTF8Encoding $false))
    Push-Location $bad
    try { & git add -- 'notes/credential-demo.md' } finally { Pop-Location }

    Write-Host ""
    Write-Host "=== 1/3  good fixture（预期 exit 0）===" -ForegroundColor Cyan
    & $psExe -NoProfile -File $audit -Repo $good -Config $config
    $goodCode = $LASTEXITCODE

    Write-Host ""
    Write-Host "=== 2/3  bad fixture（预期 exit 1）===" -ForegroundColor Cyan
    & $psExe -NoProfile -File $audit -Repo $bad -Config $config
    $badCode = $LASTEXITCODE

    Write-Host ""
    Write-Host "=== 3/3  secrets scan on bad fixture（预期 exit 1）===" -ForegroundColor Cyan
    & $psExe -NoProfile -File $secrets -Repo $bad
    $secCode = $LASTEXITCODE

    Write-Host ""
    $ok = ($goodCode -eq 0) -and ($badCode -eq 1) -and ($secCode -eq 1)
    if ($ok) {
        Write-Host "demo 结果符合预期：good=$goodCode bad=$badCode secrets=$secCode" -ForegroundColor Green
    } else {
        Write-Host "demo 结果不符合预期：good=$goodCode bad=$badCode secrets=$secCode" -ForegroundColor Red
    }
    if ($Keep) {
        Write-Host "临时目录（已保留）：$root" -ForegroundColor DarkGray
    } else {
        Write-Host "临时目录已删除（加 -Keep 可保留）" -ForegroundColor DarkGray
    }
    if ($ok) { exit 0 } else { exit 1 }
} finally {
    if (-not $Keep -and (Test-Path -LiteralPath $root)) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

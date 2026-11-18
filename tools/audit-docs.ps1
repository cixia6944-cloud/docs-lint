<#
.SYNOPSIS
    长文档一致性检查：按配置里的分类规则体检 Markdown。

.DESCRIPTION
    这个工具只做机械可判的那部分，不试图理解语义：

    分类
      · categories 是一个有序数组，按 match 里的 glob 从上到下匹配，第一个命中生效。
      · 每类可以决定：查不查违规词、日期怎么管、要不要提示「该拆文件」。
      · 没有任何分类匹配的文件会报 no-category，而不是悄悄跳过 —— 配置漏了也是错。

    日期
      datePolicy = sourced  日期必须有上下文来源：
                              文件头版本标记（> Updated: ... / 更新：...）
                              「实测 / 验证 / verified」这类行
                              表格行
                              指向 .md 的路径
                              行内代码里的日期
                              不认识的日期写法会报 date-style，而不是当成没有日期
      datePolicy = free     日期不受限；可开 warnIfNoDate 提示「一个日期都没有」
      datePolicy = ignore   不检查日期

      代码块（``` 围起来的部分）里的日期是示例数据，跳过。
      日期太多本身是信号：达到 dateCap 时提示该拆文件（默认 8 处，不阻断）。

    违规词
      checkBadWords = true 的分类会用 audit/rules.json 里的 badWords 检查历史叙述词。
      词表是【正则片段】数组，工具用 | 拼成一个正则。

    未跟踪的 .md
      git ls-files 只列已入库的文件。新写的文档在 git add 之前既不在历史里、也不进
      备份，而且很容易被检查器漏掉。这里两者都处理：内容照扫，另记一条 untracked
      逼你先 add（或加进 .gitignore 明确表示不该入库）。行为由配置的 untracked 控制。

    编码
      Markdown 必须能按严格 UTF-8 解码。解码失败会报 encoding-suspect，
      该文件不参与后续内容检查，避免把乱码当成「没问题」。

    退出码
      0  干净
      1  有违规，或配置/词表缺失、解析失败、为空、正则非法（绝不静默退回内置规则）
      2  环境问题：不是 git 仓库、找不到 git、仓库目录不存在

.PARAMETER Repo
    要检查的仓库根目录，默认本脚本所在仓库（tools/ 的上一级）。

.PARAMETER Config
    配置文件路径。默认 <Repo>/docs-lint.config.json。相对路径按 -Repo 解析。

.PARAMETER Rules
    违规词文件路径，覆盖配置里的 rulesFile。相对路径按 -Repo 解析。

.PARAMETER Json
    只输出一行机器可读 JSON，不打印人话。

.PARAMETER Quiet
    不打印分类统计与提示（违规明细照打）。

.EXAMPLE
    pwsh -NoProfile -File tools/audit-docs.ps1 -Repo .
    pwsh -NoProfile -File tools/audit-docs.ps1 -Repo . -Json
    pwsh -NoProfile -File tools/audit-docs.ps1 -Repo ./fixtures/bad -Config ./docs-lint.config.json
#>
param(
    [string]$Repo,
    [string]$Config,
    [string]$Rules,
    [switch]$Json,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# 契约：stdout 不是终端就写 UTF-8，别指望调用方把 shell 设对
try {
    if ([Console]::IsOutputRedirected) {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
} catch { }

$SCHEMA_VERSION = 1
$toolRoot = Split-Path -Parent $PSScriptRoot
$repo = if ($Repo) { $Repo } else { $toolRoot }
if (Test-Path -LiteralPath $repo) {
    try { $repo = (Resolve-Path -LiteralPath $repo).Path } catch { }
}
$configPath = $null
$rulesFile = $null

function Write-FailJson([string]$msg, [int]$code) {
    [ordered]@{
        schema_version = $SCHEMA_VERSION
        tool           = 'audit-docs'
        repo           = $repo
        config         = $configPath
        rules          = $rulesFile
        generated_at   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        ok             = $false
        exit_code      = $code
        counts         = [ordered]@{}
        issues         = @()
        warnings       = @()
        error          = $msg
    } | ConvertTo-Json -Compress -Depth 10
}

# 配置/判据出问题时唯一的出口：exit 1，绝不退回内置词表。
# 静默退回就是「假绿」：工具看起来通过了，其实没按你以为的规则看过。
function Fail([string]$msg) {
    if ($Json) { Write-FailJson $msg 1; exit 1 }
    Write-Host "[×] $msg" -ForegroundColor Red
    Write-Host "    配置/判据不可用，工具不会退回内置规则（静默退回就是假绿）。" -ForegroundColor Yellow
    exit 1
}

function FailEnv([string]$msg) {
    if ($Json) { Write-FailJson $msg 2; exit 2 }
    Write-Host "[×] $msg" -ForegroundColor Red
    exit 2
}

function Get-ConfigBool($obj, [string]$name, [bool]$fallback) {
    if ($null -eq $obj) { return $fallback }
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p -or $null -eq $p.Value) { return $fallback }
    return [bool]$p.Value
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    FailEnv "找不到 git，无法判断哪些 .md 被跟踪"
}

if (-not (Test-Path -LiteralPath $repo)) {
    FailEnv "仓库目录不存在：$repo"
}

Push-Location $repo
try {
    if (-not (Test-Path -LiteralPath '.git')) {
        FailEnv "不是 git 仓库：$repo（本工具用 git 区分已跟踪/未跟踪，没有 .git 就无法给出可信结论）"
    }

    # ---------- 配置 ----------
    $configPath = if ($Config) { $Config } else { Join-Path $repo 'docs-lint.config.json' }
    if (-not [IO.Path]::IsPathRooted($configPath)) { $configPath = Join-Path $repo $configPath }

    if (-not (Test-Path -LiteralPath $configPath)) {
        Fail "找不到配置文件：$configPath"
    }
    try {
        $configDoc = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Fail "配置文件解析失败：$configPath — $($_.Exception.Message)"
    }
    if ($null -eq $configDoc) { Fail "配置文件是空的：$configPath" }

    $categories = @($configDoc.categories)
    if ($categories.Count -eq 0) { Fail "配置文件里 categories 是空的：$configPath" }

    $catSpecs = New-Object System.Collections.ArrayList
    $seenNames = @{}
    foreach ($c in $categories) {
        if (-not $c.name) { Fail "categories 里有一项缺少 name：$configPath" }
        if ($seenNames.ContainsKey([string]$c.name)) { Fail "categories 里有重复的 name：$($c.name)" }
        $seenNames[[string]$c.name] = $true
        $patterns = @($c.match | Where-Object { $_ } | ForEach-Object { [string]$_ })
        if ($patterns.Count -eq 0) { Fail "分类 $($c.name) 缺少 match：$configPath" }
        $policy = if ($c.datePolicy) { [string]$c.datePolicy } else { 'ignore' }
        if (@('sourced', 'free', 'ignore') -notcontains $policy) {
            Fail "分类 $($c.name) 的 datePolicy 无效：$policy（只允许 sourced/free/ignore）"
        }
        $matchers = @()
        foreach ($p in $patterns) {
            try {
                $matchers += New-Object -TypeName System.Management.Automation.WildcardPattern -ArgumentList @($p, [System.Management.Automation.WildcardOptions]::IgnoreCase)
            } catch {
                Fail "分类 $($c.name) 的 match 无效：$p — $($_.Exception.Message)"
            }
        }
        [void]$catSpecs.Add([pscustomobject]@{
                Name            = [string]$c.name
                Patterns        = $patterns
                Matchers        = $matchers
                DatePolicy      = $policy
                CheckBadWords   = [bool]$c.checkBadWords
                WarnIfNoDate    = [bool]$c.warnIfNoDate
                WarnIfDateDense = [bool]$c.warnIfDateDense
            })
    }

    # ---------- 违规词（判据数据外置）----------
    $configDir = Split-Path -Parent $configPath
    if ($Rules) {
        $rulesFile = if ([IO.Path]::IsPathRooted($Rules)) { $Rules } else { Join-Path $repo $Rules }
    } elseif ($configDoc.rulesFile) {
        $candidate = [string]$configDoc.rulesFile
        $rulesFile = if ([IO.Path]::IsPathRooted($candidate)) { $candidate } else { Join-Path $configDir $candidate }
    } else {
        $rulesFile = Join-Path $configDir 'audit/rules.json'
    }

    if (-not (Test-Path -LiteralPath $rulesFile)) {
        Fail "找不到规则文件：$rulesFile"
    }
    try {
        $rulesDoc = Get-Content -LiteralPath $rulesFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Fail "规则文件解析失败：$rulesFile — $($_.Exception.Message)"
    }
    $badWords = @($rulesDoc.badWords | Where-Object { $_ -and ([string]$_).Trim() })
    if ($badWords.Count -eq 0) { Fail "规则文件里 badWords 是空的：$rulesFile" }
    $reBadWords = ($badWords | ForEach-Object { [string]$_ }) -join '|'
    try { [void][regex]::new($reBadWords) } catch { Fail "badWords 里有非法正则：$rulesFile — $($_.Exception.Message)" }

    # ---------- 日期规则 ----------
    $dateRules = $configDoc.dateRules
    $headerLines = 15
    $headerMarkers = @('更新', '最后更新', '版本', 'updated', 'last updated', 'date', 'created')
    $verifyWords = @('实测', '验证', '复测', 'verified', 'tested')
    $allowTableRows = $true
    $allowPathDates = $true
    $allowInlineCode = $true
    $allowBlockquoteHeader = $true
    if ($dateRules) {
        if ($null -ne $dateRules.headerLines) { $headerLines = [int]$dateRules.headerLines }
        if ($dateRules.headerMarkers) { $headerMarkers = @($dateRules.headerMarkers | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
        if ($dateRules.verifyWords) { $verifyWords = @($dateRules.verifyWords | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
        $allowTableRows = Get-ConfigBool $dateRules 'allowTableRows' $true
        $allowPathDates = Get-ConfigBool $dateRules 'allowPathDates' $true
        $allowInlineCode = Get-ConfigBool $dateRules 'allowInlineCode' $true
        $allowBlockquoteHeader = Get-ConfigBool $dateRules 'allowBlockquoteHeader' $true
    }

    $reDate = '20\d{2}-(?:0[1-9]|1[0-2])(?:-(?:0[1-9]|[12]\d|3[01]))?|20\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])(?!\d)|20\d{2}\s*年\s*\d{1,2}\s*月(?:\s*\d{1,2}\s*日)?'
    $reSuspectDate = '(?<!\d)(?:0?[1-9]|1[0-2])/(?:0?[1-9]|[12]\d|3[01])/20\d{2}(?!\d)|(?<!\d)20\d{2}/(?:0?[1-9]|1[0-2])/(?:0?[1-9]|[12]\d|3[01])(?!\d)|(?<!\d)(?:0?[1-9]|[12]\d|3[01])\.(?:0?[1-9]|1[0-2])\.20\d{2}(?!\d)|(?<!\d)20\d{2}-(?:[1-9]|1[0-2])(?:-(?:[1-9]|[12]\d|3[01]))?(?!\d)|(?<!\d)(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+(?:0?[1-9]|[12]\d|3[01])(?:st|nd|rd|th)?,?\s+20\d{2}(?!\d)|(?<!\d)(?:0?[1-9]|[12]\d|3[01])(?:st|nd|rd|th)?\s+(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?,?\s+20\d{2}(?!\d)'
    $reAnyDate = '(?:' + $reDate + ')|(?:' + $reSuspectDate + ')'
    $dateStyle = if ($configDoc.dateStyle) { ([string]$configDoc.dateStyle).ToLowerInvariant() } else { 'warn' }
    if (@('off', 'warn', 'error') -notcontains $dateStyle) {
        Fail "配置里的 dateStyle 无效：$dateStyle（只允许 off/warn/error）"
    }

    function Mask-Matches([string]$Text, [string]$Pattern) {
        $builder = New-Object System.Text.StringBuilder
        $cursor = 0
        foreach ($m in [regex]::Matches($Text, $Pattern)) {
            [void]$builder.Append($Text.Substring($cursor, $m.Index - $cursor))
            [void]$builder.Append(' ', $m.Length)
            $cursor = $m.Index + $m.Length
        }
        [void]$builder.Append($Text.Substring($cursor))
        return $builder.ToString()
    }

    function ConvertTo-CanonicalDate([string]$Value) {
        $monthNames = @{
            'jan' = 1; 'feb' = 2; 'mar' = 3; 'apr' = 4; 'may' = 5; 'jun' = 6
            'jul' = 7; 'aug' = 8; 'sep' = 9; 'oct' = 10; 'nov' = 11; 'dec' = 12
        }
        if ($Value -match '^(?<month>0?[1-9]|1[0-2])/(?<day>0?[1-9]|[12]\d|3[01])/(?<year>20\d{2})$') {
            return '{0:D4}-{1:D2}-{2:D2}' -f [int]$matches.year, [int]$matches.month, [int]$matches.day
        }
        if ($Value -match '^(?<year>20\d{2})/(?<month>0?[1-9]|1[0-2])/(?<day>0?[1-9]|[12]\d|3[01])$') {
            return '{0:D4}-{1:D2}-{2:D2}' -f [int]$matches.year, [int]$matches.month, [int]$matches.day
        }
        if ($Value -match '^(?<day>0?[1-9]|[12]\d|3[01])\.(?<month>0?[1-9]|1[0-2])\.(?<year>20\d{2})$') {
            return '{0:D4}-{1:D2}-{2:D2}' -f [int]$matches.year, [int]$matches.month, [int]$matches.day
        }
        if ($Value -match '^(?<year>20\d{2})-(?<month>[1-9]|1[0-2])-(?<day>[1-9]|[12]\d|3[01])$') {
            return '{0:D4}-{1:D2}-{2:D2}' -f [int]$matches.year, [int]$matches.month, [int]$matches.day
        }
        if ($Value -match '^(?<month>Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+(?<day>0?[1-9]|[12]\d|3[01])(?:st|nd|rd|th)?,?\s+(?<year>20\d{2})$') {
            $month = $monthNames[$matches.month.ToLowerInvariant().Substring(0, 3)]
            return '{0:D4}-{1:D2}-{2:D2}' -f [int]$matches.year, $month, [int]$matches.day
        }
        if ($Value -match '^(?<day>0?[1-9]|[12]\d|3[01])(?:st|nd|rd|th)?\s+(?<month>Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?,?\s+(?<year>20\d{2})$') {
            $month = $monthNames[$matches.month.ToLowerInvariant().Substring(0, 3)]
            return '{0:D4}-{1:D2}-{2:D2}' -f [int]$matches.year, $month, [int]$matches.day
        }
        return $null
    }
    $reHeaderMark = $null
    if ($headerMarkers.Count -gt 0) {
        $markerAlt = ($headerMarkers | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $reHeaderMark = '(?i)^\s*>?\s*(' + $markerAlt + ')'
    }
    $reVerify = $null
    if ($verifyWords.Count -gt 0) {
        $verifyAlt = ($verifyWords | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $reVerify = '(?i)(' + $verifyAlt + ')'
    }

    $dateCap = 8
    if ($null -ne $configDoc.dateCap) { $dateCap = [int]$configDoc.dateCap }

    $untrackedMode = if ($configDoc.untracked) { [string]$configDoc.untracked } else { 'error' }
    if (@('error', 'warn', 'ignore') -notcontains $untrackedMode) {
        Fail "配置里的 untracked 无效：$untrackedMode（只允许 error/warn/ignore）"
    }

    function Get-Category([string]$rel) {
        foreach ($c in $catSpecs) {
            foreach ($m in $c.Matchers) {
                if ($m.IsMatch($rel)) { return $c }
            }
        }
        return $null
    }

    # git 吐的是 UTF-8。core.quotepath=false 防止中文名变成 "\344\270\255"，
    # 临时切到 UTF-8 防止宿主 [Console]::OutputEncoding=gb2312 把中文名解成乱码。
    # 两条路都会让 Test-Path 落空，于是文件被静默跳过 —— 那是最难发现的假绿。
    function Invoke-GitLines {
        param([string[]]$ArgList)
        $oldEnc = try { [Console]::OutputEncoding } catch { $null }
        try {
            try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
            $out = @(git @ArgList)
            if ($LASTEXITCODE -ne 0) { throw "git $($ArgList -join ' ') 执行失败（exit $LASTEXITCODE）" }
            return $out
        } finally {
            if ($oldEnc) { try { [Console]::OutputEncoding = $oldEnc } catch { } }
        }
    }

    try {
        $untracked = @(Invoke-GitLines @('-c', 'core.quotepath=false', 'ls-files', '--others', '--exclude-standard', '--', '*.md'))
        $mdFiles = @(@(Invoke-GitLines @('-c', 'core.quotepath=false', 'ls-files', '*.md')) + $untracked)
    } catch {
        FailEnv "读取 git 文件列表失败：$($_.Exception.Message)"
    }

    $issues = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $stats = [ordered]@{}
    foreach ($c in $catSpecs) { $stats[$c.Name] = 0 }

    foreach ($rel in $mdFiles) {
        if (-not $rel) { continue }
        $path = Join-Path $repo $rel
        $cat = Get-Category $rel
        if ($null -eq $cat) {
            [void]$issues.Add([pscustomobject]@{
                    Category = '?'; File = $rel; Line = 0; Rule = 'no-category'
                    Message  = '没有匹配的分类'
                    Detail   = '配置里的 categories 没覆盖这个路径：补一条 match，或加一个最后的 catch-all（*）'
                })
            continue
        }
        if (-not (Test-Path -LiteralPath $path)) {
            [void]$issues.Add([pscustomobject]@{
                    Category = $cat.Name; File = $rel; Line = 0; Rule = 'missing-on-disk'
                    Message  = 'git 里有记录，磁盘上没这个文件'
                    Detail   = '要么删掉索引记录，要么把文件找回来'
                })
            continue
        }

        $stats[$cat.Name] = [int]$stats[$cat.Name] + 1
        $bytes = [IO.File]::ReadAllBytes($path)
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        try {
            $text = $strictUtf8.GetString($bytes)
        } catch {
            [void]$issues.Add([pscustomobject]@{
                    Category = $cat.Name; File = $rel; Line = 0; Rule = 'encoding-suspect'
                    Message  = '文件不是严格 UTF-8'
                    Detail   = '疑似其他编码；先转成 UTF-8，再让工具检查内容，避免乱码被静默当成合规'
                })
            continue
        }
        $lines = $text -split "`r?`n"
        $dateHits = 0
        $inFence = $false

        for ($i = 0; $i -lt $lines.Length; $i++) {
            $line = $lines[$i]
            # 代码块里是示例输出/命令，日期是数据不是叙事，跳过
            if ($line.TrimStart().StartsWith('```')) { $inFence = -not $inFence; continue }
            if ($inFence) { continue }
            if (-not $line) { continue }

            $isHeader = ($i -lt $headerLines)
            $isTable = $line.TrimStart().StartsWith('|')
            $dateMatches = [regex]::Matches($line, $reAnyDate, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $hasDate = $dateMatches.Count -gt 0
            if ($hasDate) { $dateHits += $dateMatches.Count }

            if ($cat.CheckBadWords -and $line -match $reBadWords) {
                [void]$issues.Add([pscustomobject]@{
                        Category = $cat.Name; File = $rel; Line = ($i + 1); Rule = 'badword'
                        Message  = '出现历史叙述词'
                        Detail   = ($line.Trim() -replace '\s+', ' ')
                    })
                continue
            }

            $allowed = $false
            $styleExempt = $false
            if ($dateStyle -ne 'off') {
                $styleText = Mask-Matches $line $reDate
                if ($allowPathDates -and $styleText -match '\.md' -and $styleText -match '[/\\]') { $styleExempt = $true }
                if (-not $styleExempt -and $allowInlineCode -and ($styleText -match ('`[^`]*(?:' + $reSuspectDate + ')[^`]*`'))) { $styleExempt = $true }
                if (-not [bool]$styleExempt) {
                    $styleMatches = @([regex]::Matches($styleText, $reSuspectDate, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))
                    if ($styleMatches.Count -gt 0) { $styleMatch = $styleMatches[0] } else { $styleMatch = $null }
                    if ($styleMatch) {
                        $canonical = ConvertTo-CanonicalDate $styleMatch.Value
                        $detail = if ($canonical) { "$($styleMatch.Value) → $canonical" } else { "无法转换日期写法：$($styleMatch.Value)" }
                        $item = [pscustomobject]@{
                            Category = $cat.Name; File = $rel; Line = ($i + 1); Rule = 'date-style'
                            Message  = '日期写法需要统一'
                            Detail   = $detail
                        }
                        if ($dateStyle -eq 'error') {
                            [void]$issues.Add($item)
                        } else {
                            [void]$warnings.Add([pscustomobject]@{
                                    File = $rel; Line = ($i + 1); Rule = 'date-style'
                                    Detail = $detail
                                })
                        }
                    }
                }
            }

            if ($cat.DatePolicy -ne 'sourced' -or -not $hasDate) { continue }

            if ($isHeader) {
                if ($allowBlockquoteHeader -and $line.TrimStart().StartsWith('>')) { $allowed = $true }
                elseif ($reHeaderMark -and ($line -match $reHeaderMark)) { $allowed = $true }
            }
            if (-not $allowed -and $reVerify -and ($line -match $reVerify)) { $allowed = $true }
            if (-not $allowed -and $allowTableRows -and $isTable) { $allowed = $true }
            if (-not $allowed -and $allowPathDates -and ($line -match '\.md' -and $line -match '[/\\]')) { $allowed = $true }
            if (-not $allowed -and $allowInlineCode -and ($line -match ('`[^`]*' + $reAnyDate + '[^`]*`'))) { $allowed = $true }

            if (-not $allowed) {
                [void]$issues.Add([pscustomobject]@{
                        Category = $cat.Name; File = $rel; Line = ($i + 1); Rule = 'date-nosource'
                        Message  = '该分类文档里有无来源的日期'
                        Detail   = ($line.Trim() -replace '\s+', ' ')
                    })
            }
        }

        if ($cat.WarnIfDateDense -and $dateHits -ge $dateCap) {
            [void]$warnings.Add([pscustomobject]@{
                    File = $rel; Rule = 'date-density'
                    Detail = "日期 $dateHits 处（阈值 $dateCap），检查是否还有该拆出去的部分"
                })
        }
        if ($cat.WarnIfNoDate -and $dateHits -eq 0) {
            [void]$warnings.Add([pscustomobject]@{
                    File = $rel; Rule = 'history-no-date'
                    Detail = '这个分类的文档没有任何日期，检查是否分错类'
                })
        }
    }

    if ($untrackedMode -ne 'ignore') {
        foreach ($rel in $untracked) {
            if (-not $rel) { continue }
            $cat = Get-Category $rel
            $catName = if ($cat) { $cat.Name } else { '?' }
            $detail = '不入 git 就不在历史里、也不进备份：先 git add，或加进 .gitignore 明确表示不该入库'
            if ($untrackedMode -eq 'warn') {
                [void]$warnings.Add([pscustomobject]@{ File = $rel; Rule = 'untracked'; Detail = $detail })
            } else {
                [void]$issues.Add([pscustomobject]@{
                        Category = $catName; File = $rel; Line = 0; Rule = 'untracked'
                        Message  = '未跟踪的 .md（还没 git add）'
                        Detail   = $detail
                    })
            }
        }
    }

    # ---------- 输出 ----------
    if ($Json) {
        $allItems = New-Object System.Collections.ArrayList
        foreach ($i in $issues) {
            [void]$allItems.Add([ordered]@{
                    category = $i.Category
                    rule     = $i.Rule
                    severity = 'error'
                    file     = $i.File
                    line     = $i.Line
                    detail   = $i.Detail
                })
        }
        $warningItems = New-Object System.Collections.ArrayList
        foreach ($w in $warnings) {
            [void]$warningItems.Add([ordered]@{
                    rule     = $w.Rule
                    severity = 'warn'
                    file     = $w.File
                    line     = $null
                    detail   = $w.Detail
                })
        }
        $exitCode = if ($issues.Count -eq 0) { 0 } else { 1 }
        $payload = [ordered]@{
            schema_version = $SCHEMA_VERSION
            tool           = 'audit-docs'
            repo           = $repo
            config         = $configPath
            rules          = $rulesFile
            generated_at   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
            ok             = ($exitCode -eq 0)
            exit_code      = $exitCode
            counts         = $stats
            issues         = @($allItems)
            warnings       = @($warningItems)
            error          = $null
        }
        $payload | ConvertTo-Json -Compress -Depth 10
        exit $exitCode
    }

    if (-not $Quiet) {
        $summary = ($stats.Keys | ForEach-Object { "$_ $($stats[$_])" }) -join ' / '
        Write-Host ""
        Write-Host "  分类：$summary" -ForegroundColor Cyan
        Write-Host ""
        if ($warnings.Count -gt 0) {
            Write-Host "  提示（不阻断）：" -ForegroundColor DarkCyan
            $warnings | ForEach-Object { Write-Host ("      {0,-46} {1}" -f $_.File, $_.Detail) -ForegroundColor DarkGray }
            Write-Host ""
        }
    }

    if ($issues.Count -eq 0) {
        Write-Host "  OK  分类与日期规则均合规" -ForegroundColor Green
        Write-Host ""
        exit 0
    }

    Write-Host "  发现 $($issues.Count) 处不合规：" -ForegroundColor Yellow
    Write-Host ""
    $issues | Group-Object File | ForEach-Object {
        Write-Host ("  " + $_.Name) -ForegroundColor White
        $_.Group | Sort-Object Line | ForEach-Object {
            $loc = if ($_.Line -gt 0) { "L$($_.Line)" } else { "--" }
            Write-Host ("      {0,-6} [{1}] {2}" -f $loc, $_.Rule, $_.Message) -ForegroundColor DarkYellow
            if ($_.Detail) { Write-Host ("             {0}" -f $_.Detail.Substring(0, [Math]::Min(96, $_.Detail.Length))) -ForegroundColor DarkGray }
        }
    }
    Write-Host ""
    Write-Host "  规则见 $configPath" -ForegroundColor Cyan
    Write-Host ""
    exit 1
}
finally { Pop-Location }

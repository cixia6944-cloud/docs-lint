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

.PARAMETER FactPack
    把可 diff 的稳定事实包写到指定 JSON 文件；stdout 保持原有输出。

.PARAMETER Baseline
    与上一次 -FactPack 按 finding id 比对，并把结果写进本次事实包。

.PARAMETER FailOnNew
    与 -Baseline 搭配：只有出现新 finding id 时才因基线差异 exit 1。

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
    [string]$FactPack,
    [string]$Baseline,
    [switch]$FailOnNew,
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
                CheckDateStyle  = (Get-ConfigBool $c 'checkDateStyle' ($policy -eq 'sourced'))
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

    function Get-ConfigSeverity($obj, [string]$name, [string]$fallback) {
        if ($null -eq $obj) { return $fallback }
        $property = $obj.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value) { return $fallback }
        $value = ([string]$property.Value).ToLowerInvariant()
        if (@('off', 'warn', 'error') -notcontains $value) {
            Fail "配置里的 $name 无效：$value（只允许 off/warn/error）"
        }
        return $value
    }

    # ---------- 证据与残留规则 ----------
    $rulesConfig = $configDoc.rules
    $claimConfig = if ($rulesConfig) { $rulesConfig.claimUnsupported } else { $null }
    $todoConfig = if ($rulesConfig) { $rulesConfig.todoResidue } else { $null }
    $staleConfig = if ($rulesConfig) { $rulesConfig.staleReference } else { $null }
    $claimSeverity = Get-ConfigSeverity $claimConfig 'severity' 'warn'
    $todoSeverity = Get-ConfigSeverity $todoConfig 'severity' 'error'
    $staleSeverity = Get-ConfigSeverity $staleConfig 'severity' 'error'

    $claimWords = @('已完成', '已修复', '已部署', '已上线', '实测通过', '验证过', '已解决', 'done', 'fixed', 'shipped')
    if ($claimConfig -and $claimConfig.claims) {
        $claimWords = @($claimConfig.claims | Where-Object { $_ -and ([string]$_).Trim() } | ForEach-Object { [string]$_ })
    }
    $claimCommands = @('pwsh', 'git', 'curl', 'systemctl', 'docker', 'python', 'npm', 'dotnet')
    if ($claimConfig -and $claimConfig.commands) {
        $claimCommands = @($claimConfig.commands | Where-Object { $_ -and ([string]$_).Trim() } | ForEach-Object { [string]$_ })
    }
    $todoWords = @('FIXME', '待补', '待确认', '暂未实现')
    if ($todoConfig -and $todoConfig.words) {
        $todoWords = @($todoConfig.words | Where-Object { $_ -and ([string]$_).Trim() } | ForEach-Object { [string]$_ })
    }
    $allowTodoFiles = @('TODO.md', 'AGENTS.md', 'docs-templates/*')
    if ($todoConfig -and $todoConfig.allowTodoFiles) {
        $allowTodoFiles = @($todoConfig.allowTodoFiles | Where-Object { $_ -and ([string]$_).Trim() } | ForEach-Object { ([string]$_).Replace('\', '/') })
    }
    $staleExtensions = @('.md', '.ps1', '.py', '.sh', '.json', '.yml', '.yaml', '.txt')
    if ($staleConfig -and $staleConfig.extensions) {
        $staleExtensions = @($staleConfig.extensions | Where-Object { $_ -and ([string]$_).Trim() } | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }
    $stalePlaceholderSegments = @('...', 'xxx', 'yyy', 'zzz', 'yyyy', 'mm', 'dd')
    if ($staleConfig -and $staleConfig.placeholderSegments) {
        $stalePlaceholderSegments = @($staleConfig.placeholderSegments | Where-Object { $_ -and ([string]$_).Trim() } | ForEach-Object { ([string]$_).Trim() })
    }
    if (@($claimWords).Count -eq 0) { Fail "rules.claimUnsupported.claims 不能为空" }
    if (@($claimCommands).Count -eq 0) { Fail "rules.claimUnsupported.commands 不能为空" }
    if (@($todoWords).Count -eq 0) { Fail "rules.todoResidue.words 不能为空" }
    if (@($staleExtensions).Count -eq 0) { Fail "rules.staleReference.extensions 不能为空" }
    if (@($stalePlaceholderSegments).Count -eq 0) { Fail "rules.staleReference.placeholderSegments 不能为空" }

    function Join-WordPattern([string[]]$Words) {
        return (($Words | ForEach-Object { '(?<![A-Za-z0-9_])' + [regex]::Escape($_) + '(?![A-Za-z0-9_])' }) -join '|')
    }
    $reClaim = Join-WordPattern $claimWords
    $reClaimCommand = Join-WordPattern $claimCommands
    $reTodo = Join-WordPattern $todoWords
    $extensionAlt = (($staleExtensions | ForEach-Object { [regex]::Escape($_) }) -join '|')
    $pathCharClass = '[a-z0-9_.\-\p{L}\p{N}]'
    $reStaleReference = '(?i)(?<![a-z0-9_\[])(?:' + $pathCharClass + '+/)+' + $pathCharClass + '+(?:' + $extensionAlt + ')(?::(\d+))?(?![a-z0-9_\]])'
    $reStaleLineReference = '(?i)(?<![a-z0-9_])(?:' + $pathCharClass + '+/)+' + $pathCharClass + '+(?:' + $extensionAlt + '):(\d+)(?![a-z0-9_])'
    $stalePlaceholderAlt = (($stalePlaceholderSegments | ForEach-Object { [regex]::Escape($_) }) -join '|')
    $reStalePlaceholder = '(?i)(?:^|/)(?:' + $stalePlaceholderAlt + ')(?=/|[-_.]|$)'

    function Test-ClaimEvidence([string]$CurrentLine, [string]$NextLine, [string[]]$Lines, [int]$NextIndex) {
        $evidenceLines = @($CurrentLine, $NextLine) | Where-Object { $_ }
        foreach ($evidenceLine in $evidenceLines) {
            if ($evidenceLine -match '(?i)https?://') { return $true }
            if ($evidenceLine -match '(?i)(?<![a-z0-9_])(?:[a-z0-9_.\-]+/)*[a-z0-9_.\-]+\.[a-z0-9]+:\d+(?![a-z0-9_])') { return $true }
            if ($evidenceLine -match '(?i)\b[0-9a-f]{7,40}\b') { return $true }
            if ($evidenceLine -match ('`[^`]*(?:' + $reClaimCommand + ')[^`]*`')) { return $true }
        }
        if ($NextLine -and ($NextLine.TrimStart().StartsWith('```') -or $NextLine.TrimStart().StartsWith('~~~'))) {
            $fenceChar = if ($NextLine.TrimStart().StartsWith('```')) { '```' } else { '~~~' }
            for ($j = $NextIndex + 1; $j -lt $Lines.Count; $j++) {
                if ($Lines[$j].TrimStart().StartsWith($fenceChar)) { break }
                if ($Lines[$j] -match ('(?:' + $reClaimCommand + ')')) { return $true }
                if ($j + 1 -lt $Lines.Count -and $Lines[$j + 1].Trim()) { return $true }
            }
        }
        return $false
    }

    $blockOn = if ($configDoc.blockOn) { ([string]$configDoc.blockOn).ToLowerInvariant() } else { 'fact' }
    if (@('fact', 'all') -notcontains $blockOn) {
        Fail "配置里的 blockOn 无效：$blockOn（只允许 fact/all）"
    }

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

    $factRules = @('missing-on-disk', 'untracked', 'encoding-suspect', 'no-category', 'todo-residue', 'stale-reference')
    function Get-FindingKind([string]$Rule) {
        if ($factRules -contains $Rule) { return 'fact' }
        return 'heuristic'
    }

    function Get-FindingId([string]$File, [string]$Rule, [string]$Detail) {
        $normalized = ($Detail.Trim() -replace '\s+', ' ')
        $bytes = [Text.Encoding]::UTF8.GetBytes($File + '|' + $Rule + '|' + $normalized)
        $hash = [Security.Cryptography.SHA1]::HashData($bytes)
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
    }

    function Get-FindingVerify([string]$Rule, [string]$File, [int]$Line, [string]$Detail) {
        switch ($Rule) {
            'missing-on-disk' { return 'Test-Path -LiteralPath "' + ($File -replace '"', '`"') + '"' }
            'untracked' { return 'git ls-files --error-unmatch -- "' + ($File -replace '"', '`"') + '"' }
            'no-category' { return 'Select-String -Path "' + $configPath + '" -Pattern "categories"' }
            'date-style' { return 'Select-String -Path "' + $File + '" -Pattern "' + (($Detail -split ' → ')[0] -replace '"', '`"') + '"' }
            'claim-unsupported' {
                if ($Detail -match '「(?<claim>[^」]+)」') {
                    return 'Select-String -Path "' + $File + '" -Pattern "' + ($matches.claim -replace '"', '`"') + '"'
                }
            }
            'todo-residue' {
                if ($Detail -match '「(?<word>[^」]+)」') {
                    return 'Select-String -Path "' + $File + '" -Pattern "' + ($matches.word -replace '"', '`"') + '"'
                }
            }
            'stale-reference' {
                if ($Detail -match '「(?<reference>[^」]+?)」') {
                    $reference = $matches.reference
                    if ($reference -match ':\d+$') {
                        return 'Select-String -Path "' + $File + '" -Pattern "' + ($reference -replace '"', '`"') + '"'
                    }
                    return 'Test-Path -LiteralPath "' + ($reference -replace '"', '`"') + '"'
                }
            }
        }
        return $null
    }

    function Get-FindingFix([string]$Rule, [string]$Detail) {
        switch ($Rule) {
            'badword' { return '把历史叙述改成现状描述；确需保留时间线时移动到 history 分类' }
            'date-nosource' { return '在行内补来源，或把日期移到文件头的 updated/created 元数据' }
            'date-style' { return (($Detail -split ' → ')[1]) }
            'date-density' { return '把变更记录拆到 history 文档，保留当前指南里的稳定结论' }
            'history-no-date' { return '补一个事件日期，或把文件移到有日期规范的分类' }
            'claim-unsupported' { return '把可复现命令及其输出、来源文件:行或 commit hash 加到这一行或紧邻下一行' }
            'todo-residue' { return '完成这个待办并把标记删除，或把条目移到 TODO.md' }
            'stale-reference' { return '把路径改成实际存在的文件和行号，或删除这条引用' }
            'no-category' { return '为这个路径补一条分类 match，或加一个明确的 catch-all（*）' }
            'missing-on-disk' { return '恢复文件，或从 git 索引里移除这条记录' }
            'untracked' { return 'git add 这个文件；若不该入库则加入 .gitignore' }
            'encoding-suspect' { return '把文件转成严格 UTF-8 后重新检查' }
        }
        return $null
    }

    function Resolve-RepoReference {
        param(
            [string]$SourceRel,
            [string]$Reference
        )

        $repoFull = [IO.Path]::GetFullPath($repo)
        $sourceFull = [IO.Path]::GetFullPath((Join-Path $repo $SourceRel))
        $sourceDir = Split-Path -Parent $sourceFull
        $repoPrefix = $repoFull.TrimEnd('\') + '\'

        try {
            $target = [IO.Path]::GetFullPath((Join-Path $sourceDir $Reference))
        } catch {
            return [pscustomobject]@{ State = 'invalid'; Target = $null; RepoRelative = $null }
        }
        if (-not $target.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ State = 'outside'; Target = $null; RepoRelative = $null }
        }

        $repoRelative = $target.Substring($repoPrefix.Length).Replace('\', '/')
        try {
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                return [pscustomobject]@{ State = 'found'; Target = $target; RepoRelative = $repoRelative }
            }
        } catch {
            return [pscustomobject]@{ State = 'invalid'; Target = $null; RepoRelative = $repoRelative }
        }

        try {
            $target = [IO.Path]::GetFullPath((Join-Path $repo $Reference))
        } catch {
            return [pscustomobject]@{ State = 'invalid'; Target = $null; RepoRelative = $repoRelative }
        }
        if (-not $target.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ State = 'missing'; Target = $null; RepoRelative = $repoRelative }
        }

        $repoRelative = $target.Substring($repoPrefix.Length).Replace('\', '/')
        try {
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                return [pscustomobject]@{ State = 'found'; Target = $target; RepoRelative = $repoRelative }
            }
        } catch {
            return [pscustomobject]@{ State = 'invalid'; Target = $null; RepoRelative = $repoRelative }
        }
        return [pscustomobject]@{ State = 'missing'; Target = $null; RepoRelative = $repoRelative }
    }

    function Add-ReferenceSkip {
        param([string]$Reason)
        [void]$filesSkipped.Add([ordered]@{ path = $rel; reason = $Reason })
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
$topLevelNames = @{}
try {
    foreach ($item in @(Get-ChildItem -LiteralPath $repo -Force)) { $topLevelNames[$item.Name] = $true }
} catch {
    FailEnv "读取仓库顶层条目失败：$($_.Exception.Message)"
}
    $filesTotal = @($mdFiles | Where-Object { $_ }).Count
    $filesSkipped = New-Object System.Collections.ArrayList
    $linesScanned = 0
    $filesScanned = 0

    $issues = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $stats = [ordered]@{}
    foreach ($c in $catSpecs) { $stats[$c.Name] = 0 }

    foreach ($rel in $mdFiles) {
        if (-not $rel) { continue }
        $path = Join-Path $repo $rel
        $cat = Get-Category $rel
        if ($null -eq $cat) {
            [void]$filesSkipped.Add([ordered]@{ path = $rel; reason = 'no-category' })
            [void]$issues.Add([pscustomobject]@{
                    Category = '?'; File = $rel; Line = 0; Rule = 'no-category'
                    Message  = '没有匹配的分类'
                    Detail   = '配置里的 categories 没覆盖这个路径：补一条 match，或加一个最后的 catch-all（*）'
                })
            continue
        }
        if (-not (Test-Path -LiteralPath $path)) {
            [void]$filesSkipped.Add([ordered]@{ path = $rel; reason = 'missing-on-disk' })
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
            [void]$filesSkipped.Add([ordered]@{ path = $rel; reason = 'encoding-suspect' })
            [void]$issues.Add([pscustomobject]@{
                    Category = $cat.Name; File = $rel; Line = 0; Rule = 'encoding-suspect'
                    Message  = '文件不是严格 UTF-8'
                    Detail   = '疑似其他编码；先转成 UTF-8，再让工具检查内容，避免乱码被静默当成合规'
                })
            continue
        }
        $lines = $text -split "`r?`n"
        $linesScanned += $lines.Count
        $filesScanned += 1
        $dateHits = 0
        $contentLines = New-Object System.Collections.Generic.List[string]
        $contentLineNumbers = New-Object System.Collections.Generic.List[int]
        $contentFences = New-Object System.Collections.Generic.List[string]
        for ($j = 0; $j -lt $lines.Count; $j++) {
            $candidate = $lines[$j]
            if ($contentFences.Count -eq 0) {
                $trimmed = $candidate.TrimStart()
                if ($trimmed.StartsWith('```')) { $contentFences.Add('```') }
                elseif ($trimmed.StartsWith('~~~')) { $contentFences.Add('~~~') }
                if ($contentFences.Count -gt 0) { continue }
            } elseif ($candidate.TrimStart().StartsWith($contentFences[$contentFences.Count - 1])) {
                $contentFences.RemoveAt($contentFences.Count - 1)
                continue
            }
            if ($contentFences.Count -eq 0) {
                $contentLines.Add($candidate)
                $contentLineNumbers.Add($j + 1)
            }
        }
        for ($i = 0; $i -lt $contentLines.Count; $i++) {
            $line = $contentLines[$i]
            $realLineNumber = $contentLineNumbers[$i]
            if (-not $line) { continue }

            $isHeader = ($i -lt $headerLines)
            $isTable = $line.TrimStart().StartsWith('|')
            $hasDate = $false
            if ($line -match '\d') {
                $dateMatches = [regex]::Matches($line, $reAnyDate, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                $hasDate = $dateMatches.Count -gt 0
                if ($hasDate) { $dateHits += $dateMatches.Count }
            }

            if ($cat.CheckBadWords -and $line -match $reBadWords) {
                [void]$issues.Add([pscustomobject]@{
                        Category = $cat.Name; File = $rel; Line = $realLineNumber; Rule = 'badword'
                        Message  = '出现历史叙述词'
                        Detail   = ($line.Trim() -replace '\s+', ' ')
                    })
                continue
            }

            $allowTodoFile = $false
            foreach ($allowTodoPattern in $allowTodoFiles) {
                if ($rel -like $allowTodoPattern) { $allowTodoFile = $true; break }
            }
            if ($todoSeverity -ne 'off' -and -not $allowTodoFile -and ($line -match $reTodo)) {
                $todoWord = $matches[0]
                $todoItem = [pscustomobject]@{
                    Category = $cat.Name; File = $rel; Line = $realLineNumber; Rule = 'todo-residue'
                    Message  = '正文里残留待办标记'
                    Detail   = "「$todoWord」仍留在正文；应完成、删除或移到 TODO.md"
                }
                if ($todoSeverity -eq 'error') { [void]$issues.Add($todoItem) } else { [void]$warnings.Add([pscustomobject]@{ File = $rel; Line = $realLineNumber; Rule = 'todo-residue'; Detail = $todoItem.Detail }) }
            }

            if ($staleSeverity -ne 'off') {
                foreach ($referenceMatch in [regex]::Matches($line, $reStaleReference)) {
                    if ($referenceMatch.Groups[1].Success) { continue }
                    $prefix = $line.Substring(0, $referenceMatch.Index)
                    if ($prefix -match '(?i)(?:https?://|[<>*/](?:[^`)]*)$)') { continue }
                    if ($prefix -match '[A-Za-z]:$') { continue }
                    if ($referenceMatch.Value -match '[<>*]') { continue }
                    if ($referenceMatch.Value -match $reStalePlaceholder) { continue }
                    if ($referenceMatch.Value -match '(?i)https?://') { continue }
                    $reference = $referenceMatch.Value
                    $resolved = Resolve-RepoReference $rel $reference
                    if ($resolved.State -eq 'outside' -or $resolved.State -eq 'invalid') {
                        Add-ReferenceSkip "stale-reference-$($resolved.State)"
                        continue
                    }
                    $referenceFirstSegment = ($resolved.RepoRelative -split '/', 2)[0]
                    if (-not $topLevelNames.ContainsKey($referenceFirstSegment)) {
                        Add-ReferenceSkip 'stale-reference-outside-top-level'
                        continue
                    }
                    if ($resolved.State -eq 'missing') {
                        [void]$issues.Add([pscustomobject]@{
                                Category = $cat.Name; File = $rel; Line = $realLineNumber; Rule = 'stale-reference'
                                Message  = '引用的路径不存在'
                                Detail   = "「$($resolved.RepoRelative)」不存在；改成实际文件，或删除这条引用"
                            })
                    }
                }
                foreach ($referenceMatch in [regex]::Matches($line, $reStaleLineReference)) {
                    $reference = $referenceMatch.Value
                    $referencePath = $reference.Substring(0, $reference.LastIndexOf(':'))
                    if ($referencePath -match $reStalePlaceholder) { continue }
                    $resolved = Resolve-RepoReference $rel $referencePath
                    if ($resolved.State -eq 'outside' -or $resolved.State -eq 'invalid') {
                        Add-ReferenceSkip "stale-reference-$($resolved.State)"
                        continue
                    }
                    $referenceFirstSegment = ($resolved.RepoRelative -split '/', 2)[0]
                    if (-not $topLevelNames.ContainsKey($referenceFirstSegment)) {
                        Add-ReferenceSkip 'stale-reference-outside-top-level'
                        continue
                    }
                    if ($resolved.State -eq 'missing') {
                        [void]$issues.Add([pscustomobject]@{
                                Category = $cat.Name; File = $rel; Line = $realLineNumber; Rule = 'stale-reference'
                                Message  = '引用的路径不存在'
                                Detail   = "「$($resolved.RepoRelative):$($referenceMatch.Groups[1].Value)」不存在；改成实际文件，或删除这条引用"
                            })
                        continue
                    }
                    try {
                        $referencedLines = @([IO.File]::ReadAllLines($resolved.Target, [Text.Encoding]::UTF8))
                    } catch {
                        Add-ReferenceSkip 'stale-reference-unreadable'
                        continue
                    }
                    $referencedLine = [int]$referenceMatch.Groups[1].Value
                    if ($referencedLine -gt $referencedLines.Count) {
                        [void]$issues.Add([pscustomobject]@{
                                Category = $cat.Name; File = $rel; Line = $realLineNumber; Rule = 'stale-reference'
                                Message  = '引用的行号超出文件范围'
                                Detail   = "「$($resolved.RepoRelative):$referencedLine」超过实际 $($referencedLines.Count) 行；改成存在的行号，或去掉行号"
                            })
                    }
                }
            }

            $allowed = $false
            $styleExempt = $false
            $hasDateSeparator = $hasDate -and ($line.Contains('/') -or $line.Contains('.'))
            if ($dateStyle -ne 'off' -and $cat.CheckDateStyle -and $hasDateSeparator) {
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
                            Category = $cat.Name; File = $rel; Line = $realLineNumber; Rule = 'date-style'
                            Message  = '日期写法需要统一'
                            Detail   = $detail
                        }
                        if ($dateStyle -eq 'error') {
                            [void]$issues.Add($item)
                        } else {
                            [void]$warnings.Add([pscustomobject]@{
                                    File = $rel; Line = $realLineNumber; Rule = 'date-style'
                                    Detail = $detail
                                })
                        }
                    }
                }
            }

            if ($claimSeverity -ne 'off' -and $cat.DatePolicy -eq 'sourced' -and ($line -match $reClaim)) {
                $claim = $matches[0]
                $nextIndex = $realLineNumber
                $nextLine = if ($nextIndex -lt $lines.Count) { $lines[$nextIndex] } else { $null }
                if (-not (Test-ClaimEvidence $line $nextLine $lines $nextIndex)) {
                    $claimDetail = "这条声称「$claim」，但没有命令输出 / 文件:行 / commit 作为证据"
                    $claimFix = "把可复现命令及其输出、来源文件:行或 commit hash 加到这一行或紧邻下一行"
                    if ($claimSeverity -eq 'error') {
                        [void]$issues.Add([pscustomobject]@{
                                Category = $cat.Name; File = $rel; Line = $realLineNumber; Rule = 'claim-unsupported'
                                Message  = '完成性表述缺少证据锚'
                                Detail   = $claimDetail
                            })
                    } else {
                        [void]$warnings.Add([pscustomobject]@{ File = $rel; Line = $realLineNumber; Rule = 'claim-unsupported'; Detail = $claimDetail })
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
                        Category = $cat.Name; File = $rel; Line = $realLineNumber; Rule = 'date-nosource'
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
    $factFindings = New-Object System.Collections.ArrayList
    foreach ($i in $issues) {
        $kind = Get-FindingKind $i.Rule
        $severity = 'error'
        if ($blockOn -eq 'fact' -and $kind -eq 'heuristic') { $severity = 'warn' }
        [void]$factFindings.Add([ordered]@{
            id       = (Get-FindingId $i.File $i.Rule $i.Detail)
            kind     = $kind
            rule     = $i.Rule
            severity = $severity
            category = $i.Category
            file     = $i.File
            line     = [int]$i.Line
            message  = $i.Message
            detail   = $i.Detail
            fix      = (Get-FindingFix $i.Rule $i.Detail)
            verify   = (Get-FindingVerify $i.Rule $i.File ([int]$i.Line) $i.Detail)
        })
    }
    foreach ($w in $warnings) {
        [void]$factFindings.Add([ordered]@{
            id       = (Get-FindingId $w.File $w.Rule $w.Detail)
            kind     = (Get-FindingKind $w.Rule)
            rule     = $w.Rule
            severity = 'warn'
            category = (Get-Category $w.File).Name
            file     = $w.File
            line     = [int]$w.Line
            message  = $w.Rule
            detail   = $w.Detail
            fix      = (Get-FindingFix $w.Rule $w.Detail)
            verify   = (Get-FindingVerify $w.Rule $w.File ([int]$w.Line) $w.Detail)
        })
    }
    $factFindings = @($factFindings | Sort-Object file, line, rule, id)
    $factTotals = [ordered]@{
        fact      = @($factFindings | Where-Object { $_.kind -eq 'fact' }).Count
        heuristic = @($factFindings | Where-Object { $_.kind -eq 'heuristic' }).Count
        by_severity = [ordered]@{
            error = @($factFindings | Where-Object { $_.severity -eq 'error' }).Count
            warn  = @($factFindings | Where-Object { $_.severity -eq 'warn' }).Count
        }
    }
    $baselineInfo = $null
    if ($Baseline) {
        if (-not (Test-Path -LiteralPath $Baseline)) { Fail "找不到基线事实包：$Baseline" }
        try { $baselineDoc = Get-Content -LiteralPath $Baseline -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Fail "基线事实包解析失败：$Baseline — $($_.Exception.Message)" }
        $baselineIds = @($baselineDoc.findings | ForEach-Object { $_.id })
        $currentIds = @($factFindings | ForEach-Object { $_.id })
        $added = @($currentIds | Where-Object { $baselineIds -notcontains $_ })
        $fixed = @($baselineIds | Where-Object { $currentIds -notcontains $_ })
        $baselineInfo = [ordered]@{
            path      = $Baseline
            added     = $added
            fixed     = $fixed
            remaining = $currentIds.Count
        }
    }
    if ($FactPack) {
        $rulesRun = @('badword', 'date-nosource', 'date-style', 'date-density', 'untracked', 'no-category', 'missing-on-disk', 'encoding-suspect', 'claim-unsupported', 'todo-residue', 'stale-reference') | Sort-Object
        $payload = [ordered]@{
            schema_version = 1
            tool           = 'audit-docs'
            repo           = $repo
            config         = $configPath
            rules          = $rulesFile
            coverage       = [ordered]@{
                files_total   = $filesTotal
                files_scanned = $filesScanned
                files_skipped = @($filesSkipped | Sort-Object path, reason)
                lines_scanned = $linesScanned
                categories    = $stats
                rules_run     = $rulesRun
            }
            findings = $factFindings
            totals   = $factTotals
        }
        if ($baselineInfo) { $payload['baseline'] = $baselineInfo }
        $factDir = Split-Path -Parent $FactPack
        if ($factDir -and -not (Test-Path -LiteralPath $factDir)) { New-Item -ItemType Directory -Force -Path $factDir | Out-Null }
        $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $FactPack -Encoding UTF8
    }

    $blockingIssues = if ($blockOn -eq 'fact') {
        @($issues | Where-Object { (Get-FindingKind $_.Rule) -eq 'fact' })
    } else {
        @($issues)
    }
    $exitCode = if ($blockingIssues.Count -eq 0) { 0 } else { 1 }

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

    if ($FailOnNew -and $Baseline) {
        if ($baselineInfo -and $baselineInfo.added.Count -gt 0) { exit 1 }
        if ($baselineInfo) { exit 0 }
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

    if ($blockingIssues.Count -eq 0) {
        Write-Host "  OK  分类与日期规则均合规" -ForegroundColor Green
        Write-Host ""
        if ($Baseline -and $baselineInfo) {
            Write-Host "  基线：新增 $($baselineInfo.added.Count)，修复 $($baselineInfo.fixed.Count)，现存 $($baselineInfo.remaining)" -ForegroundColor Cyan
        }
        exit 0
    }

    Write-Host "  发现 $($blockingIssues.Count) 处不合规：" -ForegroundColor Yellow
    Write-Host ""
    $blockingIssues | Group-Object File | ForEach-Object {
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
    if ($Baseline -and $baselineInfo) {
        Write-Host "  基线：新增 $($baselineInfo.added.Count)，修复 $($baselineInfo.fixed.Count)，现存 $($baselineInfo.remaining)" -ForegroundColor Cyan
    }
    exit 1
}
finally { Pop-Location }

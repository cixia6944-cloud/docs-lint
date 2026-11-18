<#
.SYNOPSIS
    凭据自查：扫描 git 跟踪的明文文件，报告疑似口令/密钥的位置。

.DESCRIPTION
    这是一个只报告、不阻断的自查工具。输出只给「规则 + 文件 + 行号」，
    绝不打印命中的原文 —— 免得自查本身成为泄漏渠道。

    默认扫描工作区里 git 已跟踪的文件；-Staged 只扫暂存区。
    不扫描二进制文件；.gitignore 排除的文件需要你先决定要不要纳入版本库。

    规则是内置的正则，覆盖常见形态：私钥块、JSON 里的 privateKey、
    token=、UUID、超长 base64、password/secret/api_key 字段、中文「密码/口令」标签。
    它是启发式扫描，不是秘密检测的完整方案；误报用 -Exclude 处理。

.PARAMETER Repo
    仓库根目录，默认本脚本所在仓库（tools/ 的上一级）。

.PARAMETER Staged
    只扫暂存区（pre-commit 钩子用）。

.PARAMETER Exclude
    额外跳过的文件 glob（相对仓库根目录，大小写不敏感），可以传多个。
    工具自身和 tools/selftest.ps1 永远跳过：后者装着自测用的假凭据，
    不排除就会天天自报。

.PARAMETER Quiet
    只打印结论和命中位置，不打印处理建议。

.EXAMPLE
    pwsh -NoProfile -File tools/check-secrets.ps1 -Repo .
    pwsh -NoProfile -File tools/check-secrets.ps1 -Staged
    pwsh -NoProfile -File tools/check-secrets.ps1 -Exclude 'docs/security.md','fixtures/*'

.NOTES
    退出码：0 未发现；1 发现疑似凭据；2 不是 git 仓库 / 找不到 git。
#>
param(
    [string]$Repo,
    [switch]$Staged,
    [string[]]$Exclude,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

try {
    if ([Console]::IsOutputRedirected) {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
} catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$root = if ($Repo) { $Repo } else { $toolRoot }
if (Test-Path -LiteralPath $root) {
    try { $root = (Resolve-Path -LiteralPath $root).Path } catch { }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "[×] 找不到 git，无法确定扫描范围" -ForegroundColor Red
    exit 2
}
$git = (Get-Command git -ErrorAction Stop).Source
if (-not (Test-Path -LiteralPath $root)) {
    Write-Host "[×] 仓库目录不存在：$root" -ForegroundColor Red
    exit 2
}

Push-Location $root
try {
    if (-not (Test-Path -LiteralPath '.git')) {
        Write-Host "[×] 不是 git 仓库：$root" -ForegroundColor Red
        Write-Host "    没有 .git 就无法区分已跟踪/未跟踪，给不出可信的扫描范围。" -ForegroundColor Yellow
        exit 2
    }

    $skip = @('tools/check-secrets.ps1', 'tools/selftest.ps1')
    $excludePatterns = @($Exclude | Where-Object { $_ } | ForEach-Object { [string]$_ })

    $rules = @(
        @{ n = 'PRIVATE-KEY 块'; r = '-----BEGIN [A-Z ]*PRIVATE KEY-----' }
        @{ n = 'privateKey 赋值'; r = '"([Pp]rivateKey)"\s*:\s*"[^"<\s]{8,}"' }
        @{ n = 'token= 明文'; r = '(?i)\btoken=[A-Za-z0-9_\-\.]{6,}' }
        @{ n = 'UUID / 设备 id'; r = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b' }
        @{ n = '超长 base64'; r = '(?<![A-Za-z0-9+/=])[A-Za-z0-9+/]{60,}={0,2}(?![A-Za-z0-9+/=])' }
        @{ n = '常见口令字段'; r = '(?i)\b(password|passwd|secret|api[_-]?key)\b\s*[:=]\s*["'']?[^\s"''<]{6,}' }
        # 中文标签（密码 / 口令）+ 反引号值。只认英文关键字会漏掉中文文档里最常见的写法。
        # 值的形状必须像口令才报：字母 + 数字混合、≥8 位、不含点 ——
        # 否则「密码管理器（`example.com`）」这类引用会误报。
        @{ n = '中文口令字段'; r = '(?:密码|口令)[^\n\x60]{0,6}\x60(?=[^\x60\n]*\d)(?=[^\x60\n]*[A-Za-z])[A-Za-z0-9!@#$%^&*_+=\-]{8,}\x60' }
    )

    function Get-RuleHits {
        param([string]$Text)
        $out = New-Object System.Collections.ArrayList
        if (-not $Text) { return $out }
        $lines = $Text -split "`r?`n"
        foreach ($rule in $rules) {
            for ($i = 0; $i -lt $lines.Length; $i++) {
                $line = $lines[$i]
                if ($line -match '<REDACTED>' -or $line -match 'example|模板|占位') { continue }
                $found = $false
                foreach ($m in [regex]::Matches($line, $rule.r)) {
                    $v = $m.Value
                    # 纯十六进制（MD5/SHA1/SHA256 指纹）不是秘密，文档里常用来核对身份
                    if ($v -match '^[0-9a-fA-F]{32,64}$') { continue }
                    # 纯数字 ID
                    if ($v -match '^\d+$') { continue }
                    $found = $true
                }
                if ($found) { [void]$out.Add([pscustomobject]@{ Rule = $rule.n; Line = ($i + 1) }) }
            }
        }
        return $out
    }

    # git 吐 UTF-8；临时切编码，防止 gb2312 宿主把中文文件名解成乱码后 Test-Path 落空。
    function Get-GitText {
        param([string[]]$ArgList)
        $oldEnc = try { [Console]::OutputEncoding } catch { $null }
        try {
            try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
            $out = & git @ArgList 2>$null
            if ($LASTEXITCODE -ne 0) { throw "git $($ArgList -join ' ') 执行失败（exit $LASTEXITCODE）" }
            return ((@($out) | ForEach-Object { "$_" }) -join "`n")
        } finally {
            if ($oldEnc) { try { [Console]::OutputEncoding = $oldEnc } catch { } }
        }
    }

    function Get-GitLines {
        param([string[]]$ArgList)
        $t = Get-GitText -ArgList $ArgList
        if (-not $t) { return @() }
        return @($t -split "`r?`n" | Where-Object { $_ })
    }

    function Test-Excluded([string]$rel) {
        $norm = $rel -replace '\\', '/'
        if ($skip -contains $norm) { return $true }
        foreach ($p in $excludePatterns) {
            if ($norm -like $p) { return $true }
        }
        return $false
    }

    # core.quotepath=false：不加这个，中文名会被 git 吐成 "\344\270\255" 这种转义串
    try {
        $files = if ($Staged) {
            Get-GitLines @('-c', 'core.quotepath=false', 'diff', '--cached', '--name-only', '--diff-filter=ACMR')
        } else {
            Get-GitLines @('-c', 'core.quotepath=false', 'ls-files')
        }
    } catch {
        Write-Host "[×] 读取 git 文件列表失败：$($_.Exception.Message)" -ForegroundColor Red
        exit 2
    }
    $fileTotal = @($files).Count
    $files = @($files | Where-Object { $_ -and (Test-Path -LiteralPath $_) })

    $hits = New-Object System.Collections.ArrayList
    $scanned = 0
    $gb18030Count = 0
    $gb18030Files = New-Object System.Collections.ArrayList
    $encodingSuspects = New-Object System.Collections.ArrayList
    foreach ($f in $files) {
        $norm = $f -replace '\\', '/'
        if (Test-Excluded $norm) { continue }
        if ($norm -match '\.(png|jpg|jpeg|gif|webp|ico|zip|gz|tgz|7z|pdf|exe|dll)$') { continue }
        if ($Staged) {
            $tempFile = Join-Path ([IO.Path]::GetTempPath()) ("docs-lint-staged-" + [Guid]::NewGuid().ToString('N') + ".bin")
            try {
                $processInfo = New-Object System.Diagnostics.ProcessStartInfo
                $processInfo.FileName = $git
                $processInfo.Arguments = 'show ":0:' + ($f -replace '"', '\"') + '"'
                $processInfo.WorkingDirectory = $root
                $processInfo.RedirectStandardOutput = $true
                $processInfo.UseShellExecute = $false
                $stream = [IO.File]::Create($tempFile)
                try {
                    $process = [System.Diagnostics.Process]::Start($processInfo)
                    $process.StandardOutput.BaseStream.CopyTo($stream)
                    $process.WaitForExit()
                    if ($process.ExitCode -ne 0) { throw "git show :$f 失败，exit=$($process.ExitCode)" }
                } finally {
                    if ($stream) { $stream.Dispose() }
                    if ($process) { $process.Dispose() }
                }
                $bytes = [IO.File]::ReadAllBytes($tempFile)
            } catch {
                continue
            } finally {
                Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
            }
        } else {
            try { $bytes = [IO.File]::ReadAllBytes((Join-Path $root $f)) } catch { continue }
        }
        $text = $null
        try {
            $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
        } catch {
            try {
                $gb18030 = [Text.Encoding]::GetEncoding(936)
                $text = $gb18030.GetString($bytes)
                $gb18030Count++
                [void]$gb18030Files.Add($norm)
            } catch {
                [void]$encodingSuspects.Add($norm)
                continue
            }
        }
        if (-not $text) { continue }
        # 二进制块按文本判没有意义（超长 base64 那条会乱报）
        if ($text.IndexOf([char]0) -ge 0) { continue }
        $scanned++
        foreach ($h in @(Get-RuleHits -Text $text)) {
            [void]$hits.Add([pscustomobject]@{ Rule = $h.Rule; File = $norm; Line = $h.Line })
        }
    }

    # 扫了多少、跳过了什么，必须写进结论里。
    # 「零命中」不交代范围，是这个工具最贵的那种谎。
    $scope = if ($Staged) { "扫描 $scanned 个暂存文件" } else { "扫描 $scanned 个已跟踪文件" }
    $missing = $fileTotal - $files.Count
    if ($gb18030Count -gt 0) { $scope = $scope + "，其中 $gb18030Count 个不是 UTF-8，已按 GB18030 解码" }
    if ($encodingSuspects.Count -gt 0) { $scope = $scope + "，$($encodingSuspects.Count) 个编码可疑（不参与内容扫描）" }
    if ($missing -gt 0) { $scope = $scope + "（git 记录 $fileTotal 个，$missing 个在磁盘上不存在）" }
    $skipped = @($files).Count - $scanned
    if ($skipped -gt 0) { $scope = $scope + "，跳过 $skipped 个（工具自身/排除项/二进制/读不到）" }

    if ($hits.Count -eq 0) {
        if ($gb18030Count -gt 0) {
            Write-Host "! 未发现疑似凭据，但有文件编码可疑（$scope）" -ForegroundColor Yellow
            $gb18030Files | ForEach-Object { Write-Host ("  encoding-suspect  $_（已按 GB18030 解码并扫描）") -ForegroundColor DarkYellow }
            exit 1
        }
        if ($encodingSuspects.Count -gt 0) {
            Write-Host "× 文件编码无法可靠解码（$scope）" -ForegroundColor Red
            $encodingSuspects | ForEach-Object { Write-Host ("  encoding-suspect  $_") -ForegroundColor DarkYellow }
            exit 1
        }
        Write-Host "✓ 未发现疑似凭据（$scope）" -ForegroundColor Green
        exit 0
    }

    Write-Host ""
    Write-Host "发现 $($hits.Count) 处疑似凭据（只报告，不阻止任何操作）：" -ForegroundColor Yellow
    Write-Host "  $scope" -ForegroundColor DarkGray
    Write-Host ""
    $hits | Group-Object File | ForEach-Object {
        Write-Host ("  " + $_.Name) -ForegroundColor Yellow
        $_.Group | ForEach-Object { Write-Host ("      L{0,-5} {1}" -f $_.Line, $_.Rule) -ForegroundColor DarkGray }
    }
    if ($encodingSuspects.Count -gt 0) {
        Write-Host ""
        Write-Host "文件编码无法可靠解码：" -ForegroundColor Yellow
        $encodingSuspects | ForEach-Object { Write-Host ("  encoding-suspect  $_") -ForegroundColor DarkYellow }
    }
    if ($gb18030Count -gt 0) {
        Write-Host ""
        Write-Host "文件编码可疑，但已按 GB18030 解码并完成扫描：" -ForegroundColor Yellow
        $gb18030Files | ForEach-Object { Write-Host ("  encoding-suspect  $_") -ForegroundColor DarkYellow }
    }
    if (-not $Quiet) {
        Write-Host ""
        Write-Host "处理建议：" -ForegroundColor Cyan
        Write-Host "  1) 换成 <REDACTED>，真值挪到库外"
        Write-Host "  2) 或只挑不含凭据的片段对外"
        Write-Host "  3) 确认是误报 → 用 -Exclude 加白名单"
    }
    Write-Host ""
    exit 1
}
finally { Pop-Location }

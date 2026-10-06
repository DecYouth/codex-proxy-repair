#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$editor = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts\Set-CodexProxyEnv.ps1'))
$root = Join-Path $PSScriptRoot ('fixtures-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$utf8 = New-Object Text.UTF8Encoding($false)
$passed = 0
$skipped = New-Object 'Collections.Generic.List[string]'
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
    $script:passed++
}
function Fixture([string]$Name) {
    $path = Join-Path $root $Name
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}
function Invoke-Edit([hashtable]$Options) {
    $raw = & $editor @Options
    return ($raw | ConvertFrom-Json)
}
function Must-Fail([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert $failed $Message
}
function Same-Bytes([byte[]]$Left, [byte[]]$Right) {
    return [Convert]::ToBase64String($Left) -ceq [Convert]::ToBase64String($Right)
}

$proxy = 'http://127.0.0.1:34567'
$loopbackFixture = Fixture 'other-loopback'
$loopbackPreview = Invoke-Edit @{ CodexHome = $loopbackFixture; ProxyUrl = 'http://127.0.0.2:34567' }
Assert ($loopbackPreview.ProxyUrl -eq 'http://127.0.0.2:34567') 'other 127/8 loopback supported'
$loopbackApplied = Invoke-Edit @{ CodexHome = $loopbackFixture; ProxyUrl = 'http://127.0.0.2:34567'; Apply = $true; ExpectedHash = $loopbackPreview.ExpectedHash }
Assert ([IO.File]::ReadAllText((Join-Path $loopbackFixture '.env')).Contains('HTTP_PROXY=http://127.0.0.2:34567')) 'other loopback applies without changing address'
foreach ($invalidLoopback in @('http://127.0.0.999:34567','http://127.0.256.1:34567','http://128.0.0.1:34567')) {
    Must-Fail { Invoke-Edit @{ CodexHome = $loopbackFixture; ProxyUrl = $invalidLoopback } } 'invalid or nonloopback IPv4 refused'
}
# New file: preview has no side effects; expected hash required; safe removal.
$missing = Fixture 'missing'
$preview = Invoke-Edit @{ CodexHome = $missing; ProxyUrl = $proxy }
Assert ($preview.Mode -eq 'Preview' -and $preview.ExpectedHash -eq 'MISSING') 'missing preview'
Assert (-not (Test-Path -LiteralPath (Join-Path $missing '.env'))) 'preview writes nothing'
Assert (@(Get-ChildItem -LiteralPath $missing -Force).Count -eq 0) 'preview creates no lock or receipt'
Must-Fail { Invoke-Edit @{ CodexHome = $missing; ProxyUrl = $proxy; Apply = $true } } 'apply needs expected hash'
$applied = Invoke-Edit @{ CodexHome = $missing; ProxyUrl = $proxy; Apply = $true; ExpectedHash = $preview.ExpectedHash }
Assert ($applied.Mode -eq 'Applied' -and $null -eq $applied.BackupPath) 'new apply'
$text = [IO.File]::ReadAllText((Join-Path $missing '.env'))
foreach ($key in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'WS_PROXY', 'WSS_PROXY')) { Assert ($text.Contains($key + '=' + $proxy)) ('new ' + $key) }
Assert ($text.Contains('NO_PROXY=localhost,127.0.0.1,::1')) 'safe default bypass'
$restorePreview = Invoke-Edit @{ RestoreReceipt = $applied.ReceiptPath }
Assert ($restorePreview.Mode -eq 'RestorePreview' -and (Test-Path -LiteralPath (Join-Path $missing '.env'))) 'rollback preview is read only'
$restored = Invoke-Edit @{ RestoreReceipt = $applied.ReceiptPath; Apply = $true }
Assert ($restored.Mode -eq 'Restored' -and -not (Test-Path -LiteralPath (Join-Path $missing '.env'))) 'rollback removes only newly created env'

# BOM/CRLF, comments/export/quotes, duplicates and secret preservation.
$existing = Fixture 'existing'
$envFile = Join-Path $existing '.env'
$originalText = "# 留存注释`r`nSECRET=do-not-print-this-test-secret`r`nexport no_proxy='localhost,example.test' # keep bypass`r`nHTTP_PROXY=`"http://old.invalid:80`" # first`r`nexport http_proxy='http://second.invalid:81' # duplicate`r`nHTTPS_PROXY=http://old.invalid:80`r`nUNRELATED = value`r`n"
$original = [byte[]](@(239, 187, 191) + $utf8.GetBytes($originalText))
[IO.File]::WriteAllBytes($envFile, $original)
$p = Invoke-Edit @{ CodexHome = $existing; ProxyUrl = $proxy }
$raw = & $editor -CodexHome $existing -ProxyUrl $proxy -Apply -ExpectedHash $p.ExpectedHash
Assert (-not ($raw -join '').Contains('do-not-print-this-test-secret')) 'output redacts old secret'
$a = $raw | ConvertFrom-Json
Assert (Same-Bytes ([IO.File]::ReadAllBytes($a.BackupPath)) $original) 'backup byte equality'
$updated = [IO.File]::ReadAllBytes($envFile)
Assert ($updated[0] -eq 239 -and $updated[1] -eq 187 -and $updated[2] -eq 191) 'BOM preservation'
$updatedText = $utf8.GetString($updated, 3, $updated.Length - 3)
Assert ($updatedText.Contains("export no_proxy='localhost,example.test' # keep bypass`r`n")) 'NO_PROXY exact preservation'
Assert ($updatedText.Contains("SECRET=do-not-print-this-test-secret`r`n")) 'unrelated secret preservation'
Assert ($updatedText.Contains("HTTP_PROXY=`"$proxy`" # first`r`n")) 'quoted comment preservation'
Assert ($updatedText.Contains("export http_proxy='$proxy' # duplicate`r`n")) 'duplicate case export preservation'
Assert ($updatedText -notmatch '(?<!\r)\n') 'CRLF preserved'
Assert ([regex]::Matches($updatedText, '(?im)^(?:export )?no_proxy=').Count -eq 1) 'no bypass duplicate'
Assert (-not [IO.File]::ReadAllText($a.ReceiptPath).Contains('do-not-print-this-test-secret')) 'receipt excludes secret'
$beforeFiles = @(Get-ChildItem -LiteralPath $existing -Force).Count
$p2 = Invoke-Edit @{ CodexHome = $existing; ProxyUrl = $proxy }
$a2 = Invoke-Edit @{ CodexHome = $existing; ProxyUrl = $proxy; Apply = $true; ExpectedHash = $p2.ExpectedHash }
Assert ($a2.Mode -eq 'NoChange' -and -not $a2.HasChanges) 'idempotency'
Assert (@(Get-ChildItem -LiteralPath $existing -Force).Count -eq $beforeFiles) 'idempotency creates no backup receipt or lock'
[void](Invoke-Edit @{ RestoreReceipt = $a.ReceiptPath; Apply = $true })
Assert (Same-Bytes ([IO.File]::ReadAllBytes($envFile)) $original) 'existing rollback exact bytes'

# Preserve LF, absent final newline, and arbitrary non-proxy lines.
$lf = Fixture 'lf'
$lfFile = Join-Path $lf '.env'
$allKeys = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'WS_PROXY', 'WSS_PROXY') | ForEach-Object { $_ + '=old' }
$lfOriginal = "#first`n" + ($allKeys -join "`n") + "`nNO_PROXY=keep`nAPI_KEY=secret-without-newline"
[IO.File]::WriteAllText($lfFile, $lfOriginal, $utf8)
$lp = Invoke-Edit @{ CodexHome = $lf; ProxyUrl = 'http://localhost:1234/' }
[void](Invoke-Edit @{ CodexHome = $lf; ProxyUrl = 'http://localhost:1234/'; Apply = $true; ExpectedHash = $lp.ExpectedHash })
$lt = [IO.File]::ReadAllText($lfFile)
Assert (-not $lt.Contains("`r") -and $lt.EndsWith('API_KEY=secret-without-newline')) 'LF and no terminal newline preserved'

# Hash mismatches, concurrent/after repair edits, and invalid dotenv input.
$stale = Fixture 'stale'
$sp = Invoke-Edit @{ CodexHome = $stale; ProxyUrl = $proxy }
[IO.File]::WriteAllText((Join-Path $stale '.env'), 'SECRET=keep', $utf8)
Must-Fail { Invoke-Edit @{ CodexHome = $stale; ProxyUrl = $proxy; Apply = $true; ExpectedHash = $sp.ExpectedHash } } 'missing marker race refused'
Assert ([IO.File]::ReadAllText((Join-Path $stale '.env')) -eq 'SECRET=keep') 'race retained other file'
$sp2 = Invoke-Edit @{ CodexHome = $stale; ProxyUrl = $proxy }
[IO.File]::AppendAllText((Join-Path $stale '.env'), 'changed', $utf8)
Must-Fail { Invoke-Edit @{ CodexHome = $stale; ProxyUrl = $proxy; Apply = $true; ExpectedHash = $sp2.ExpectedHash } } 'stale existing hash refused'
$modified = Fixture 'modified'
$ma = Invoke-Edit @{ CodexHome = $modified; ProxyUrl = $proxy; Apply = $true; ExpectedHash = 'MISSING' }
[IO.File]::AppendAllText((Join-Path $modified '.env'), '# user later edit', $utf8)
$modifiedBytes = [IO.File]::ReadAllBytes((Join-Path $modified '.env'))
Must-Fail { Invoke-Edit @{ RestoreReceipt = $ma.ReceiptPath; Apply = $true } } 'rollback refuses later changes'
Assert (Same-Bytes ([IO.File]::ReadAllBytes((Join-Path $modified '.env'))) $modifiedBytes) 'later changes remain exact'
$invalid = Fixture 'invalid'
foreach ($url in @('https://127.0.0.1:123', 'socks5://127.0.0.1:123', 'http://example.com:123', 'http://127.0.0.1:0', 'http://127.0.0.1:65536', 'http://user:pass@127.0.0.1:123', 'http://127.0.0.1:123?x=1', 'http://127.0.0.1:123/#x', 'http://127.0.0.1:123/path')) {
    Must-Fail { Invoke-Edit @{ CodexHome = $invalid; ProxyUrl = $url } } ('invalid URL: ' + $url)
}
Assert ((Invoke-Edit @{ CodexHome = $invalid; ProxyUrl = 'http://[::1]:1234' }).ProxyUrl -eq 'http://[::1]:1234') 'IPv6 loopback accepted'
$invalidFile = Join-Path $invalid '.env'
foreach ($badText in @('HTTP_PROXY="unterminated', 'HTTP_PROXY: 123', 'export HTTP_PROXY', 'declare -x HTTP_PROXY=old', 'HTTP_PROXY=old\', 'HTTP_PROXY=old extra')) {
    [IO.File]::WriteAllText($invalidFile, $badText, $utf8)
    Must-Fail { Invoke-Edit @{ CodexHome = $invalid; ProxyUrl = $proxy } } 'ambiguous proxy syntax refused'
    Assert ([IO.File]::ReadAllText($invalidFile) -ceq $badText) 'invalid dotenv retained'
}
[IO.File]::WriteAllBytes($invalidFile, [byte[]]@(255, 254, 97, 0))
Must-Fail { Invoke-Edit @{ CodexHome = $invalid; ProxyUrl = $proxy } } 'invalid UTF8 refused'
$multiline = "SECRET=`"line`nHTTP_PROXY=not_a_setting`nend`""
[IO.File]::WriteAllText($invalidFile, $multiline, $utf8)
Must-Fail { Invoke-Edit @{ CodexHome = $invalid; ProxyUrl = $proxy } } 'multiline unrelated value refused'
Assert ([IO.File]::ReadAllText($invalidFile) -ceq $multiline) 'multiline unrelated content unmodified'
$crMultiline = "# prefix`rSECRET=`"line`rHTTP_PROXY=not_a_setting`rend`""
[IO.File]::WriteAllText($invalidFile, $crMultiline, $utf8)
Must-Fail { Invoke-Edit @{ CodexHome = $invalid; ProxyUrl = $proxy } } 'CR-only multiline unrelated value refused'
Assert ([IO.File]::ReadAllText($invalidFile) -ceq $crMultiline) 'CR-only multiline content unmodified'
[IO.File]::WriteAllBytes($invalidFile, (New-Object byte[] 1048577))
Must-Fail { Invoke-Edit @{ CodexHome = $invalid; ProxyUrl = $proxy } } 'oversized dotenv refused'

# Reparse ancestors must be refused; a directory junction needs no admin rights.
$junction = Join-Path $root 'junction'
try {
    New-Item -ItemType Junction -Path $junction -Target $existing -ErrorAction Stop | Out-Null
    Must-Fail { Invoke-Edit @{ CodexHome = $junction; ProxyUrl = $proxy } } 'reparse ancestor refused'
} catch {
    if (Test-Path -LiteralPath $junction) { throw }
    $skipped.Add('Directory junction creation unavailable in this environment.')
}

[ordered]@{ PassedAssertions = $passed; Skipped = @($skipped); FixtureDirectory = $root; PowerShellVersion = $PSVersionTable.PSVersion.ToString(); Status = 'PASS' } | ConvertTo-Json -Depth 4

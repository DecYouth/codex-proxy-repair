#requires -Version 5.1
<#
.SYNOPSIS
Preview, apply, or roll back a narrowly scoped Codex dotenv proxy change.
.DESCRIPTION
No change is made without -Apply. Apply requires -ExpectedHash from the preview.
Only loopback HTTP proxies are supported. Output is JSON and never includes old
dotenv values. Keep the receipt and backup together beside the changed .env.
#>
[CmdletBinding(DefaultParameterSetName = 'Edit')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Edit')][string]$CodexHome,
    [Parameter(Mandatory = $true, ParameterSetName = 'Edit')][string]$ProxyUrl,
    [Parameter(ParameterSetName = 'Edit')][string]$ExpectedHash,
    [Parameter(Mandatory = $true, ParameterSetName = 'Restore')][string]$RestoreReceipt,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$targetNames = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'WS_PROXY', 'WSS_PROXY')
$strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)

function Get-AbsolutePath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'An absolute path is required.' }
    return [IO.Path]::GetFullPath($Path)
}

function Assert-NoReparse([string]$Path) {
    $part = Get-AbsolutePath $Path
    while ($part) {
        if (Test-Path -LiteralPath $part) {
            $item = Get-Item -LiteralPath $part -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Reparse points and symbolic links are not supported for configuration, backup, or receipt paths.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($part)
        if ($parent -eq $part) { break }
        $part = $parent
    }
}

function Get-Hash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-StreamBytes([IO.Stream]$Stream) {
    if ($Stream.Length -gt 1048576) { throw 'The .env file exceeds the supported 1 MiB size limit.' }
    $Stream.Position = 0
    $buffer = New-Object IO.MemoryStream
    try { $Stream.CopyTo($buffer); return ,$buffer.ToArray() }
    finally { $buffer.Dispose() }
}

function Write-NewFile([string]$Path, [byte[]]$Bytes) {
    Assert-NoReparse $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
}

function Open-OperationLock([string]$Directory) {
    $lockPath = [IO.Path]::Combine($Directory, '.codex-proxy-repair.lock')
    Assert-NoReparse $lockPath
    try {
        return New-Object IO.FileStream($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    } catch { throw 'Could not acquire the repair lock. Another operation may be running, or a stale lock requires inspection.' }
}

function Get-NormalizedProxy([string]$Value) {
    # Deliberately narrow: no credentials, remote hosts, SOCKS, paths, or URI tricks.
    if ($Value -notmatch '^(?i:http)://(?<host>127(?:\.[0-9]{1,3}){3}|(?i:localhost)|\[::1\]):(?<port>[0-9]{1,5})/?$') {
        throw 'ProxyUrl must be a loopback HTTP URL with an explicit port; credentials, query strings, and fragments are not allowed.'
    }
    $port = [int]$Matches.port
    $proxyHost = $Matches.host.ToLowerInvariant()
    if ($port -lt 1 -or $port -gt 65535) { throw 'ProxyUrl port must be between 1 and 65535.' }
    if ($proxyHost -ne 'localhost' -and $proxyHost -ne '[::1]') {
        $proxyAddress = $null
        if (-not [Net.IPAddress]::TryParse($proxyHost, [ref]$proxyAddress) -or
            -not [Net.IPAddress]::IsLoopback($proxyAddress)) {
            throw 'ProxyUrl must use a valid loopback address.'
        }
        $proxyHost = $proxyAddress.ToString()
    }
    return ('http://{0}:{1}' -f $proxyHost, $port)
}

function Get-EditedBytes([byte[]]$Bytes, [string]$Url) {
    $hasBom = $Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191
    $offset = 0
    if ($hasBom) { $offset = 3 }
    try { $content = $strictUtf8.GetString($Bytes, $offset, $Bytes.Length - $offset) }
    catch { throw 'The .env file is not valid UTF-8. No change was made.' }
    if ($content.IndexOf([char]0) -ge 0) { throw 'The .env file contains NUL characters; no change was made.' }
    # A line that resembles HTTP_PROXY may actually be inside another variable's
    # multiline quoted value. Refuse those files before interpreting any line.
    foreach ($physicalLine in [regex]::Matches($content, '[^\r\n]+')) {
        $quotedLine = [regex]::Match($physicalLine.Value, '^[ \t]*(?:(?i:export)[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*(?<value>["''].*)$')
        if (-not $quotedLine.Success) { continue }
        $value = $quotedLine.Groups['value'].Value
        if ($value.StartsWith('"')) { $valid = [regex]::IsMatch($value, '^"(?:\\.|[^"\\])*"[ \t]*(?:#.*)?$') }
        else { $valid = [regex]::IsMatch($value, "^'[^']*'[ \t]*(?:#.*)?$") }
        if (-not $valid) { throw 'Multiline or ambiguous quoted dotenv values are not supported; no change was made.' }
    }
    $newlineMatch = [regex]::Match($content, '\r\n|\n|\r')
    $newline = "`r`n"
    if ($newlineMatch.Success) { $newline = $newlineMatch.Value }
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $builder = New-Object Text.StringBuilder
    $noProxyPresent = $false
    $changed = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($lineMatch in [regex]::Matches($content, '([^\r\n]*)(\r\n|\n|\r|$)')) {
        if ($lineMatch.Length -eq 0) { continue }
        $line = $lineMatch.Groups[1].Value
        $ending = $lineMatch.Groups[2].Value
        $assignment = [regex]::Match($line, '^(?<prefix>[ \t]*(?:(?i:export)[ \t]+)?)(?<key>[A-Za-z_][A-Za-z0-9_]*)(?<equals>[ \t]*=[ \t]*)(?<value>.*)$')
        if ($assignment.Success) {
            $key = $assignment.Groups['key'].Value
            if ($key -ieq 'NO_PROXY') { $noProxyPresent = $true }
            if ($targetNames -icontains $key) {
                [void]$seen.Add($key)
                $old = $assignment.Groups['value'].Value
                $parsed = $null
                $quote = ''
                if ($old.StartsWith('"')) {
                    $parsed = [regex]::Match($old, '^"(?:\\.|[^"\\])*"(?<suffix>[ \t]*(?:#.*)?)$')
                    $quote = '"'
                } elseif ($old.StartsWith("'")) {
                    $parsed = [regex]::Match($old, "^'[^']*'(?<suffix>[ \t]*(?:#.*)?)$")
                    $quote = "'"
                } else {
                    $parsed = [regex]::Match($old, '^(?<value>[^ \t#''"]*)(?<suffix>[ \t]*(?:#.*)?)$')
                    if ($parsed.Success -and $parsed.Groups['value'].Value.EndsWith('\')) {
                        throw ('Unsupported multiline syntax for {0}; no change was made.' -f $key.ToUpperInvariant())
                    }
                }
                if (-not $parsed.Success) { throw ('Unsupported dotenv syntax for {0}; no change was made.' -f $key.ToUpperInvariant()) }
                $replacement = $assignment.Groups['prefix'].Value + $key + $assignment.Groups['equals'].Value + $quote + $Url + $quote + $parsed.Groups['suffix'].Value
                if ($line -cne $replacement) { [void]$changed.Add($key.ToUpperInvariant()) }
                $line = $replacement
            }
        } elseif ($line -match '^[ \t]*(?:(?i:export)[ \t]+)?(?i:HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|WS_PROXY|WSS_PROXY|NO_PROXY)\b') {
            throw 'An ambiguous proxy assignment was found; no change was made.'
        } elseif ($line -notmatch '^\s*(#|$)' -and $line -match '(?i)(?:^|[ \t])(?:HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|WS_PROXY|WSS_PROXY|NO_PROXY)[ \t]*=') {
            throw 'An unsupported proxy assignment form was found; no change was made.'
        }
        [void]$builder.Append($line).Append($ending)
    }
    $additions = New-Object 'Collections.Generic.List[string]'
    foreach ($key in $targetNames) {
        if (-not $seen.Contains($key)) { $additions.Add($key + '=' + $Url); [void]$changed.Add($key) }
    }
    if (-not $noProxyPresent) { $additions.Add('NO_PROXY=localhost,127.0.0.1,::1'); [void]$changed.Add('NO_PROXY') }
    if ($additions.Count -gt 0) {
        if ($builder.Length -gt 0 -and $builder[$builder.Length - 1] -ne "`n" -and $builder[$builder.Length - 1] -ne "`r") { [void]$builder.Append($newline) }
        [void]$builder.Append(($additions -join $newline)).Append($newline)
    }
    $encoded = $strictUtf8.GetBytes($builder.ToString())
    if ($hasBom) { $encoded = [byte[]](@(239, 187, 191) + $encoded) }
    return @{ Bytes = $encoded; ChangedKeys = @($changed | Sort-Object); NoProxyPreserved = $noProxyPresent }
}

function Write-Result($Value) { $Value | ConvertTo-Json -Depth 6 }

function Open-DeleteCapableFile([string]$Path) {
    if (-not ('CodexProxyRepair.NativeFile' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace CodexProxyRepair {
  public static class NativeFile {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetFileInformationByHandle(SafeFileHandle file, int infoClass, ref int deleteFile, uint size);
  }
}
'@
    }
    $handle = [CodexProxyRepair.NativeFile]::CreateFile($Path, [uint32]2147549184, 0, [IntPtr]::Zero, 3, 0x80, [IntPtr]::Zero)
    if ($handle.IsInvalid) { $handle.Dispose(); throw 'Could not exclusively open the newly created .env for rollback.' }
    try { return New-Object IO.FileStream($handle, [IO.FileAccess]::Read) }
    catch { $handle.Dispose(); throw }
}

if ($PSCmdlet.ParameterSetName -eq 'Restore') {
    $receiptPath = Get-AbsolutePath $RestoreReceipt
    Assert-NoReparse $receiptPath
    if ([IO.Path]::GetFileName($receiptPath) -notmatch '^\.env\.codex-proxy-repair\.[0-9]{8}T[0-9]{9}Z-[a-f0-9]{32}\.json$') { throw 'Unrecognized receipt filename.' }
    if ((Get-Item -LiteralPath $receiptPath).Length -gt 65536) { throw 'Receipt is too large.' }
    $receipt = [IO.File]::ReadAllText($receiptPath, $strictUtf8) | ConvertFrom-Json
    $directory = [IO.Path]::GetDirectoryName($receiptPath)
    $target = [IO.Path]::Combine($directory, '.env')
    $expectedBackup = [IO.Path]::ChangeExtension($receiptPath, '.bak')
    if ($receipt.SchemaVersion -ne 1 -or $receipt.TargetPath -cne $target -or $receipt.AfterHash -notmatch '^[a-f0-9]{64}$' -or $receipt.ExistedBefore -isnot [bool]) { throw 'Invalid or mismatched receipt.' }
    if ($receipt.ExistedBefore) {
        if ($receipt.BackupPath -cne $expectedBackup -or $receipt.BeforeHash -notmatch '^[a-f0-9]{64}$') { throw 'Invalid backup location in receipt.' }
        Assert-NoReparse $expectedBackup
        if ((Get-Item -LiteralPath $expectedBackup).Length -gt 1048576) { throw 'Backup exceeds the supported 1 MiB size limit.' }
        $original = [IO.File]::ReadAllBytes($expectedBackup)
        if ((Get-Hash $original) -ne $receipt.BeforeHash) { throw 'Backup hash does not match receipt.' }
    } elseif ($receipt.BeforeHash -ne 'MISSING' -or $null -ne $receipt.BackupPath) { throw 'Invalid receipt for a newly created file.' }
    Assert-NoReparse $target
    $lock = $null
    $stream = $null
    try {
        if ($Apply) { $lock = Open-OperationLock $directory }
        Assert-NoReparse $target
        if ($Apply -and -not $receipt.ExistedBefore) { $stream = Open-DeleteCapableFile $target }
        else { $stream = [IO.File]::Open($target, [IO.FileMode]::Open, $(if ($Apply) { [IO.FileAccess]::ReadWrite } else { [IO.FileAccess]::Read }), [IO.FileShare]::None) }
        $current = Read-StreamBytes $stream
        if ((Get-Hash $current) -ne $receipt.AfterHash) { throw 'Current .env differs from the repair receipt. Rollback refused to preserve later changes.' }
        if ($Apply) {
            if ($receipt.ExistedBefore) {
                $stream.Position = 0; $stream.Write($original, 0, $original.Length); $stream.SetLength($original.Length); $stream.Flush($true)
                if ((Get-Hash (Read-StreamBytes $stream)) -ne $receipt.BeforeHash) { throw 'Restored bytes did not match the backup hash.' }
            } else {
                [int]$delete = 1
                if (-not [CodexProxyRepair.NativeFile]::SetFileInformationByHandle($stream.SafeFileHandle, 4, [ref]$delete, 4)) { throw 'Windows refused safe deletion of the unchanged, newly created .env.' }
            }
        }
        Write-Result @{ Mode = $(if ($Apply) { 'Restored' } else { 'RestorePreview' }); TargetPath = $target; Action = $(if ($receipt.ExistedBefore) { 'RestoreBackup' } else { 'RemoveNewFile' }); ReceiptPath = $receiptPath }
    } finally { if ($stream) { $stream.Dispose() }; if ($lock) { $lock.Dispose() } }
    return
}

$url = Get-NormalizedProxy $ProxyUrl
$directory = Get-AbsolutePath $CodexHome
if ($directory.Length -gt [IO.Path]::GetPathRoot($directory).Length) { $directory = $directory.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) }
Assert-NoReparse $directory
if (-not [IO.Directory]::Exists($directory)) { throw 'CodexHome must be an existing directory.' }
$target = [IO.Path]::Combine($directory, '.env')
Assert-NoReparse $target
if ([IO.Directory]::Exists($target)) { throw '.env is a directory, not a file.' }
if ($Apply -and $ExpectedHash -notmatch '^(MISSING|[a-fA-F0-9]{64})$') { throw '-Apply requires -ExpectedHash from a fresh preview (SHA256 or MISSING).' }
$lock = $null
$stream = $null
try {
    if ($Apply) { $lock = Open-OperationLock $directory }
    Assert-NoReparse $target
    $existed = [IO.File]::Exists($target)
    $oldBytes = [byte[]]@()
    if ($existed) {
        $stream = [IO.File]::Open($target, [IO.FileMode]::Open, $(if ($Apply) { [IO.FileAccess]::ReadWrite } else { [IO.FileAccess]::Read }), [IO.FileShare]::None)
        $oldBytes = Read-StreamBytes $stream
    }
    $beforeHash = 'MISSING'
    if ($existed) { $beforeHash = Get-Hash $oldBytes }
    if ($Apply -and $ExpectedHash -ine $beforeHash) { throw 'The .env file changed since preview. Run preview again before applying.' }
    $edit = Get-EditedBytes $oldBytes $url
    $afterHash = Get-Hash $edit.Bytes
    $hasChanges = $beforeHash -ne $afterHash
    $result = [ordered]@{ Mode = $(if ($Apply) { 'NoChange' } else { 'Preview' }); TargetPath = $target; ExpectedHash = $beforeHash; AfterHash = $afterHash; HasChanges = $hasChanges; ProxyUrl = $url; ChangedKeys = $edit.ChangedKeys; ExistingNoProxyPreserved = $edit.NoProxyPreserved; BackupPath = $null; ReceiptPath = $null }
    if ($Apply -and $hasChanges) {
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N')
        $basePath = [IO.Path]::Combine($directory, '.env.codex-proxy-repair.' + $stamp)
        $backupPath = $null
        if ($existed) { $backupPath = $basePath + '.bak'; Write-NewFile $backupPath $oldBytes }
        $receiptPath = $basePath + '.json'
        $receipt = [ordered]@{ SchemaVersion = 1; TargetPath = $target; ExistedBefore = $existed; BeforeHash = $beforeHash; AfterHash = $afterHash; BackupPath = $backupPath; CreatedUtc = [DateTime]::UtcNow.ToString('o') }
        Write-NewFile $receiptPath ($strictUtf8.GetBytes(($receipt | ConvertTo-Json)))
        if (-not $existed) {
            Assert-NoReparse $target
            $stream = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        try {
            $stream.Position = 0; $stream.Write($edit.Bytes, 0, $edit.Bytes.Length); $stream.SetLength($edit.Bytes.Length); $stream.Flush($true)
            if ((Get-Hash (Read-StreamBytes $stream)) -ne $afterHash) { throw 'Written file hash did not match expected result.' }
        } catch {
            if ($existed) { $stream.Position = 0; $stream.Write($oldBytes, 0, $oldBytes.Length); $stream.SetLength($oldBytes.Length); $stream.Flush($true) }
            throw
        }
        $result.Mode = 'Applied'; $result.BackupPath = $backupPath; $result.ReceiptPath = $receiptPath
    }
    Write-Result $result
} finally { if ($stream) { $stream.Dispose() }; if ($lock) { $lock.Dispose() } }

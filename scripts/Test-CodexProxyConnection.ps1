#Requires -Version 5.1
<#
.SYNOPSIS
Runs the confirmed Codex executable's doctor in an isolated child environment.
.DESCRIPTION
Does not edit files or the caller's environment. Existing persisted configuration
may still be loaded by Codex. Only the five inherited proxy variables are cleared;
NO_PROXY and other settings are retained. A passing result proves the diagnostic
WebSocket handshake, not a model response or a running desktop's environment.

Output is one JSON object. Raw doctor output is never emitted or saved. Unknown
doctor schemas fail closed. At most 2 Mi characters per stream are retained.
.PARAMETER CodexExe
Confirmed absolute path to the actual backend executable, not a command on PATH.
.PARAMETER CodexHome
Confirmed absolute path to an existing Codex configuration directory.
.PARAMETER ProxyUrl
Optional HTTP loopback proxy URL, with an explicit port and no authentication.
.PARAMETER TimeoutSeconds
Maximum child diagnostic runtime, from 1 to 60 seconds (default 45).
.EXAMPLE
& .\Test-CodexProxyConnection.ps1 -CodexExe $exe -CodexHome $configDir
.EXAMPLE
& .\Test-CodexProxyConnection.ps1 -CodexExe $exe -CodexHome $configDir -ProxyUrl $proxy
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CodexExe,
    [Parameter(Mandatory = $true)][string]$CodexHome,
    [string]$ProxyUrl,
    [ValidateRange(1, 60)][int]$TimeoutSeconds = 45
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$proxyKeys = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'WS_PROXY', 'WSS_PROXY')
$watch = [System.Diagnostics.Stopwatch]::StartNew()
$explicitCandidate = $PSBoundParameters.ContainsKey('ProxyUrl')
$report = [ordered]@{
    mode = $(if ($explicitCandidate) { 'explicit-candidate' } else { 'existing-persisted-config' })
    result = 'unknown'
    success = $false
    diagnostic_status = 'not-started'
    reason = $null
    elapsed_ms = 0
    timeout_seconds = $TimeoutSeconds
    codex_version = $null
    schema_version = $null
    exit_code = $null
    no_proxy_preserved = $true
    evidence = [ordered]@{}
}

function Get-Field {
    param($Object, [string]$Name)
    if ($null -eq $Object -or $Object -isnot [pscustomobject]) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-SafeStatus {
    param($Value)
    if ($Value -is [string] -and $Value -cmatch '^(ok|warning|warn|error|failed|fail|skipped|skip|unknown|unsupported)$') {
        return $Value
    }
    return 'unknown'
}

function Get-SafeBoolean {
    param($Value)
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        switch -Regex ($Value.Trim()) {
            '^(?i:true|yes|enabled|on)$' { return $true }
            '^(?i:false|no|disabled|off)$' { return $false }
        }
    }
    return $null
}

function Get-ProxyKeyNames {
    param($Value)
    # Extract names only. In particular, never return a value following NAME=.
    $names = @()
    $strings = @($Value | Where-Object { $_ -is [string] })
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'WS_PROXY', 'WSS_PROXY', 'NO_PROXY')) {
        foreach ($part in $strings) {
            if ($part -match ('(?i)(?<![A-Za-z0-9_])' + $name + '(?![A-Za-z0-9_])')) {
                $names += $name
                break
            }
        }
    }
    return $names
}

function Get-SafeHttpStatus {
    param($Value)
    if ($Value -is [string] -and $Value -match '(?i)\bHTTP(?:/[0-9.]+)?\s+([1-5][0-9]{2})\b') {
        return [int]$Matches[1]
    }
    return $null
}

function Get-FailureCategory {
    param($Value)
    if ($Value -isnot [string]) { return $null }
    if ($Value -match '(?i)timed?\s*out|timeout|deadline exceeded') { return 'timeout' }
    if ($Value -match '(?i)certificate|unknown issuer|tls|ssl') { return 'tls-or-certificate' }
    if ($Value -match '(?i)connection refused|actively refused') { return 'connection-refused' }
    if ($Value -match '(?i)\bDNS\b|name resolution|resolve host') { return 'dns' }
    if ($Value -match '(?i)\b401\b|\b403\b|unauthorized|forbidden') { return 'authentication-or-access' }
    if ($Value -match '(?i)\b429\b|rate limit') { return 'rate-limit' }
    if ($Value -match '(?i)\b5[0-9]{2}\b|service unavailable') { return 'server-or-gateway' }
    return $null
}

function Test-ReportedPath {
    param($Value, [string]$Expected)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $null }
    try {
        if (-not [System.IO.Path]::IsPathRooted($Value)) { return $null }
        return [string]::Equals([System.IO.Path]::GetFullPath($Value).TrimEnd('\', '/'),
            [System.IO.Path]::GetFullPath($Expected).TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)
    } catch { return $null }
}

function Invoke-IsolatedDoctor {
    param([string]$Exe, [string]$ConfigDirectory, [string]$Candidate, [bool]$UseCandidate, [int]$LimitSeconds)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Exe
    $startInfo.Arguments = 'doctor --json'
    $startInfo.WorkingDirectory = $ConfigDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    foreach ($key in @($startInfo.EnvironmentVariables.Keys)) {
        if ($key -imatch '^(HTTP|HTTPS|ALL|WS|WSS)_PROXY$') {
            $startInfo.EnvironmentVariables.Remove($key)
        }
    }
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $ConfigDirectory
    if ($UseCandidate) {
        foreach ($key in $proxyKeys) { $startInfo.EnvironmentVariables[$key] = $Candidate }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $started = $false
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $stdout = New-Object System.Text.StringBuilder
    $stderr = New-Object System.Text.StringBuilder
    $maxCharacters = 2 * 1024 * 1024
    $state = 'completed'
    $exitCode = $null
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Child did not start.' }
        $outBuffer = New-Object char[] 4096
        $errBuffer = New-Object char[] 4096
        $outRead = $process.StandardOutput.ReadAsync($outBuffer, 0, $outBuffer.Length)
        $errRead = $process.StandardError.ReadAsync($errBuffer, 0, $errBuffer.Length)
        $outDone = $false
        $errDone = $false
        while ($true) {
            if ($timer.Elapsed.TotalSeconds -ge $LimitSeconds) { $state = 'timeout'; break }
            if (-not $outDone -and $outRead.IsCompleted) {
                $count = $outRead.GetAwaiter().GetResult()
                if ($count -eq 0) { $outDone = $true }
                elseif ($stdout.Length + $count -gt $maxCharacters) { $state = 'output-limit'; break }
                else {
                    [void]$stdout.Append($outBuffer, 0, $count)
                    $outRead = $process.StandardOutput.ReadAsync($outBuffer, 0, $outBuffer.Length)
                }
            }
            if (-not $errDone -and $errRead.IsCompleted) {
                $count = $errRead.GetAwaiter().GetResult()
                if ($count -eq 0) { $errDone = $true }
                elseif ($stderr.Length + $count -gt $maxCharacters) { $state = 'output-limit'; break }
                else {
                    [void]$stderr.Append($errBuffer, 0, $count)
                    $errRead = $process.StandardError.ReadAsync($errBuffer, 0, $errBuffer.Length)
                }
            }
            if ($process.HasExited -and $outDone -and $errDone) { $exitCode = $process.ExitCode; break }
            # Both streams have pending asynchronous reads; do not block on either one.
            if ($process.HasExited) { [System.Threading.Thread]::Sleep(2) }
            else { [void]$process.WaitForExit(10) }
        }
    } catch {
        $state = $(if ($started) { 'diagnostic-read-failed' } else { 'launch-failed' })
    } finally {
        # Never taskkill by image name and never terminate the user's other processes.
        if ($started) {
            try { if (-not $process.HasExited) { $process.Kill() } } catch { $state = 'child-cleanup-failed' }
        }
        $timer.Stop()
        $process.Dispose()
    }
    return [pscustomobject]@{
        State = $state; ExitCode = $exitCode
        Stdout = $stdout.ToString(); Stderr = $stderr.ToString()
    }
}

try {
    # Require a fully qualified local/UNC Windows path. Drive-relative C:foo and
    # rooted-but-drive-relative \foo are rejected before resolving filesystem items.
    foreach ($path in @($CodexExe, $CodexHome)) {
        if ([string]::IsNullOrWhiteSpace($path) -or $path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+[\\/]?)' -or $path -match '[\r\n]') {
            throw 'INPUT_PATH'
        }
    }
    $exeItem = Get-Item -LiteralPath $CodexExe -ErrorAction Stop
    $homeItem = Get-Item -LiteralPath $CodexHome -ErrorAction Stop
    if ($exeItem.PSIsContainer -or $exeItem.Extension -ine '.exe' -or -not $homeItem.PSIsContainer -or
        $exeItem.PSProvider.Name -ne 'FileSystem' -or $homeItem.PSProvider.Name -ne 'FileSystem') {
        throw 'INPUT_PATH'
    }
    $resolvedExe = $exeItem.FullName
    $resolvedHome = $homeItem.FullName
    $candidate = $null
    if ($explicitCandidate) {
        # Literal loopback only: no DNS, credentials, PAC, query, fragment, or URL path.
        if ($ProxyUrl -notmatch '^http://(?<host>127(?:\.[0-9]{1,3}){3}|localhost|\[::1\]):(?<port>[0-9]{1,5})/?$') {
            throw 'INPUT_PROXY'
        }
        $candidateHost = $Matches.host
        $candidatePort = [int]$Matches.port
        if ($candidatePort -lt 1 -or $candidatePort -gt 65535) { throw 'INPUT_PROXY' }
        if ($candidateHost -ine 'localhost' -and $candidateHost -ne '[::1]') {
            $address = $null
            if (-not [System.Net.IPAddress]::TryParse($candidateHost, [ref]$address) -or
                -not [System.Net.IPAddress]::IsLoopback($address)) { throw 'INPUT_PROXY' }
        }
        $candidate = 'http://{0}:{1}' -f $candidateHost.ToLowerInvariant(), $candidatePort
    }
    $fileVersion = $exeItem.VersionInfo.ProductVersion
    if ($fileVersion -is [string] -and $fileVersion -match '^\d{1,4}\.\d{1,4}\.\d{1,4}(?:\.\d{1,4})?$') {
        $report.codex_version = $fileVersion
    }
    $run = Invoke-IsolatedDoctor -Exe $resolvedExe -ConfigDirectory $resolvedHome -Candidate $candidate -UseCandidate $explicitCandidate -LimitSeconds $TimeoutSeconds
    $report.diagnostic_status = $run.State
    $report.exit_code = $run.ExitCode
    if ($run.State -ne 'completed') {
        $report.reason = $run.State
    } else {
        $parsed = $null
        try { $parsed = ConvertFrom-Json -InputObject $run.Stdout -ErrorAction Stop } catch { }
        $checks = Get-Field $parsed 'checks'
        $websocketCheck = Get-Field $checks 'network.websocket_reachability'
        if ($null -eq $checks -or $null -eq $websocketCheck) {
            $report.diagnostic_status = 'needs-version-specific-diagnostics'
            $unsupported = ($run.Stderr -match '(?i)(?:unrecognized|unknown|unexpected|invalid)\s+(?:subcommand|command|argument|option)[^\r\n]{0,100}(?:doctor|--json)')
            $report.reason = $(if ($unsupported) { 'doctor-command-or-json-unsupported' } elseif ($null -eq $parsed) { 'doctor-json-unavailable' } else { 'required-check-schema-missing' })
        } else {
            $version = Get-Field $parsed 'codexVersion'
            if ($version -is [string] -and $version -match '^\d{1,4}\.\d{1,4}\.\d{1,4}(?:[-+][A-Za-z0-9.]{1,32})?$') { $report.codex_version = $version }
            $schemaVersion = Get-Field $parsed 'schemaVersion'
            if ($schemaVersion -is [int] -or $schemaVersion -is [long]) { $report.schema_version = $schemaVersion }
            foreach ($id in @('config.load', 'network.env', 'network.provider_reachability', 'network.websocket_reachability')) {
                $check = Get-Field $checks $id
                $details = Get-Field $check 'details'
                $safeCheck = [ordered]@{ present = ($null -ne $check); status = (Get-SafeStatus (Get-Field $check 'status')) }
                switch ($id) {
                    'config.load' {
                        $safeCheck.codex_home_matches_input = Test-ReportedPath (Get-Field $details 'CODEX_HOME') $resolvedHome
                        $safeCheck.config_path_matches_expected = Test-ReportedPath (Get-Field $details 'config.toml') (Join-Path $resolvedHome 'config.toml')
                        $safeCheck.cwd_matches_input = Test-ReportedPath (Get-Field $details 'cwd') $resolvedHome
                        $provider = Get-Field $details 'model provider'
                        $safeCheck.provider = $(if ($provider -ceq 'openai') { 'openai' } elseif ($null -ne $provider) { 'other-or-unrecognized' } else { 'unknown' })
                    }
                    'network.env' {
                        $safeCheck.proxy_variable_names = @(Get-ProxyKeyNames (Get-Field $details 'proxy env vars present'))
                        $safeCheck.respect_system_proxy = Get-SafeBoolean (Get-Field $details 'respect system proxy')
                        $safeCheck.managed_proxy = Get-SafeBoolean (Get-Field $details 'managed proxy')
                    }
                    'network.provider_reachability' {
                        $safeCheck.inference_http_status = Get-SafeHttpStatus (Get-Field $details 'ChatGPT inference URL')
                        $safeCheck.inference_failure_category = Get-FailureCategory (Get-Field $details 'ChatGPT inference URL')
                    }
                    'network.websocket_reachability' {
                        $handshake = Get-Field $details 'handshake result'
                        # Match a reported successful response, never an arbitrary summary
                        # that merely mentions an expected 101 response or a secret URL.
                        $upgrade101 = ($handshake -is [string] -and $handshake -match '^\s*(?:HTTP(?:/[0-9.]+)?\s+)?101\s+Switching\s+Protocols(?:\s|$)')
                        $safeCheck.handshake_result_present = ($handshake -is [string])
                        $safeCheck.http_101_switching_protocols = $upgrade101
                        $safeCheck.supports_websockets = Get-SafeBoolean (Get-Field $details 'supports websockets')
                        $safeCheck.proxy_variable_names = @(Get-ProxyKeyNames (Get-Field $details 'proxy env vars present'))
                        $failureCategory = Get-FailureCategory $handshake
                        if ($null -eq $failureCategory) {
                            foreach ($note in @(Get-Field $check 'notes')) {
                                $failureCategory = Get-FailureCategory $note
                                if ($null -ne $failureCategory) { break }
                            }
                        }
                        if ($null -eq $failureCategory) {
                            # Classify a reported failure without exposing raw
                            # summaries (which can contain user paths or URLs).
                            $failureCategory = Get-FailureCategory (Get-Field $check 'summary')
                        }
                        $safeCheck.failure_category = $failureCategory
                        $safeCheck.http_status = $(if ($upgrade101) { 101 } else { Get-SafeHttpStatus $handshake })
                    }
                }
                $report.evidence[$id] = $safeCheck
            }
            $websocket = $report.evidence['network.websocket_reachability']
            $configEvidence = $report.evidence['config.load']
            if ($report.schema_version -ne 1 -or $configEvidence.status -cne 'ok' -or
                $configEvidence.codex_home_matches_input -ne $true -or
                $configEvidence.config_path_matches_expected -ne $true -or
                $configEvidence.provider -cne 'openai') {
                $report.diagnostic_status = 'needs-version-specific-diagnostics'
                $report.reason = 'schema-provider-or-config-directory-unconfirmed'
            } elseif ($websocket.status -ceq 'ok' -and $websocket.http_101_switching_protocols) {
                $report.result = 'passed'; $report.success = $true
                $report.reason = 'authenticated-websocket-upgrade-confirmed'
            } elseif ($websocket.status -in @('error', 'failed', 'fail') -or
                ($websocket.status -in @('warning', 'warn') -and $null -ne $websocket.failure_category)) {
                $report.result = 'failed'; $report.reason = 'websocket-check-failed'
            } else {
                $report.diagnostic_status = 'needs-version-specific-diagnostics'
                $report.reason = 'explicit-websocket-success-evidence-missing'
            }
        }
    }
} catch {
    $report.diagnostic_status = 'not-started'
    $report.reason = $(if ($_.Exception.Message -eq 'INPUT_PROXY') { 'invalid-loopback-http-proxy-url' } else { 'invalid-input-or-diagnostic-error' })
} finally {
    $watch.Stop()
    $report.elapsed_ms = [long]$watch.Elapsed.TotalMilliseconds
}

$report | ConvertTo-Json -Depth 8

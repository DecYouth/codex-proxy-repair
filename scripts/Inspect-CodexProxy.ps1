#requires -Version 5.1
<#
Read-only snapshot. A proxy program name is a hint, never proof of ownership or
protocol. -Probe sends CONNECT and performs normal certificate-verified TLS to
chatgpt.com:443; it does NOT test an authenticated Codex/WebSocket request.
No installed-program search, credential files, subscriptions or command lines.
#>
[CmdletBinding()]
param(
    [switch]$Probe,
    [ValidateRange(1000,15000)][int]$TimeoutMs = 5000,
    [switch]$LibraryOnly
)

function ConvertTo-ProxyEndpoint {
    param([string]$Value, [string]$Mapping = 'all')
    $valueText = $Value.Trim()
    $defaultScheme = 'http'
    if ($Mapping -eq 'socks') { $defaultScheme = 'socks' }
    if ($valueText -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $valueText = $defaultScheme + '://' + $valueText
    }
    $parsed = $null
    if (-not [Uri]::TryCreate($valueText, [UriKind]::Absolute, [ref]$parsed)) {
        return [pscustomobject]@{ Valid = $false; Reason = 'InvalidEndpoint'; Mapping = $Mapping }
    }
    if ($parsed.Scheme -notin @('http','https','socks','socks4','socks4a','socks5','socks5h') -or
        $parsed.Port -lt 1 -or $parsed.Port -gt 65535 -or
        $parsed.AbsolutePath -notin @('','/') -or $parsed.Query -or $parsed.Fragment -or -not $parsed.Host) {
        return [pscustomobject]@{ Valid = $false; Reason = 'UnsupportedOrIncompleteEndpoint'; Mapping = $Mapping }
    }
    $endpointHost = $parsed.Host.Trim('[',']').ToLowerInvariant()
    $ip = $null
    $isIp = [Net.IPAddress]::TryParse($endpointHost, [ref]$ip)
    if ($isIp) { $endpointHost = $ip.ToString().ToLowerInvariant() }
    $displayHost = $endpointHost
    if ($endpointHost.Contains(':')) { $displayHost = '[' + $endpointHost + ']' }
    $loopback = ($endpointHost -eq 'localhost') -or ($isIp -and [Net.IPAddress]::IsLoopback($ip))
    [pscustomobject]@{
        Valid = $true; Reason = $null; Mapping = $Mapping
        Scheme = $parsed.Scheme; Host = $endpointHost; Port = $parsed.Port
        Endpoint = $parsed.Scheme + '://' + $displayHost + ':' + $parsed.Port
        CredentialsPresent = [bool]$parsed.UserInfo
        IsLoopback = [bool]$loopback
    }
}

function ConvertFrom-WinInetProxyServer {
    param([string]$ProxyServer)
    if ([string]::IsNullOrWhiteSpace($ProxyServer)) { return }
    foreach ($entry in ($ProxyServer -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $mapping = 'all'
        $endpointText = $entry.Trim()
        if ($endpointText -match '^([^=]+)=(.*)$') {
            $mapping = $Matches[1].Trim().ToLowerInvariant()
            $endpointText = $Matches[2].Trim()
            if ($mapping -notin @('http','https','ftp','socks')) {
                [pscustomobject]@{ Valid = $false; Reason = 'UnknownProtocolMapping'; Mapping = 'unknown' }
                continue
            }
        }
        ConvertTo-ProxyEndpoint -Value $endpointText -Mapping $mapping
    }
}

function Test-ListenerBinding {
    param([string]$EndpointHost, [string]$ListenerAddress)
    # Wildcards cover only the appropriate local address family. Never match a
    # different explicit address merely because it has the same port number.
    $listenIp = $null
    if (-not [Net.IPAddress]::TryParse($ListenerAddress, [ref]$listenIp)) { return $false }
    $endpointIps = @()
    if ($EndpointHost -eq 'localhost') {
        $endpointIps = @([Net.IPAddress]::Loopback, [Net.IPAddress]::IPv6Loopback)
    } else {
        $endpointIp = $null
        if (-not [Net.IPAddress]::TryParse($EndpointHost.Trim('[',']'), [ref]$endpointIp)) { return $false }
        $endpointIps = @($endpointIp)
    }
    foreach ($candidateIp in $endpointIps) {
        if ($listenIp.Equals($candidateIp)) { return $true }
        if ($listenIp.Equals([Net.IPAddress]::Any) -and
            $candidateIp.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { return $true }
        if ($listenIp.Equals([Net.IPAddress]::IPv6Any) -and
            $candidateIp.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) { return $true }
    }
    return $false
}

function Get-LimitedProcessPath {
    param([int]$ProcessId)
    # PROCESS_QUERY_LIMITED_INFORMATION avoids requesting process memory access.
    if (-not ('CodexProxyRepair.ProcessImage' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace CodexProxyRepair {
 public static class ProcessImage {
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr h, uint flags, StringBuilder name, ref int size);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  public static string Read(int pid) {
   IntPtr h = OpenProcess(0x1000, false, pid);
   if (h == IntPtr.Zero) return null;
   try { int n=32768; var s=new StringBuilder(n); return QueryFullProcessImageName(h,0,s,ref n) ? s.ToString() : null; }
   finally { CloseHandle(h); }
  }
 }
}
'@ -ErrorAction Stop
    }
    [CodexProxyRepair.ProcessImage]::Read($ProcessId)
}

function Get-SafeProcessRecord {
    param([int]$ProcessId, [object]$CimRecord)
    $procName = $null
    $procPath = $null
    $startUtc = $null
    $isRunning = $false
    $pathSource = 'UnknownAccessDeniedOrExited'
    $parentId = $null
    if ($null -ne $CimRecord) {
        $procName = $CimRecord.Name
        $procPath = $CimRecord.ExecutablePath
        $parentId = $CimRecord.ParentProcessId
        if ($procPath) { $pathSource = 'CIM' }
    }
    try {
        $live = Get-Process -Id $ProcessId -ErrorAction Stop
        $isRunning = -not $live.HasExited
        if (-not $procName) { $procName = $live.ProcessName }
        try { $startUtc = $live.StartTime.ToUniversalTime().ToString('o') } catch { }
        if (-not $procPath) {
            try { $procPath = $live.Path } catch { }
            if ($procPath) { $pathSource = 'GetProcess' }
        }
    } catch { }
    if ($isRunning -and -not $procPath) {
        try {
            $procPath = Get-LimitedProcessPath -ProcessId $ProcessId
            if ($procPath) { $pathSource = 'QueryFullProcessImageName' }
        } catch { }
    }
    [pscustomobject]@{
        ProcessId = $ProcessId; ParentProcessId = $parentId; Name = $procName; Path = $procPath
        IsRunningAtInspection = $isRunning; StartTimeUtc = $startUtc
        PathSource = $pathSource
    }
}

function Get-WinInetConnectionFlags {
    # Query WinINET itself: AutoDetect is usually NOT a standalone registry
    # value. This API reads only connection flags, not PAC content or secrets.
    if (-not ('CodexProxyRepair.WinInetRouting' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CodexProxyRepair {
 public static class WinInetRouting {
  [StructLayout(LayoutKind.Explicit)] struct OptionValue {
   [FieldOffset(0)] public int Integer;
   [FieldOffset(0)] public IntPtr Pointer;
   [FieldOffset(0)] public System.Runtime.InteropServices.ComTypes.FILETIME FileTime;
  }
  [StructLayout(LayoutKind.Sequential)] struct Option { public int Key; public OptionValue Value; }
  [StructLayout(LayoutKind.Sequential)] struct OptionList {
   public int Size; public IntPtr Connection; public int Count; public int Error; public IntPtr Options;
  }
  [DllImport("wininet.dll", EntryPoint="InternetQueryOptionW", SetLastError=true)]
  static extern bool Query(IntPtr handle, int option, ref OptionList list, ref int size);
  public static int ReadFlags() {
   IntPtr block=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Option)));
   try {
    foreach (int key in new int[] {10,1}) {
     Option item=new Option(); item.Key=key;
     Marshal.StructureToPtr(item,block,false);
     OptionList list=new OptionList(); list.Size=Marshal.SizeOf(typeof(OptionList));
     list.Count=1; list.Options=block; int size=list.Size;
     if(Query(IntPtr.Zero,75,ref list,ref size)) {
      return ((Option)Marshal.PtrToStructure(block,typeof(Option))).Value.Integer;
     }
    }
    return -1;
   } finally { Marshal.FreeHGlobal(block); }
  }
 }
}
'@ -ErrorAction Stop
    }
    [CodexProxyRepair.WinInetRouting]::ReadFlags()
}

function Test-HttpProxyTls {
    param([string]$ProxyHost, [int]$ProxyPort, [int]$BudgetMs)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $tcp = $null
    $ssl = $null
    $stage = 'TcpConnect'
    $connectStatus = $null
    $result = [ordered]@{
        Kind = 'HTTP_CONNECT_then_verified_TLS'; Target = 'chatgpt.com:443'
        Success = $false; HttpConnectStatus = $null; CertificateVerified = $false
        TlsProtocol = $null; FailureStage = $null; ErrorType = $null
        DurationMs = $null; AuthenticatedCodexOrWebSocketTest = $false
    }
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        $asyncConnect = $tcp.BeginConnect($ProxyHost, $ProxyPort, $null, $null)
        try {
            if (-not $asyncConnect.AsyncWaitHandle.WaitOne($BudgetMs)) { throw [TimeoutException]::new('TCP timeout') }
            $tcp.EndConnect($asyncConnect)
        } finally { $asyncConnect.AsyncWaitHandle.Close() }
        $stage = 'HttpConnect'
        $remaining = $BudgetMs - [int]$watch.ElapsedMilliseconds
        if ($remaining -le 0) { throw [TimeoutException]::new('Budget exhausted') }
        $stream = $tcp.GetStream()
        $stream.WriteTimeout = $remaining
        $request = [Text.Encoding]::ASCII.GetBytes("CONNECT chatgpt.com:443 HTTP/1.1`r`nHost: chatgpt.com:443`r`nConnection: keep-alive`r`n`r`n")
        $stream.Write($request, 0, $request.Length)
        $header = New-Object Text.StringBuilder
        while ($header.Length -lt 8192) {
            $remaining = $BudgetMs - [int]$watch.ElapsedMilliseconds
            if ($remaining -le 0) { throw [TimeoutException]::new('Budget exhausted') }
            $stream.ReadTimeout = $remaining
            $b = $stream.ReadByte()
            if ($b -lt 0) { throw [IO.IOException]::new('Proxy closed connection') }
            [void]$header.Append([char]$b)
            if ($header.ToString().EndsWith("`r`n`r`n")) { break }
        }
        if (-not $header.ToString().EndsWith("`r`n`r`n")) { throw [IO.IOException]::new('Header exceeds limit') }
        if ($header.ToString() -notmatch '^HTTP/1\.[01] ([0-9]{3})[ \r\n]') { throw [IO.IOException]::new('Invalid HTTP CONNECT response') }
        $connectStatus = [int]$Matches[1]
        $result.HttpConnectStatus = $connectStatus
        if ($connectStatus -ne 200) { throw [IO.IOException]::new('HTTP CONNECT rejected') }
        $stage = 'VerifiedTls'
        $remaining = $BudgetMs - [int]$watch.ElapsedMilliseconds
        if ($remaining -le 0) { throw [TimeoutException]::new('Budget exhausted') }
        $ssl = New-Object Net.Security.SslStream($stream, $false)
        # No certificate validation callback. Normal hostname and chain checks
        # remain enabled. TLS 1.2 is supported by Windows PowerShell 5.1.
        $asyncTls = $ssl.BeginAuthenticateAsClient('chatgpt.com', $null, [Security.Authentication.SslProtocols]::Tls12, $true, $null, $null)
        try {
            if (-not $asyncTls.AsyncWaitHandle.WaitOne($remaining)) { throw [TimeoutException]::new('TLS timeout') }
            $ssl.EndAuthenticateAsClient($asyncTls)
        } finally { $asyncTls.AsyncWaitHandle.Close() }
        $result.Success = $true
        $result.CertificateVerified = $true
        $result.TlsProtocol = $ssl.SslProtocol.ToString()
    } catch {
        $result.FailureStage = $stage
        # Error types are safe diagnostics; exception messages may contain URLs.
        $exception = $_.Exception
        if ($exception.InnerException) { $exception = $exception.InnerException }
        $result.ErrorType = $exception.GetType().FullName
    } finally {
        if ($null -ne $ssl) { $ssl.Dispose() }
        if ($null -ne $tcp) { $tcp.Close() }
        $watch.Stop()
        $result.DurationMs = $watch.ElapsedMilliseconds
    }
    [pscustomobject]$result
}

function Get-CodexProxyInspection {
    param([switch]$RunProbe, [int]$ProbeTimeoutMs)
    $started = [DateTime]::UtcNow.ToString('o')
    $warnings = New-Object 'Collections.Generic.List[string]'
    $registry = $null
    try { $registry = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop }
    catch { $warnings.Add('WinInetReadFailedOrAccessDenied') }
    $proxyEnabled = $false
    $pacConfigured = $false
    $autoDetect = $null
    $routingFlags = -1
    if ($null -ne $registry) {
        $proxyEnabled = $registry.ProxyEnable -eq 1
        $pacConfigured = -not [string]::IsNullOrWhiteSpace([string]$registry.AutoConfigURL)
    }
    try { $routingFlags = Get-WinInetConnectionFlags } catch { $warnings.Add('WinInetRoutingFlagsReadFailed') }
    $routingConflict = $false
    if ($routingFlags -ge 0) {
        $autoDetect = [bool]($routingFlags -band 8)
        $apiFixedProxy = [bool]($routingFlags -band 2)
        if ($apiFixedProxy -ne $proxyEnabled) { $routingConflict = $true; $warnings.Add('WinInetApiAndRegistryFixedProxyDisagree') }
        # A configured but inactive PAC URL is still reported conservatively.
        $pacConfigured = $pacConfigured -or [bool]($routingFlags -band 4)
    } else { $warnings.Add('WinInetAutoRoutingUnknownDoNotAutoSelect') }
    # PAC URLs and bypass lists are deliberately not printed.
    $parsedEndpoints = @()
    if ($null -ne $registry) { $parsedEndpoints = @(ConvertFrom-WinInetProxyServer -ProxyServer ([string]$registry.ProxyServer)) }
    $connections = @()
    $connectionQueryOk = $false
    try { $connections = @(Get-NetTCPConnection -ErrorAction Stop); $connectionQueryOk = $true }
    catch { $warnings.Add('TcpConnectionReadFailedOrAccessDenied') }
    $listeners = @($connections | Where-Object { $_.State -eq 'Listen' })
    $cimProcesses = @()
    try { $cimProcesses = @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name,ExecutablePath -ErrorAction Stop) }
    catch { $warnings.Add('ProcessInventoryFailedOrAccessDenied') }
    $cimById = @{}
    foreach ($row in $cimProcesses) { $cimById[[int]$row.ProcessId] = $row }
    $recordsById = @{}
    $candidates = New-Object 'Collections.Generic.List[object]'
    $seen = @{}
    foreach ($endpoint in $parsedEndpoints) {
        if (-not $endpoint.Valid) { $warnings.Add('WinInetEndpoint:' + $endpoint.Reason); continue }
        $key = $endpoint.Endpoint
        if ($seen.ContainsKey($key)) { $seen[$key].Mappings += $endpoint.Mapping; continue }
        $matching = @($listeners | Where-Object {
            $_.LocalPort -eq $endpoint.Port -and (Test-ListenerBinding -EndpointHost $endpoint.Host -ListenerAddress $_.LocalAddress)
        })
        $owners = @()
        foreach ($ownerId in @($matching | Select-Object -ExpandProperty OwningProcess -Unique)) {
            $ownerNumber = [int]$ownerId
            if (-not $recordsById.ContainsKey($ownerNumber)) {
                $recordsById[$ownerNumber] = Get-SafeProcessRecord -ProcessId $ownerNumber -CimRecord $cimById[$ownerNumber]
            }
            $owners += $recordsById[$ownerNumber]
        }
        $candidate = [pscustomobject]@{
            Source = 'WinINET'; SystemProxyEnabled = $proxyEnabled; Mappings = @($endpoint.Mapping)
            Endpoint = $endpoint.Endpoint; Scheme = $endpoint.Scheme; Host = $endpoint.Host; Port = $endpoint.Port
            IsLoopback = $endpoint.IsLoopback; CredentialsPresent = $endpoint.CredentialsPresent
            MatchingListeners = @($matching | Select-Object LocalAddress,LocalPort,OwningProcess)
            Owners = @($owners); Probe = $null; ProbeSkippedReason = $null
            IdentityGuard = 'NotChecked'; CanConsiderForRepair = $false
        }
        if (-not $RunProbe) { $candidate.ProbeSkippedReason = 'ProbeNotRequested' }
        elseif (-not $proxyEnabled) { $candidate.ProbeSkippedReason = 'SystemProxyDisabled' }
        elseif ($routingConflict -or $routingFlags -lt 0) { $candidate.ProbeSkippedReason = 'WinInetRoutingUnknownOrConflicting' }
        elseif ($pacConfigured -or $autoDetect -eq $true) { $candidate.ProbeSkippedReason = 'PACOrAutoDetectRequiresRoutingReview' }
        elseif ($endpoint.CredentialsPresent) { $candidate.ProbeSkippedReason = 'ProxyAuthenticationPresent' }
        elseif (-not $endpoint.IsLoopback -or $endpoint.Scheme -ne 'http') { $candidate.ProbeSkippedReason = 'OnlyLoopbackHttpProbeSupported' }
        elseif ($owners.Count -ne 1 -or -not $owners[0].IsRunningAtInspection -or -not $owners[0].StartTimeUtc) { $candidate.ProbeSkippedReason = 'OwnerAmbiguousUnknownOrExited' }
        else {
            $candidate.Probe = Test-HttpProxyTls -ProxyHost $endpoint.Host -ProxyPort $endpoint.Port -BudgetMs $ProbeTimeoutMs
            $freshOwner = Get-SafeProcessRecord -ProcessId $owners[0].ProcessId -CimRecord $null
            $freshListeners = @()
            try { $freshListeners = @(Get-NetTCPConnection -State Listen -LocalPort $endpoint.Port -ErrorAction Stop) } catch { }
            $freshMatch = @($freshListeners | Where-Object { Test-ListenerBinding -EndpointHost $endpoint.Host -ListenerAddress $_.LocalAddress })
            $freshOwnerIds = @($freshMatch | Select-Object -ExpandProperty OwningProcess -Unique)
            $routingUnchanged = $false
            try {
                $freshRegistry = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
                $routingUnchanged = $freshRegistry.ProxyEnable -eq $registry.ProxyEnable -and
                    $freshRegistry.ProxyServer -ceq $registry.ProxyServer -and
                    $freshRegistry.AutoConfigURL -ceq $registry.AutoConfigURL -and
                    (Get-WinInetConnectionFlags) -eq $routingFlags
            } catch { }
            if ($freshOwner.IsRunningAtInspection -and $freshOwner.StartTimeUtc -eq $owners[0].StartTimeUtc -and
                $freshOwnerIds.Count -eq 1 -and $freshOwnerIds[0] -eq $owners[0].ProcessId -and $routingUnchanged) {
                $candidate.IdentityGuard = 'SameRunningProcessAndBindingAfterProbe'
                $candidate.CanConsiderForRepair = [bool]$candidate.Probe.Success
            } else { $candidate.IdentityGuard = 'MismatchOrUnknownDoNotMutate' }
        }
        $seen[$key] = $candidate
        $candidates.Add($candidate)
    }
    $plausible = @()
    $codexProcesses = @()
    $proxyNamePattern = '^(nano|clash.*|mihomo.*|sing-box|singbox|v2ray.*|xray.*|hysteria.*|shadowsocks.*|ss-local|trojan.*|nekoray.*|nekobox.*|hiddify.*|outline.*|tailscale.*|wireguard.*|openvpn.*|tun2socks.*)(\.exe)?$'
    foreach ($row in $cimProcesses) {
        $isProxyHint = $row.Name -match $proxyNamePattern
        $isCodex = $row.Name -match '^codex(?:[-_].*)?\.exe$'
        if (-not $isProxyHint -and -not $isCodex) { continue }
        $recordId = [int]$row.ProcessId
        if (-not $recordsById.ContainsKey($recordId)) { $recordsById[$recordId] = Get-SafeProcessRecord -ProcessId $recordId -CimRecord $row }
        $processRecord = $recordsById[$recordId]
        if (-not $processRecord.IsRunningAtInspection) { continue }
        if ($isProxyHint) {
            $plausible += [pscustomobject]@{
                Process = $processRecord; Evidence = 'NameHintOnlyNotSelectedAsProxy'
                Listeners = @($listeners | Where-Object { $_.OwningProcess -eq $recordId } | Select-Object LocalAddress,LocalPort)
            }
        }
        if ($isCodex) {
            $role = 'CodexProcessRoleUnconfirmed'
            if ($processRecord.Path -match '[\\/]resources[\\/](?:[^\\/]+[\\/])*codex(?:-app-server)?\.exe$' -or
                $processRecord.Path -match '[\\/]OpenAI[\\/]Codex[\\/]bin[\\/][^\\/]+[\\/]codex\.exe$') { $role = 'BundledCodexBackendCandidate' }
            $established = @($connections | Where-Object { $_.OwningProcess -eq $recordId -and $_.State -eq 'Established' })
            $remoteRows = @()
            foreach ($connection in $established) {
                $matchesCandidates = @($candidates | Where-Object {
                    $_.Port -eq $connection.RemotePort -and (Test-ListenerBinding -EndpointHost $_.Host -ListenerAddress $connection.RemoteAddress)
                } | Select-Object -ExpandProperty Endpoint)
                $remoteRows += [pscustomobject]@{
                    LocalAddress = $connection.LocalAddress; LocalPort = $connection.LocalPort
                    RemoteAddress = $connection.RemoteAddress; RemotePort = $connection.RemotePort
                    MatchesCandidateEndpoints = $matchesCandidates
                }
            }
            $codexProcesses += [pscustomobject]@{ Process = $processRecord; Role = $role; EstablishedConnections = $remoteRows }
        }
    }
    $callerProxyEnvironment = @()
    foreach ($varName in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','WS_PROXY','WSS_PROXY')) {
        $varValue = [Environment]::GetEnvironmentVariable($varName,'Process')
        if ([string]::IsNullOrWhiteSpace($varValue)) { continue }
        $safeEndpoint = ConvertTo-ProxyEndpoint -Value $varValue
        $callerProxyEnvironment += [pscustomobject]@{
            Name = $varName; Present = $true
            Endpoint = $(if ($safeEndpoint.Valid) { $safeEndpoint.Endpoint } else { $null })
            CredentialsPresent = $(if ($safeEndpoint.Valid) { $safeEndpoint.CredentialsPresent } else { $null })
            ValueOmittedWhenNotAnEndpoint = -not $safeEndpoint.Valid
        }
    }
    $resolution = 'Inconclusive'
    if ($routingConflict -or $routingFlags -lt 0) { $resolution = 'InconclusiveWinInetRoutingFlags' }
    elseif ($pacConfigured -or $autoDetect -eq $true) { $resolution = 'InconclusivePACOrAutoDetect' }
    elseif (-not $proxyEnabled) { $resolution = 'InconclusiveNoEnabledFixedSystemProxyPossibleTUN' }
    elseif (@($candidates | Where-Object { $_.CanConsiderForRepair }).Count -eq 1 -and $candidates.Count -eq 1) { $resolution = 'OneVerifiedHttpProxyCandidateRequiresCodexDiagnosticComparison' }
    elseif ($candidates.Count -gt 1) { $resolution = 'MultipleEndpointMappingsRequireReview' }
    elseif ($candidates.Count -eq 1) { $resolution = 'CandidateRequiresProbeOrDiagnosis' }
    [pscustomobject]@{
        SchemaVersion = 1; SnapshotStartedUtc = $started; SnapshotCompletedUtc = [DateTime]::UtcNow.ToString('o')
        ReadOnly = $true; NetworkProbeRequested = [bool]$RunProbe; Resolution = $resolution
        EvidenceFreshness = 'PointInTimeOnlyReinspectImmediatelyBeforeMutation'
        WinINET = [pscustomobject]@{ ReadSucceeded = ($null -ne $registry); ProxyEnabled = $proxyEnabled; PACConfigured = $pacConfigured; AutoDetectEnabled = $autoDetect; ConnectionFlags = $routingFlags; ConnectionFlagsSource = 'InternetQueryOptionPerConnectionFlagsUIWithFlagsFallback'; AutoDetectNotFullyDetermined = ($routingFlags -lt 0); ApiRegistryConflict = $routingConflict }
        TcpSnapshotSucceeded = $connectionQueryOk; Candidates = @($candidates.ToArray())
        PlausibleRunningProxyProcesses = $plausible; CodexProcesses = $codexProcesses
        CallerProxyEnvironment = $callerProxyEnvironment
        CallerEnvironmentCaveat = 'This is the inspector process environment, not proof of the running Codex backend environment.'
        Limitations = @('No authenticated Codex or WebSocket test performed.', 'Established TCP connections are a transient snapshot, not proof of all request routing.', 'TUN and PAC routing cannot be inferred from a fixed proxy or process name.', 'A process listener can be an admin port; only successful protocol probes establish HTTP proxy behavior.', 'Candidate readiness does not authorize a write without Codex diagnostic comparison.')
        Warnings = @($warnings.ToArray())
    }
}

if (-not $LibraryOnly) {
    Get-CodexProxyInspection -RunProbe:$Probe -ProbeTimeoutMs $TimeoutMs | ConvertTo-Json -Depth 12
}

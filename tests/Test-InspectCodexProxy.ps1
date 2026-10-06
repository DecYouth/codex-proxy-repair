#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\Inspect-CodexProxy.ps1') -LibraryOnly
$checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Label)
    if (-not $Condition) { throw ('FAILED: ' + $Label) }
    $script:checks++
}
$single = @(ConvertFrom-WinInetProxyServer 'http://127.0.0.1:61234')
Assert-True ($single.Count -eq 1 -and $single[0].Port -eq 61234 -and $single[0].IsLoopback) 'single HTTP endpoint'
$bare = @(ConvertFrom-WinInetProxyServer '127.0.0.1:54321')
Assert-True ($bare[0].Scheme -eq 'http' -and $bare[0].Port -eq 54321) 'bare WinINET defaults to HTTP'
$mapped = @(ConvertFrom-WinInetProxyServer 'http=127.0.0.1:1111;https=[::1]:2222;socks=localhost:3333')
Assert-True ($mapped.Count -eq 3) 'per-protocol mappings'
Assert-True ($mapped[1].Scheme -eq 'http' -and $mapped[1].Endpoint -eq 'http://[::1]:2222') 'HTTPS mapping is not HTTPS proxy assumption'
Assert-True ($mapped[2].Scheme -eq 'socks') 'SOCKS version left unspecified'
$credentials = ConvertTo-ProxyEndpoint 'http://exampleUser:exampleSecret@127.0.0.1:2222'
Assert-True ($credentials.CredentialsPresent -and $credentials.Endpoint -eq 'http://127.0.0.1:2222') 'credentials excluded from safe endpoint'
Assert-True (-not (ConvertTo-ProxyEndpoint 'http://localhost:2222/path?token=exampleSecret').Valid) 'URL paths or secrets cannot become endpoint'
Assert-True (-not (ConvertTo-ProxyEndpoint 'http://localhost:99999').Valid) 'invalid port rejected'
Assert-True ((ConvertTo-ProxyEndpoint 'http://[::1]:2222').IsLoopback) 'IPv6 loopback'
Assert-True (Test-ListenerBinding '127.0.0.1' '127.0.0.1') 'exact IPv4 listener'
Assert-True (-not (Test-ListenerBinding '127.0.0.1' '127.0.0.2')) 'same port different explicit address must not match'
Assert-True (Test-ListenerBinding '127.0.0.1' '0.0.0.0') 'IPv4 wildcard covers IPv4 loopback'
Assert-True (-not (Test-ListenerBinding '127.0.0.1' '::')) 'IPv6 wildcard does not imply dual mode'
Assert-True (Test-ListenerBinding 'localhost' '::1') 'localhost allows IPv6 loopback'
Assert-True (-not (Test-ListenerBinding 'unknown.invalid' '0.0.0.0')) 'unresolved host not assumed local'
Assert-True (-not (Test-ListenerBinding '::1' '::2')) 'IPv6 different address rejected'
$fakeListener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
try {
    $fakeListener.Start()
    # TCP accepts into its backlog, but the peer never supplies an HTTP reply.
    # This validates the total read budget using a local fake proxy only.
    $timeoutResult = Test-HttpProxyTls -ProxyHost '127.0.0.1' -ProxyPort $fakeListener.LocalEndpoint.Port -BudgetMs 1000
    Assert-True (-not $timeoutResult.Success -and $timeoutResult.FailureStage -eq 'HttpConnect') 'silent fake proxy is not a success'
    Assert-True ($timeoutResult.DurationMs -lt 5000) 'silent fake proxy has bounded total wait'
} finally { $fakeListener.Stop() }
[pscustomobject]@{ Result = 'PASS'; Checks = $checks; PowerShellVersion = $PSVersionTable.PSVersion.ToString() } | ConvertTo-Json

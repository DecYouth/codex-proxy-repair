#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$tester = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts\Test-CodexProxyConnection.ps1'))
$root = Join-Path $PSScriptRoot ('connection-fixtures-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$fakeExe = Join-Path $root 'fake-codex.exe'
$utf8 = New-Object Text.UTF8Encoding($false)
$passed = 0
function Assert([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw ('Failed: ' + $Name) }
    $script:passed++
}
# Compile only a local fixture; no downloaded binaries or dependency installs.
$className = 'FakeDoctor' + [Guid]::NewGuid().ToString('N')
$source = @'
using System;
using System.IO;
using System.Text;
using System.Threading;
public class CLASSNAME {
 public static void Main(string[] args) {
  string dir=Environment.GetEnvironmentVariable("CODEX_HOME");
  string mode=File.ReadAllText(Path.Combine(dir,"mode.txt"));
  string[] keys={"HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","WS_PROXY","WSS_PROXY","NO_PROXY"};
  using(var w=new StreamWriter(Path.Combine(dir,"observed.txt"),false,new UTF8Encoding(false))) {
   foreach(string key in keys) w.WriteLine(key+"="+(Environment.GetEnvironmentVariable(key)??"<missing>"));
  }
  if(mode=="sleep") { Thread.Sleep(10000); return; }
  if(mode=="flood") { Console.Write(new string('x',3*1024*1024)); return; }
  if(mode=="unsupported") { Console.Error.Write("unrecognized subcommand 'doctor'"); return; }
  Console.Write(File.ReadAllText(Path.Combine(dir,"doctor-report.json")));
 }
}
'@
$source = $source.Replace('CLASSNAME', $className)
if ($PSVersionTable.PSEdition -eq 'Core') {
    # PowerShell 7 cannot emit executable assemblies with Add-Type. Compile the
    # fixture using Windows' built-in .NET Framework PowerShell, then test the
    # production diagnostic script in the current PowerShell 7 process.
    [IO.File]::WriteAllText((Join-Path $root 'fixture.cs'), $source, $utf8)
    $compiler = Join-Path $root 'compile-fixture.ps1'
    [IO.File]::WriteAllText($compiler, @'
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixture.cs'))) -OutputAssembly (Join-Path $PSScriptRoot 'fake-codex.exe') -OutputType ConsoleApplication
'@, $utf8)
    & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -File $compiler
    if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($fakeExe)) { throw 'Local fixture compilation failed.' }
} else {
    Add-Type -TypeDefinition $source -OutputAssembly $fakeExe -OutputType ConsoleApplication
}
function Make-Report {
    return @{
        schemaVersion = 1; codexVersion = '0.160.0'
        checks = @{
            'config.load' = @{ status = 'ok'; details = @{
                CODEX_HOME = $root; 'config.toml' = (Join-Path $root 'config.toml'); cwd = $root; 'model provider' = 'openai'
            }}
            'network.env' = @{ status = 'ok'; details = @{ 'proxy env vars present' = 'HTTP_PROXY, HTTPS_PROXY, NO_PROXY; secret=never-print-this'; 'respect system proxy' = 'disabled' }}
            'network.provider_reachability' = @{ status = 'warning'; details = @{ 'ChatGPT inference URL' = 'https://private.invalid/token-never-print-this reachable (HTTP 405)' }}
            'network.websocket_reachability' = @{ status = 'ok'; details = @{ 'handshake result' = 'HTTP 101 Switching Protocols'; 'supports websockets' = 'true'; 'proxy env vars present' = 'HTTP_PROXY, HTTPS_PROXY' }}
        }
    }
}
function Run-Fixture($Report, [string]$Mode = 'normal', [hashtable]$Options = @{}) {
    [IO.File]::WriteAllText((Join-Path $root 'mode.txt'), $Mode, $utf8)
    [IO.File]::WriteAllText((Join-Path $root 'doctor-report.json'), ($Report | ConvertTo-Json -Depth 10), $utf8)
    $raw = & $tester -CodexExe $fakeExe -CodexHome $root @Options
    Assert (-not ($raw -join '').Contains('never-print-this')) 'raw sensitive diagnostics excluded'
    return ($raw | ConvertFrom-Json)
}
$savedProxy = [Environment]::GetEnvironmentVariable('HTTP_PROXY','Process')
$savedBypass = [Environment]::GetEnvironmentVariable('NO_PROXY','Process')
try {
    [Environment]::SetEnvironmentVariable('HTTP_PROXY','http://caller.invalid:1234','Process')
    [Environment]::SetEnvironmentVariable('NO_PROXY','localhost,fixture.test','Process')
    $result = Run-Fixture (Make-Report)
    Assert ($result.success -and $result.result -eq 'passed') 'explicit 101 succeeds'
    Assert ($result.mode -eq 'existing-persisted-config') 'persistent diagnostic mode'
    $observed = [IO.File]::ReadAllLines((Join-Path $root 'observed.txt'))
    foreach ($key in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','WS_PROXY','WSS_PROXY')) {
        Assert ($observed -contains ($key + '=<missing>')) ('inherited ' + $key + ' cleared')
    }
    Assert ($observed -contains 'NO_PROXY=localhost,fixture.test') 'bypass retained in child'
    Assert ([Environment]::GetEnvironmentVariable('HTTP_PROXY','Process') -eq 'http://caller.invalid:1234') 'caller environment unchanged'
    $result = Run-Fixture (Make-Report) -Options @{ ProxyUrl = 'http://127.0.0.1:34567' }
    Assert ($result.success -and $result.mode -eq 'explicit-candidate') 'candidate diagnostic mode'
    $observed = [IO.File]::ReadAllLines((Join-Path $root 'observed.txt'))
    foreach ($key in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','WS_PROXY','WSS_PROXY')) {
        Assert ($observed -contains ($key + '=http://127.0.0.1:34567')) ('candidate sets ' + $key)
    }
    $report = Make-Report
    $report.checks['network.websocket_reachability'].details.Remove('handshake result')
    $result = Run-Fixture $report
    Assert (-not $result.success -and $result.result -eq 'unknown') 'status ok without 101 is not success'
    $report = Make-Report
    $report.checks['network.websocket_reachability'].details['handshake result'] = 'HTTP 405 Method Not Allowed'
    $result = Run-Fixture $report
    Assert (-not $result.success) 'HTTPS 405 cannot prove WebSocket success'
    $report = Make-Report
    $report.checks['network.websocket_reachability'].status = 'warning'
    $report.checks['network.websocket_reachability'].details.Remove('handshake result')
    $report.checks['network.websocket_reachability'].notes = @('handshake timed out')
    $result = Run-Fixture $report
    Assert (-not $result.success -and $result.result -eq 'failed') 'reported timeout is a failure'
    $report = Make-Report
    $report.checks['network.websocket_reachability'].status = 'warning'
    $report.checks['network.websocket_reachability'].details.Remove('handshake result')
    $report.checks['network.websocket_reachability'].summary = 'Responses WebSocket timed out; HTTPS fallback may still work'
    $result = Run-Fixture $report
    Assert (-not $result.success -and $result.result -eq 'failed') 'summary timeout is classified without exposing summary'
    $report = Make-Report; $report.schemaVersion = 99
    $result = Run-Fixture $report
    Assert (-not $result.success) 'unknown schema fails closed'
    $report = Make-Report; $report.checks['config.load'].details.CODEX_HOME = (Join-Path $root 'different')
    $result = Run-Fixture $report
    Assert (-not $result.success) 'wrong configuration directory is not success'
    $report = Make-Report; $report.checks['config.load'].details['model provider'] = 'other'
    $result = Run-Fixture $report
    Assert (-not $result.success) 'custom provider needs distinct diagnostics'
    $result = Run-Fixture (Make-Report) -Mode 'unsupported'
    Assert (-not $result.success -and $result.reason -eq 'doctor-command-or-json-unsupported') 'unsupported command is explicit'
    $result = Run-Fixture (Make-Report) -Mode 'sleep' -Options @{ TimeoutSeconds = 1 }
    Assert (-not $result.success -and $result.reason -eq 'timeout' -and $result.elapsed_ms -lt 5000) 'bounded child lifetime'
    $result = Run-Fixture (Make-Report) -Mode 'flood'
    Assert (-not $result.success -and $result.reason -eq 'output-limit') 'bounded captured diagnostics'
    $result = Run-Fixture (Make-Report) -Options @{ ProxyUrl = 'http://user:secret@127.0.0.1:34567' }
    Assert (-not $result.success -and $result.reason -eq 'invalid-loopback-http-proxy-url') 'authenticated proxy excluded'
} finally {
    [Environment]::SetEnvironmentVariable('HTTP_PROXY',$savedProxy,'Process')
    [Environment]::SetEnvironmentVariable('NO_PROXY',$savedBypass,'Process')
}
[pscustomobject]@{ Result = 'PASS'; Checks = $passed; PowerShellVersion = $PSVersionTable.PSVersion.ToString() } | ConvertTo-Json

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path $PSScriptRoot) 'bridge-common.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$Temporary = Join-Path ([IO.Path]::GetTempPath()) ('bridge-serve-test-' + [guid]::NewGuid().ToString('N'))
$Executable = Join-Path $Temporary 'serve fixture.exe'
$StatePath = Join-Path $Temporary 'target.txt'
$PidPath = Join-Path $Temporary 'child.pid'
$EnvironmentNames = @('BRIDGE_SERVE_TEST_MODE', 'BRIDGE_SERVE_TEST_STATE', 'BRIDGE_SERVE_TEST_PID')
$OriginalEnvironment = @{}
New-Item -ItemType Directory -Path $Temporary | Out-Null

try {
    foreach ($Name in $EnvironmentNames) { $OriginalEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process') }
    [Environment]::SetEnvironmentVariable('BRIDGE_SERVE_TEST_STATE', $StatePath, 'Process')
    [Environment]::SetEnvironmentVariable('BRIDGE_SERVE_TEST_PID', $PidPath, 'Process')
    Add-Type -OutputAssembly $Executable -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

public static class BridgeServeFixture {
    public static int Main(string[] args) {
        var state = Environment.GetEnvironmentVariable("BRIDGE_SERVE_TEST_STATE");
        if (args.Length >= 2 && args[0] == "serve" && args[1] == "status") {
            var target = File.ReadAllText(state);
            Console.WriteLine("{\"TCP\":{\"8443\":{\"HTTPS\":true}},\"Web\":{\"example.test:8443\":{\"Handlers\":{\"/\":{\"Proxy\":\"" + target + "\"}}}}}");
            return 0;
        }
        if (args.Length != 5 || args[0] != "serve" || args[1] != "--bg" || args[2] != "--yes" || args[3] != "--https=8443") {
            Console.Error.WriteLine("unexpected arguments");
            return 2;
        }
        File.WriteAllText(Environment.GetEnvironmentVariable("BRIDGE_SERVE_TEST_PID"), Process.GetCurrentProcess().Id.ToString());
        var mode = Environment.GetEnvironmentVariable("BRIDGE_SERVE_TEST_MODE");
        if (mode == "error") {
            Console.WriteLine("fixture stdout before failure");
            Console.Error.WriteLine("fixture stderr: configuration rejected");
            return 7;
        }
        if (mode == "authorization") {
            Console.WriteLine("Serve is not enabled on your tailnet. To enable, visit:");
            Console.WriteLine("https://example.test/f/serve?test-only=true");
            Console.Error.WriteLine("fixture stderr: waiting for authorization");
            Thread.Sleep(Timeout.Infinite);
        }
        if (mode == "verbose") {
            Console.WriteLine(new string('o', 128 * 1024));
            Console.Error.WriteLine(new string('e', 128 * 1024));
        }
        File.WriteAllText(state, mode == "wrong-target" ? "http://127.0.0.1:1" : args[4]);
        Console.WriteLine("fixture Serve configured");
        return 0;
    }
}
'@
    $Config = [pscustomobject]@{ TailscalePath = $Executable; HttpsPort = 8443; LocalPort = 8765 }

    foreach ($Mode in @('success', 'verbose')) {
        [Environment]::SetEnvironmentVariable('BRIDGE_SERVE_TEST_MODE', $Mode, 'Process')
        $Result = Set-BridgeServe -Config $Config -LocalPort 8766 -TimeoutSeconds 5
        Assert-True ($null -eq $Result) 'Successful Serve configuration must not leak CLI output into callers.'
        Assert-True ((Get-Content -LiteralPath $StatePath -Raw) -eq 'http://127.0.0.1:8766') 'Serve must use the requested target port.'
        Assert-True ($Config.LocalPort -eq 8765) 'Verification must not mutate the source configuration.'
    }

    [Environment]::SetEnvironmentVariable('BRIDGE_SERVE_TEST_MODE', 'error', 'Process')
    $Failure = $null
    try { Set-BridgeServe -Config $Config -TimeoutSeconds 5 } catch { $Failure = $_.Exception.Message }
    Assert-True ($Failure -like '*exit code 7*') 'A nonzero CLI exit must fail configuration.'
    Assert-True ($Failure -like '*fixture stdout before failure*' -and $Failure -like '*fixture stderr: configuration rejected*') 'CLI errors must preserve both output streams.'

    [Environment]::SetEnvironmentVariable('BRIDGE_SERVE_TEST_MODE', 'wrong-target', 'Process')
    $Failure = $null
    try { Set-BridgeServe -Config $Config -TimeoutSeconds 5 } catch { $Failure = $_.Exception.Message }
    Assert-True ($Failure -like '*configuration verification failed*') 'A zero exit with the wrong target must fail verification.'

    [Environment]::SetEnvironmentVariable('BRIDGE_SERVE_TEST_MODE', 'authorization', 'Process')
    $Failure = $null
    $Elapsed = [Diagnostics.Stopwatch]::StartNew()
    try { Set-BridgeServe -Config $Config -TimeoutSeconds 1 } catch { $Failure = $_.Exception.Message }
    $Elapsed.Stop()
    Assert-True ($Failure -like '*timed out after 1s*') 'An authorization wait must report a timeout.'
    Assert-True ($Failure -like '*Serve is not enabled on your tailnet*' -and $Failure -like '*https://example.test/f/serve?test-only=true*') 'A timeout must retain the authorization prompt and URL.'
    Assert-True ($Failure -like '*fixture stderr: waiting for authorization*') 'A timeout must retain stderr.'
    Assert-True ($Elapsed.Elapsed.TotalSeconds -lt 8) 'An authorization wait must return within its bounded timeout.'
    $ChildId = [int](Get-Content -LiteralPath $PidPath -Raw)
    Assert-True (-not (Get-Process -Id $ChildId -ErrorAction SilentlyContinue)) 'A timed-out child process must be terminated.'
    Write-Output 'serve tests passed'
} finally {
    foreach ($Name in $EnvironmentNames) {
        [Environment]::SetEnvironmentVariable($Name, $OriginalEnvironment[$Name], 'Process')
    }
    $ResolvedTemporary = [IO.Path]::GetFullPath($Temporary)
    $ResolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $ResolvedTemporary.StartsWith($ResolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Test cleanup path is outside the temporary directory: $ResolvedTemporary"
    }
    Remove-Item -LiteralPath $ResolvedTemporary -Recurse -Force
}

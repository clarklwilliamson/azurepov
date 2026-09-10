<#
    Test-DeployedImage.ps1 - runs ON the deployed server, proves the five things survived.

    This is the payoff. The VM this runs on was created from a captured, sysprepped image
    and nobody has touched it since. Everything it reports was baked in at build time.

    Emits one line per check, then a machine-readable block the workflow turns into a
    summary table.
#>
$ErrorActionPreference = 'Continue'
$results = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    $results.Add([pscustomobject]@{ Name = $Name; Pass = $Pass; Detail = $Detail })
}

# 1. Windows Update
$wu     = Get-Service wuauserv -ErrorAction SilentlyContinue
$noAuto = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -ErrorAction SilentlyContinue).NoAutoUpdate
Add-Check 'Windows Update disabled' `
          (($wu.StartType -eq 'Disabled') -and ($noAuto -eq 1)) `
          "wuauserv StartType=$($wu.StartType), NoAutoUpdate=$noAuto (SetupComplete.cmd re-asserts the policy at first boot)"

# 2. Local admin
$user    = Get-LocalUser -Name 'clarkadmin' -ErrorAction SilentlyContinue
$inAdmin = $null -ne (Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like '*\clarkadmin' })
Add-Check 'Local admin created' `
          (($null -ne $user) -and $inAdmin) `
          "clarkadmin exists=$($null -ne $user), in Administrators=$inAdmin"

# 3. Defender
$rt  = (Get-MpPreference -ErrorAction SilentlyContinue).DisableRealtimeMonitoring
$pol = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name DisableAntiSpyware -ErrorAction SilentlyContinue).DisableAntiSpyware
Add-Check 'Defender real-time off' `
          (($rt -eq $true) -or ($pol -eq 1)) `
          "DisableRealtimeMonitoring=$rt, DisableAntiSpyware policy=$pol"

# 4 and 5. The two demo agent services
foreach ($agent in @(
        @{ Svc = 'ClarkQualys';      Dir = 'Qualys' },
        @{ Svc = 'ClarkCrowdStrike'; Dir = 'CrowdStrike' })) {

    $svc     = Get-Service -Name $agent.Svc -ErrorAction SilentlyContinue
    $logPath = "C:\ClarkAgents\$($agent.Dir)\$($agent.Dir.ToLower()).log"
    $log     = @(Get-Content -Path $logPath -ErrorAction SilentlyContinue)
    # "running" is only ever written by the service starting. The build-time seed line
    # says "installed into image", so a running line proves it started on THIS machine.
    $ranHere = @($log | Where-Object { $_ -match 'running' }).Count -gt 0

    Add-Check "$($agent.Svc) service" `
              (($null -ne $svc) -and ($svc.Status -eq 'Running') -and $ranHere) `
              "state=$($svc.Status), start=$($svc.StartType), started-here=$ranHere, log lines=$($log.Count)"

    if ($log) {
        Write-Output ""
        Write-Output "--- $logPath"
        $log | Select-Object -Last 3 | ForEach-Object { Write-Output "    $_" }
    }
}

Write-Output ""
Write-Output "VERIFY-BEGIN"
foreach ($r in $results) {
    $mark = if ($r.Pass) { 'PASS' } else { 'FAIL' }
    Write-Output "$mark|$($r.Name)|$($r.Detail)"
}
Write-Output "VERIFY-END"

if ($results | Where-Object { -not $_.Pass }) { Write-Output "OVERALL|FAIL" } else { Write-Output "OVERALL|PASS" }

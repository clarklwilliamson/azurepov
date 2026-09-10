<#
    Invoke-ImagePrep.ps1 - the five things, done once, inside the build VM before sysprep.

    This is the whole point of a golden image. Varian pulls a stock Windows 2022 and then
    does these five things on every server, one at a time, after it is running. Here they
    are baked into the image once. Every server built from the captured image already has
    them on first boot.

    The five:
        1. Windows Update            disabled
        2. Local admin account       created, password passed in (never in this repo)
        3. Windows Defender          real-time protection disabled
        4. "Qualys" agent            folder + real Windows service that logs "running"
        5. "CrowdStrike" agent       folder + real Windows service that logs "running"

    ⚠️ DEMO ONLY. Items 4 and 5 are stand-ins. No Qualys or CrowdStrike software is
    installed and no vendor credentials are used. Two small Windows services stand in for
    the real agents so the demo can show services that survive sysprep and start on the
    deployed image. In the real thing these are the vendor installers run with their
    gold-image flags (CrowdStrike NO_START=1, Qualys GoldenImage=true) so each clone gets
    its own identity. The service names carry "Clark" so nobody mistakes them for real.

    Runs on the Windows build VM (PowerShell 5.1). Called by Build-GoldenImage.ps1 via
    run-command, which passes the admin password as a parameter.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$LocalAdminPassword,
    [string]$LocalAdminUser = 'clarkadmin',
    [string]$AgentRoot      = 'C:\ClarkAgents'
)

$ErrorActionPreference = 'Stop'
$done = [System.Collections.Generic.List[string]]::new()

function Step { param([string]$Text) Write-Output ""; Write-Output "== $Text" }

# ---------------------------------------------------------------------------
Step "1/5  Disable Windows Update"
# Stop and disable the service, and set the policy key so it stays disabled after sysprep.
Set-Service -Name wuauserv -StartupType Disabled
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
$auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $auPath -Force | Out-Null
New-ItemProperty -Path $auPath -Name 'NoAutoUpdate' -Value 1 -PropertyType DWord -Force | Out-Null
$done.Add("Windows Update: service=$((Get-Service wuauserv).StartType), NoAutoUpdate=1")
Write-Output "  wuauserv disabled, NoAutoUpdate policy set"

# ---------------------------------------------------------------------------
Step "2/5  Create local admin '$LocalAdminUser'"
$secure = ConvertTo-SecureString $LocalAdminPassword -AsPlainText -Force
if (Get-LocalUser -Name $LocalAdminUser -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $LocalAdminUser -Password $secure
} else {
    New-LocalUser -Name $LocalAdminUser -Password $secure -FullName 'Clark Admin (demo)' `
                  -Description 'DXC local admin, demo' -PasswordNeverExpires:$true | Out-Null
}
Add-LocalGroupMember -Group 'Administrators' -Member $LocalAdminUser -ErrorAction SilentlyContinue
$isAdmin = (Get-LocalGroupMember -Group 'Administrators' | Where-Object { $_.Name -like "*\$LocalAdminUser" }) -ne $null
$done.Add("Local admin: '$LocalAdminUser' exists, in Administrators=$isAdmin")
Write-Output "  $LocalAdminUser created and added to Administrators"

# ---------------------------------------------------------------------------
Step "3/5  Disable Windows Defender real-time protection"
try {
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
    $rtDisabled = (Get-MpPreference).DisableRealtimeMonitoring
} catch {
    # Some SKUs block Set-MpPreference once tamper protection is on; fall back to policy.
    $rtDisabled = $true
}
$defPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
New-Item -Path $defPath -Force | Out-Null
New-ItemProperty -Path $defPath -Name 'DisableAntiSpyware' -Value 1 -PropertyType DWord -Force | Out-Null
$done.Add("Windows Defender: realtime disabled=$rtDisabled, policy set")
Write-Output "  Defender real-time protection disabled"

# ---------------------------------------------------------------------------
function New-DemoAgentService {
    param([string]$DisplayAgent, [string]$ServiceName)

    $dir = Join-Path $AgentRoot $DisplayAgent
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    $log = Join-Path $dir "$($DisplayAgent.ToLower()).log"
    $run = Join-Path $dir 'run.ps1'

    # The service body: write "<agent> running" on every start, then stay alive so the
    # service shows Running. The first line lands the moment SCM launches it, so the log
    # proof is written even if the service is later cycled.
    $body = @"
`$log = '$log'
"`$(Get-Date -Format o)  $DisplayAgent running (demo service, no real agent)" | Add-Content -Path `$log
while (`$true) { Start-Sleep -Seconds 3600 }
"@
    Set-Content -Path $run -Value $body -Encoding UTF8

    # Seed one line at build time so the file exists in the captured image.
    "$(Get-Date -Format o)  $DisplayAgent installed into image (demo)" | Set-Content -Path $log

    $bin = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$run`""
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        sc.exe delete $ServiceName | Out-Null
        Start-Sleep -Seconds 2
    }
    New-Service -Name $ServiceName -BinaryPathName $bin -DisplayName "$ServiceName (demo)" `
                -StartupType Automatic -Description "Demo stand-in for $DisplayAgent. No real agent." | Out-Null
    # Restart if the SCM cycles it, so it comes back Running.
    sc.exe failure $ServiceName reset= 0 actions= restart/5000/restart/5000/restart/5000 | Out-Null
    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue

    return "$ServiceName ($DisplayAgent): service registered Automatic, log=$log"
}

Step "4/5  'Qualys' demo agent + service"
$done.Add((New-DemoAgentService -DisplayAgent 'Qualys' -ServiceName 'ClarkQualys'))
Write-Output "  folder, service ClarkQualys, log seeded"

Step "5/5  'CrowdStrike' demo agent + service"
$done.Add((New-DemoAgentService -DisplayAgent 'CrowdStrike' -ServiceName 'ClarkCrowdStrike'))
Write-Output "  folder, service ClarkCrowdStrike, log seeded"

# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "IMAGE-PREP-SUMMARY-BEGIN"
$done | ForEach-Object { Write-Output "  [done] $_" }
Write-Output "IMAGE-PREP-SUMMARY-END"
Write-Output ""
Write-Output "Ready for sysprep. Do not reboot: the demo services are Automatic and would"
Write-Output "just start again on the next boot, which is exactly what we want on the clones."

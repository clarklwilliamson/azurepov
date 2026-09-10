<#
    Invoke-ImagePrep.ps1 - the five things, done once, inside the build VM before sysprep.

    This is the whole point of a golden image. The usual pattern is to pull a stock
    Windows 2022 and then do these five things on every server, one at a time, after it
    is running. Here they are baked into the image once, so every server built from the
    captured image already has them on first boot.

    The five:
        1. Windows Update            disabled
        2. Local admin account       created, password passed in (never in this repo)
        3. Windows Defender          real-time protection disabled
        4. "Qualys" agent            folder + real Windows service that logs "running"
        5. "CrowdStrike" agent       folder + real Windows service that logs "running"

    ⚠️ DEMO ONLY. Items 4 and 5 are stand-ins. No Qualys or CrowdStrike software is
    installed and no vendor credentials are used. Two small Windows services stand in for
    the real agents so the demo can show services that survive sysprep and start on their
    own on the deployed image. In the real thing these are the vendor installers run with
    their gold-image flags (CrowdStrike NO_START=1, Qualys GoldenImage=true) so each clone
    gets its own identity. The service names carry "Clark" so nobody mistakes them for real.

    Runs on the Windows build VM (PowerShell 5.1), called by Build-GoldenImage.ps1.
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
                  -Description 'Local admin, demo' -PasswordNeverExpires:$true | Out-Null
}
Add-LocalGroupMember -Group 'Administrators' -Member $LocalAdminUser -ErrorAction SilentlyContinue
$isAdmin = $null -ne (Get-LocalGroupMember -Group 'Administrators' | Where-Object { $_.Name -like "*\$LocalAdminUser" })
$done.Add("Local admin: '$LocalAdminUser' exists, in Administrators=$isAdmin")
Write-Output "  $LocalAdminUser created and added to Administrators"

# ---------------------------------------------------------------------------
Step "3/5  Disable Windows Defender real-time protection"
try   { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop }
catch { Write-Output "  Set-MpPreference blocked (tamper protection); relying on policy" }
$defPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
New-Item -Path $defPath -Force | Out-Null
New-ItemProperty -Path $defPath -Name 'DisableAntiSpyware' -Value 1 -PropertyType DWord -Force | Out-Null
$done.Add("Windows Defender: DisableAntiSpyware policy set")
Write-Output "  Defender real-time protection disabled"

# ---------------------------------------------------------------------------
# A Windows service has to answer the Service Control Manager within 30 seconds or the
# SCM kills it with error 1053. "powershell.exe -File script.ps1" never answers, so it
# registers fine, survives sysprep, and then refuses to start on every clone. Compiling
# a real ServiceBase is the only way to get a service that actually runs, and the C#
# compiler needed for it ships in the box.
# ---------------------------------------------------------------------------
function New-DemoAgentService {
    param([string]$DisplayAgent, [string]$ServiceName)

    $dir = Join-Path $AgentRoot $DisplayAgent
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    $log = Join-Path $dir "$($DisplayAgent.ToLower()).log"
    $exe = Join-Path $dir "$ServiceName.exe"
    $cs  = Join-Path $dir "$ServiceName.cs"

    $source = @"
using System;
using System.IO;
using System.ServiceProcess;

public class DemoAgent : ServiceBase
{
    const string AgentName = "$DisplayAgent";
    const string LogPath   = @"$log";

    public DemoAgent() { this.ServiceName = "$ServiceName"; }

    void Write(string what)
    {
        try {
            File.AppendAllText(LogPath,
                DateTime.UtcNow.ToString("o") + "  " + AgentName + " " + what +
                " (demo service, no real agent)" + Environment.NewLine);
        } catch { }
    }

    protected override void OnStart(string[] args) { Write("running"); }
    protected override void OnStop()               { Write("stopped"); }

    public static void Main() { ServiceBase.Run(new DemoAgent()); }
}
"@
    Set-Content -Path $cs -Value $source -Encoding UTF8

    $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $csc)) { throw "csc.exe not found at $csc" }
    $compile = & $csc /nologo /target:exe /optimize+ "/out:$exe" `
                      /reference:System.ServiceProcess.dll "$cs" 2>&1
    if (-not (Test-Path $exe)) { throw "compile failed for $ServiceName :`n$compile" }

    # Seed one line so the file exists in the captured image, then the service adds its
    # own "running" line on every boot of every machine built from that image.
    "$(Get-Date -Format o)  $DisplayAgent installed into image (demo)" | Set-Content -Path $log

    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        sc.exe delete $ServiceName | Out-Null
        Start-Sleep -Seconds 2
    }
    New-Service -Name $ServiceName -BinaryPathName $exe -DisplayName "$ServiceName (demo)" `
                -StartupType Automatic -Description "Demo stand-in for $DisplayAgent. No real agent." | Out-Null
    sc.exe failure $ServiceName reset= 0 actions= restart/5000/restart/5000/restart/5000 | Out-Null

    Start-Service -Name $ServiceName
    Start-Sleep -Seconds 2
    $state = (Get-Service -Name $ServiceName).Status
    if ($state -ne 'Running') { throw "$ServiceName compiled and registered but will not run (state=$state)." }

    return "$ServiceName ($DisplayAgent): compiled service, state=$state, Automatic, log=$log"
}

Step "4/5  'Qualys' demo agent + service"
$done.Add((New-DemoAgentService -DisplayAgent 'Qualys' -ServiceName 'ClarkQualys'))
Write-Output "  folder, compiled service ClarkQualys, running"

Step "5/5  'CrowdStrike' demo agent + service"
$done.Add((New-DemoAgentService -DisplayAgent 'CrowdStrike' -ServiceName 'ClarkCrowdStrike'))
Write-Output "  folder, compiled service ClarkCrowdStrike, running"

# ---------------------------------------------------------------------------
# Sysprep /generalize clears some HKLM policy, and the Windows Update AU key is one of
# them: it reads back as 0 on the deployed machine even though it was 1 at capture.
# SetupComplete.cmd is the supported first-boot hook on a sysprepped image, so re-assert
# it there rather than pretending the policy survived.
# ---------------------------------------------------------------------------
Step "first-boot hook to re-assert what sysprep clears"
$scriptDir = Join-Path $env:SystemRoot 'Setup\Scripts'
New-Item -Path $scriptDir -ItemType Directory -Force | Out-Null
@'
@echo off
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiSpyware /t REG_DWORD /d 1 /f
sc config wuauserv start= disabled
exit /b 0
'@ | Set-Content -Path (Join-Path $scriptDir 'SetupComplete.cmd') -Encoding Ascii
Write-Output "  $scriptDir\SetupComplete.cmd written"
$done.Add("First-boot hook: SetupComplete.cmd re-asserts the update and Defender policy")

# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "IMAGE-PREP-SUMMARY-BEGIN"
$done | ForEach-Object { Write-Output "  [done] $_" }
Write-Output "IMAGE-PREP-SUMMARY-END"
Write-Output ""
Write-Output "Ready for sysprep."

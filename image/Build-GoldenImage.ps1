<#
    Build-GoldenImage.ps1 - build a Windows image, capture it into the gallery.

    The whole loop:

        1. create a build VM from a marketplace image, pinned to an exact version
        2. run Install-Agents.ps1 inside it, which installs both agents inert
        3. sysprep /generalize /oobe /shutdown
        4. deallocate, generalize, capture as a numbered gallery image version
        5. delete the build VM and everything it brought with it

    Step 3 is the one that matters. Sysprep strips the machine identity: the SID, the
    computer name, the activation state. Without it every clone is the same machine
    wearing a different name, which is what makes cloning a bad word.

    .EXAMPLE
        pwsh ./image/Build-GoldenImage.ps1 `
            -ResourceGroup pov-images -GalleryName povgallery `
            -ImageDefinition win2022-hardened -ImageVersion 1.0.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [Parameter(Mandatory)] [string]$GalleryName,
    [string]$ImageDefinition = 'win2022-hardened',
    [Parameter(Mandatory)] [string]$ImageVersion,

    [string]$Location      = 'westus3',
    [string]$BuildVmName   = "imgbuild-$(Get-Random -Minimum 1000 -Maximum 9999)",
    # DDSv5 family quota is 0 on a fresh subscription. DSv3 has 10.
    [string]$BuildVmSize   = 'Standard_D2s_v3',
    [string]$AdminUsername = 'imgbuilder',

    # The demo local-admin password, baked into the image by Invoke-ImagePrep.ps1.
    # Passed in from a GitHub secret; never defaulted, never committed.
    [Parameter(Mandatory)] [string]$LocalAdminPassword,

    # Pinned on purpose. 'latest' here would mean two image versions built a week apart
    # start from different Windows builds, which is the problem this repo exists to fix.
    [string]$SourceImage   = 'MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:20348.2582.240619',

    [switch]$KeepBuildVm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Args)
    Write-Verbose "az $($Args -join ' ')"
    $out = & az @Args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Args -join ' ') failed:`n$out" }
    return $out
}

function Write-Step { param([string]$Text) Write-Host ""; Write-Host "== $Text" }

$adminPassword = -join ((65..90) + (97..122) + (48..57) + (33,35,37,64) | Get-Random -Count 24 | ForEach-Object { [char]$_ })

try {
    Write-Step "1/5  build VM $BuildVmName from $SourceImage"
    Invoke-Az group create --name $ResourceGroup --location $Location --output none
    Invoke-Az vm create `
        --resource-group $ResourceGroup --name $BuildVmName --location $Location `
        --image $SourceImage --size $BuildVmSize `
        --admin-username $AdminUsername --admin-password $adminPassword `
        --security-type TrustedLaunch --nsg-rule NONE --public-ip-address '' `
        --output none
    Write-Host "  created"

    Write-Step "2/5  the five things"
    $prepScript = Join-Path $PSScriptRoot 'Invoke-ImagePrep.ps1'
    if (-not (Test-Path $prepScript)) { throw "Invoke-ImagePrep.ps1 not found next to this script." }

    # The password travels as a run-command parameter, so it is never written to disk on
    # the build VM and never appears in this repository.
    $prepOut = Invoke-Az vm run-command invoke `
        --resource-group $ResourceGroup --name $BuildVmName `
        --command-id RunPowerShellScript --scripts "@$prepScript" `
        --parameters "LocalAdminPassword=$LocalAdminPassword" `
        --query "value[0].message" -o tsv

    # Echo just the summary block the prep script emits, not the whole stream.
    $inSummary = $false
    foreach ($line in ($prepOut -split "`n")) {
        if ($line -match 'IMAGE-PREP-SUMMARY-BEGIN') { $inSummary = $true; continue }
        if ($line -match 'IMAGE-PREP-SUMMARY-END')   { $inSummary = $false; continue }
        if ($inSummary) { Write-Host $line }
    }
    if ($prepOut -notmatch 'IMAGE-PREP-SUMMARY-END') {
        throw "Image prep did not finish. Output:`n$prepOut"
    }

    Write-Step "3/5  sysprep and shut down"
    # /generalize strips the SID, the computer name and the activation state. Without it
    # every clone is the same machine wearing a different name.
    $sysprep = @'
Start-Process -FilePath "$env:SystemRoot\System32\Sysprep\Sysprep.exe" `
              -ArgumentList '/generalize','/oobe','/shutdown','/quiet','/mode:vm' `
              -Wait -NoNewWindow
'@
    Invoke-Az vm run-command invoke `
        --resource-group $ResourceGroup --name $BuildVmName `
        --command-id RunPowerShellScript --scripts $sysprep `
        --output none

    Write-Host "  waiting for the VM to stop"
    $deadline = (Get-Date).AddMinutes(20)
    do {
        Start-Sleep -Seconds 20
        $state = (Invoke-Az vm get-instance-view -g $ResourceGroup -n $BuildVmName `
                    --query "instanceView.statuses[?starts_with(code,'PowerState/')].code" -o tsv) -join ''
        Write-Host "    $state"
        if ((Get-Date) -gt $deadline) { throw "Sysprep did not shut the VM down within 20 minutes." }
    } until ($state -match 'stopped|deallocated')

    Write-Step "4/5  generalize and capture as version $ImageVersion"
    Invoke-Az vm deallocate --resource-group $ResourceGroup --name $BuildVmName --output none
    Invoke-Az vm generalize --resource-group $ResourceGroup --name $BuildVmName --output none

    $vmId = (Invoke-Az vm show -g $ResourceGroup -n $BuildVmName --query id -o tsv) -join ''
    Invoke-Az sig image-version create `
        --resource-group $ResourceGroup --gallery-name $GalleryName `
        --gallery-image-definition $ImageDefinition --gallery-image-version $ImageVersion `
        --virtual-machine $vmId `
        --output none

    $versionId = (Invoke-Az sig image-version show `
        --resource-group $ResourceGroup --gallery-name $GalleryName `
        --gallery-image-definition $ImageDefinition --gallery-image-version $ImageVersion `
        --query id -o tsv) -join ''

    Write-Step "5/5  clean up"
    if ($KeepBuildVm) {
        Write-Host "  keeping $BuildVmName as asked"
    }
    else {
        Invoke-Az vm delete --resource-group $ResourceGroup --name $BuildVmName --yes --output none
        Write-Host "  build VM deleted"
    }

    Write-Host ""
    Write-Host "Image version captured."
    Write-Host "  $versionId"
    Write-Host ""
    Write-Host "Build a server from exactly this disk:"
    Write-Host "  az deployment group create -g $ResourceGroup ``"
    Write-Host "     --template-file infra/vm-from-gallery.bicep ``"
    Write-Host "     --parameters imageVersionId=$versionId adminPassword=<pw>"
}
catch {
    Write-Host ""
    Write-Error $_.Exception.Message
    Write-Host "Build VM '$BuildVmName' left in place for inspection. Delete it with:"
    Write-Host "  az vm delete -g $ResourceGroup -n $BuildVmName --yes"
    exit 1
}

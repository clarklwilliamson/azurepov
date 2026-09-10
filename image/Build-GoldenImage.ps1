<#
    Build-GoldenImage.ps1 - build a Windows image, capture it into the gallery.

    The whole loop:

        1. create a build VM from a marketplace image, pinned to an exact version
        2. run Invoke-ImagePrep.ps1 inside it, which does the five things
        3. sysprep /generalize /oobe /shutdown
        4. deallocate, generalize, capture as a numbered gallery image version
        5. delete the build VM and everything it brought with it

    Step 3 is the one that matters. Sysprep strips the machine identity: the SID, the
    computer name, the activation state. Without it every clone is the same machine
    wearing a different name, which is what makes cloning a bad word.

    .EXAMPLE
        pwsh ./image/Build-GoldenImage.ps1 `
            -ResourceGroup pov-images -GalleryName povgallery `
            -ImageDefinition win2022-clarkdemo -ImageVersion 1.0.0 -LocalAdminPassword <pw>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [Parameter(Mandatory)] [string]$GalleryName,
    [string]$ImageDefinition = 'win2022-clarkdemo',
    [Parameter(Mandatory)] [string]$ImageVersion,

    [string]$Location      = 'westus3',
    [string]$BuildVmName   = "imgbuild-$(Get-Random -Minimum 1000 -Maximum 9999)",
    # On a fresh subscription most families are either quota 0 or NotAvailableForSubscription.
    # D2ads_v6 is the small size that is both unrestricted and has quota in westus3.
    [string]$BuildVmSize   = 'Standard_D2ads_v6',
    [string]$AdminUsername = 'imgbuilder',

    # The demo local-admin password, baked into the image by Invoke-ImagePrep.ps1.
    # Passed in from a GitHub secret; never defaulted, never committed.
    [Parameter(Mandatory)] [string]$LocalAdminPassword,

    # Pinned on purpose. 'latest' here would mean two image versions built a week apart
    # start from different Windows builds, which is the problem this repo exists to fix.
    [string]$SourceImage   = 'MicrosoftWindowsServer:windowsserver2022:2022-datacenter-azure-edition-smalldisk:20348.5622.260906',

    [switch]$KeepBuildVm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No param block on purpose. An advanced function tries to bind leading-dash tokens to
# its own parameters, so a trailing "-o tsv" fails with "the parameter name 'o' is
# ambiguous". A plain function collects everything in $args and passes it straight through.
function Invoke-Az {
    $azArgs = $args
    Write-Verbose "az $($azArgs -join ' ')"
    # az writes progress and warnings to stderr. With 2>&1 those arrive as ErrorRecords,
    # and under $ErrorActionPreference='Stop' PowerShell 7 promotes them to terminating
    # errors, so a command that succeeded still blows up the script. Drop to Continue for
    # the duration of the call and judge the result on the exit code alone.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out  = & az @azArgs 2>&1
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) { throw "az $($azArgs -join ' ') failed (exit $code):`n$out" }
    return $out
}

function Write-Step { param([string]$Text) Write-Host ""; Write-Host "== $Text" }

# Reuse the passed-in secret for the build VM too. A locally generated one is not known
# to GitHub, so it would appear in clear text if az echoes the failing command.
$adminPassword = $LocalAdminPassword

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
        --query "value[0].message" --output tsv

    # az --output tsv hands back an ARRAY when the value spans lines. `-notmatch` against
    # an array FILTERS it and returns the non-matching elements, so `if ($array -notmatch
    # 'x')` is truthy whenever any single line lacks 'x'. Flatten to one string first.
    # (Same trap as reading a verdict out of $tmpvar[$tmpvar.Count-1].)
    $prepText = ($prepOut | Out-String)

    # Echo just the summary block the prep script emits, not the whole stream.
    $inSummary = $false
    foreach ($line in ($prepText -split "`r?`n")) {
        if ($line -match 'IMAGE-PREP-SUMMARY-BEGIN') { $inSummary = $true; continue }
        if ($line -match 'IMAGE-PREP-SUMMARY-END')   { $inSummary = $false; continue }
        if ($inSummary -and $line.Trim()) { Write-Host $line }
    }
    if ($prepText -notmatch 'IMAGE-PREP-SUMMARY-END') {
        throw "Image prep did not finish. Output:`n$prepText"
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
        $state = (Invoke-Az vm get-instance-view --resource-group $ResourceGroup --name $BuildVmName `
                    --query "instanceView.statuses[?starts_with(code,'PowerState/')].code" --output tsv) -join ''
        Write-Host "    $state"
        if ((Get-Date) -gt $deadline) { throw "Sysprep did not shut the VM down within 20 minutes." }
    } until ($state -match 'stopped|deallocated')

    Write-Step "4/5  generalize and capture as version $ImageVersion"
    Invoke-Az vm deallocate --resource-group $ResourceGroup --name $BuildVmName --output none
    Invoke-Az vm generalize --resource-group $ResourceGroup --name $BuildVmName --output none

    $vmId = (Invoke-Az vm show --resource-group $ResourceGroup --name $BuildVmName --query id --output tsv) -join ''
    Invoke-Az sig image-version create `
        --resource-group $ResourceGroup --gallery-name $GalleryName `
        --gallery-image-definition $ImageDefinition --gallery-image-version $ImageVersion `
        --virtual-machine $vmId `
        --output none

    $versionId = (Invoke-Az sig image-version show `
        --resource-group $ResourceGroup --gallery-name $GalleryName `
        --gallery-image-definition $ImageDefinition --gallery-image-version $ImageVersion `
        --query id --output tsv) -join ''

    Write-Step "5/5  clean up"
    if ($KeepBuildVm) {
        Write-Host "  keeping $BuildVmName as asked"
    }
    else {
        Invoke-Az vm delete --resource-group $ResourceGroup --name $BuildVmName --yes --output none
        # az vm delete removes only the VM. The NIC, OS disk, NSG and VNet it created are
        # left behind and keep costing money, so sweep anything named after the build VM.
        $strays = (Invoke-Az resource list --resource-group $ResourceGroup `
                     --query "[?starts_with(name, '$BuildVmName')].id" --output tsv)
        foreach ($id in @($strays)) {
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            try { Invoke-Az resource delete --ids $id --output none } catch { }
        }
        # NIC before VNet, so take a second pass for anything that was still attached.
        $strays = (Invoke-Az resource list --resource-group $ResourceGroup `
                     --query "[?starts_with(name, '$BuildVmName')].id" --output tsv)
        foreach ($id in @($strays)) {
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            try { Invoke-Az resource delete --ids $id --output none } catch { }
        }
        Write-Host "  build VM and its disk, NIC, NSG and VNet deleted"
    }

    Write-Host ""
    Write-Host "Image version captured."
    Write-Host "  $versionId"
    Write-Host ""
    Write-Host "Build a server from exactly this disk:"
    Write-Host "  az vm create -g $ResourceGroup -n mysrv --image $versionId ``"
    Write-Host "     --size Standard_D2ads_v6 --admin-username imgbuilder --admin-password <pw>"
}
catch {
    Write-Host ""
    Write-Error $_.Exception.Message
    Write-Host "Build VM '$BuildVmName' left in place for inspection. Delete it with:"
    Write-Host "  az vm delete -g $ResourceGroup -n $BuildVmName --yes"
    exit 1
}

<#
.SYNOPSIS
    Deploys the Azure shared-storage IOPS lab.

.EXAMPLE
    .\deploy.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" `
                 -ResourceGroup rg-storage-iops-lab `
                 -Location westus3 `
                 -SshPublicKeyPath $HOME\.ssh\anf_lab.pub `
                 -SshSourceAddressPrefix "$((Invoke-RestMethod https://api.ipify.org))/32"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $SubscriptionId,
    [Parameter(Mandatory = $true)] [string] $ResourceGroup,
    [string] $Location = 'westus3',
    [Parameter(Mandatory = $true)] [string] $SshPublicKeyPath,
    [string] $SshSourceAddressPrefix = '*',
    [string] $NamePrefix = 'iopslab',
    [string] $VmSize = 'Standard_D8s_v5',
    [ValidateSet('1','2','3')] [string] $AlignedZone = '1',
    [ValidateSet('1','2','3')] [string] $MisalignedZone = '2',
    [ValidateSet('Standard','Premium','Ultra')] [string] $AnfServiceLevel = 'Premium',
    [int] $AnfPoolSizeTiB = 4,
    [int] $AnfVolumeSizeGiB = 2048,
    [int] $FileShareQuotaGiB = 100
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Test-Path $SshPublicKeyPath)) {
    throw "SSH public key not found at $SshPublicKeyPath"
}
$sshKey = (Get-Content $SshPublicKeyPath -Raw).Trim()

Write-Host "==> Selecting subscription $SubscriptionId" -ForegroundColor Cyan
az account set --subscription $SubscriptionId | Out-Null

Write-Host "==> Registering required resource providers (idempotent)" -ForegroundColor Cyan
foreach ($provider in 'Microsoft.NetApp','Microsoft.Storage','Microsoft.Compute','Microsoft.Network') {
    az provider register --namespace $provider --wait | Out-Null
}

Write-Host "==> Creating resource group $ResourceGroup in $Location" -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location | Out-Null

$deploymentName = "storage-iops-lab-$(Get-Date -Format yyyyMMddHHmmss)"
Write-Host "==> Deploying Bicep ($deploymentName) - this takes ~15-20 minutes" -ForegroundColor Cyan

$deployJson = az deployment group create `
    --name $deploymentName `
    --resource-group $ResourceGroup `
    --template-file (Join-Path $here 'main.bicep') `
    --parameters `
        location=$Location `
        namePrefix=$NamePrefix `
        sshPublicKey="$sshKey" `
        sshSourceAddressPrefix=$SshSourceAddressPrefix `
        vmSize=$VmSize `
        alignedZone=$AlignedZone `
        misalignedZone=$MisalignedZone `
        anfServiceLevel=$AnfServiceLevel `
        anfPoolSizeTiB=$AnfPoolSizeTiB `
        anfVolumeSizeGiB=$AnfVolumeSizeGiB `
        fileShareQuotaGiB=$FileShareQuotaGiB `
    --output json

if ($LASTEXITCODE -ne 0) {
    throw "Bicep deployment failed (exit $LASTEXITCODE). See error above. Aborting."
}

$result = $deployJson | ConvertFrom-Json
$o = $result.properties.outputs

Write-Host "==> Reading storage account keys" -ForegroundColor Cyan
$smbKey = (az storage account keys list --account-name $o.smbAccount.value --resource-group $ResourceGroup --query '[0].value' -o tsv)
if ($LASTEXITCODE -ne 0 -or -not $smbKey) {
    throw "Failed to read SMB storage account key. Aborting."
}

$summary = [ordered]@{
    resourceGroup     = $ResourceGroup
    location          = $Location
    alignedVmName     = $o.alignedVmName.value
    alignedVmIp       = $o.alignedVmIp.value
    misalignedVmName  = $o.misalignedVmName.value
    misalignedVmIp    = $o.misalignedVmIp.value
    adminUsername     = $o.adminUsername.value
    smbAccount        = $o.smbAccount.value
    smbShare          = $o.smbShare.value
    smbKey            = $smbKey
    nfsAccount        = $o.nfsAccount.value
    nfsShare          = $o.nfsShare.value
    anfMountIp        = $o.anfMountIp.value
    anfMountPath      = $o.anfMountPath.value
    anfZone           = $o.anfZone.value
}
$summary | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $here 'lab-output.json')

Write-Host ""
Write-Host "==> Deployment complete" -ForegroundColor Green
Write-Host ""
$summary.GetEnumerator() | ForEach-Object {
    if ($_.Key -eq 'smbKey') {
        Write-Host ("  {0,-18} <hidden, written to lab-output.json>" -f $_.Key)
    } else {
        Write-Host ("  {0,-18} {1}" -f $_.Key, $_.Value)
    }
}

# Copy helper scripts to both VMs
$scriptsDir   = Join-Path (Split-Path $here -Parent) 'scripts'
$setupScript  = Join-Path $scriptsDir 'setup-vm.sh'
$fioScript    = Join-Path $scriptsDir 'run-fio-tests.sh'
$sshKeyPriv   = $SshPublicKeyPath.TrimEnd('.pub')
if (-not (Test-Path $sshKeyPriv)) { $sshKeyPriv = $SshPublicKeyPath -replace '\.pub$','' }

foreach ($pair in @(
        @{ Name = $summary.alignedVmName;    Ip = $summary.alignedVmIp    },
        @{ Name = $summary.misalignedVmName; Ip = $summary.misalignedVmIp })) {
    Write-Host ""
    Write-Host "==> Copying helper scripts to $($pair.Name) ($($pair.Ip))" -ForegroundColor Cyan
    & ssh-keygen -R $pair.Ip 2>$null | Out-Null
    & scp -i $sshKeyPriv -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
        $setupScript $fioScript "$($summary.adminUsername)@$($pair.Ip):/tmp/"
}

Write-Host ""
Write-Host "==> Next steps" -ForegroundColor Yellow
Write-Host "  1) Mount shares on both VMs:" -ForegroundColor Yellow
Write-Host "       ssh -i $sshKeyPriv $($summary.adminUsername)@$($summary.alignedVmIp) ``"
Write-Host "         ""sudo bash /tmp/setup-vm.sh '$($summary.smbAccount)' '<SMB_KEY>' '$($summary.nfsAccount)' '$($summary.anfMountIp)' '$($summary.anfMountPath)'"""
Write-Host "     (Get <SMB_KEY> from lab-output.json -> smbKey)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  2) Run the fio tests:" -ForegroundColor Yellow
Write-Host "       ssh -i $sshKeyPriv $($summary.adminUsername)@$($summary.alignedVmIp) ""bash /tmp/run-fio-tests.sh"""
Write-Host "       ssh -i $sshKeyPriv $($summary.adminUsername)@$($summary.misalignedVmIp) ""bash /tmp/run-fio-tests.sh"""

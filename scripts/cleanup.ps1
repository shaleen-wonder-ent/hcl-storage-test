[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ResourceGroup,
    [string] $SubscriptionId
)
$ErrorActionPreference = 'Stop'
if ($SubscriptionId) { az account set --subscription $SubscriptionId | Out-Null }

Write-Host "==> Deleting resource group $ResourceGroup (no-wait)" -ForegroundColor Yellow
az group delete --name $ResourceGroup --yes --no-wait
Write-Host "==> Submitted. Use 'az group show -n $ResourceGroup' to track."

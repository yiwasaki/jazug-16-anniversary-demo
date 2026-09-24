# ============================================================
# disable-package-upload-access.ps1
# 操作者 IP ルールを削除し、Storage Account の Public endpoint を無効化する (PowerShell 版)
#
# Usage:
#   pwsh ./scripts/disable-package-upload-access.ps1 `
#        -ResourceGroupName rg-gcpolicy `
#        -StorageAccountName <sa> `
#        -OperatorPublicIp <ipv4>
#
# 前提条件:
#   Connect-AzAccount でログイン済みであること
# ============================================================

#Requires -Modules Az.Accounts, Az.Storage

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$OperatorPublicIp
)

$ErrorActionPreference = 'Stop'

if (-not (Get-AzContext)) {
    throw "Azure にログインしていません。'Connect-AzAccount' を実行してください。"
}

Write-Host '===== Disable Package Upload Access =====' -ForegroundColor Cyan

Write-Host '[INFO] 操作者 IP ルールを削除します。' -ForegroundColor Yellow
try {
    Remove-AzStorageAccountNetworkRule -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -IPAddressOrRange $OperatorPublicIp | Out-Null
}
catch {
    Write-Host '[WARN] IP ルールを削除できませんでした。Public network access の無効化を続行します。' -ForegroundColor Yellow
}

Write-Host '[INFO] Public network access を無効化します。' -ForegroundColor Yellow
Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -PublicNetworkAccess Disabled -Force | Out-Null

$publicNetworkAccess = (Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName).PublicNetworkAccess
$networkRules = Get-AzStorageAccountNetworkRuleSet -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
$ipRuleCount = @($networkRules.IpRules | Where-Object { $_.IPAddressOrRange -eq $OperatorPublicIp }).Count

if ($publicNetworkAccess -ne 'Disabled' -or "$ipRuleCount" -ne '0') {
    throw "[FAIL] Storage firewall を安全な状態へ戻せませんでした (access=$publicNetworkAccess, ipRuleCount=$ipRuleCount)。"
}

Write-Host "[PASS] Public network access: $publicNetworkAccess" -ForegroundColor Green
Write-Host "[PASS] Removed operator IP: $OperatorPublicIp" -ForegroundColor Green

# ============================================================
# enable-package-upload-access.ps1
# Storage Account の Public endpoint と操作者 IP を一時許可する (PowerShell 版)
#
# Usage:
#   pwsh ./scripts/enable-package-upload-access.ps1 `
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

if ($OperatorPublicIp -notmatch '^(\d{1,3}\.){3}\d{1,3}$') {
    throw "Public IPv4 address を指定してください: $OperatorPublicIp"
}

if (-not (Get-AzContext)) {
    throw "Azure にログインしていません。'Connect-AzAccount' を実行してください。"
}

Write-Host '===== Enable Package Upload Access =====' -ForegroundColor Cyan

Write-Host '[INFO] Public network access を有効化します。' -ForegroundColor Yellow
try {
    Update-AzStorageAccountNetworkRuleSet -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -DefaultAction Deny | Out-Null
    Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -PublicNetworkAccess Enabled -Force | Out-Null
    Write-Host '[INFO] 操作者 IP を許可します。' -ForegroundColor Yellow
    Add-AzStorageAccountNetworkRule -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -IPAddressOrRange $OperatorPublicIp | Out-Null
}
catch {
    Write-Host '[ERROR] IP ルールを追加できなかったため、Public network access を無効化します。' -ForegroundColor Red
    Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -PublicNetworkAccess Disabled -Force | Out-Null
    throw
}

$publicNetworkAccess = (Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName).PublicNetworkAccess
$networkRules = Get-AzStorageAccountNetworkRuleSet -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
$ipRuleCount = @($networkRules.IpRules | Where-Object { $_.IPAddressOrRange -eq $OperatorPublicIp }).Count

if ($publicNetworkAccess -ne 'Enabled' -or "$ipRuleCount" -ne '1') {
    throw "[FAIL] Storage firewall の許可状態を確認できませんでした (access=$publicNetworkAccess, ipRuleCount=$ipRuleCount)。"
}

Write-Host "[PASS] Public network access: $publicNetworkAccess" -ForegroundColor Green
Write-Host "[PASS] Allowed operator IP: $OperatorPublicIp" -ForegroundColor Green
Write-Host '[INFO] データプレーンへの反映には時間がかかる場合があります。次に upload-package.ps1 を実行してください。' -ForegroundColor Yellow

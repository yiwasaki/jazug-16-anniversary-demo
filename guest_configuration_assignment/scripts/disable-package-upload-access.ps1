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

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    throw "Azure にログインしていません。'Connect-AzAccount' を実行してください。"
}

Write-Host '===== Disable Package Upload Access =====' -ForegroundColor Cyan

Write-Host '[INFO] 操作者 IP ルールを削除します。' -ForegroundColor Yellow
try {
    Remove-AzStorageAccountNetworkRule `
        -ResourceGroupName $ResourceGroupName `
        -Name $StorageAccountName `
        -IPAddressOrRange $OperatorPublicIp | Out-Null
}
catch {
    Write-Host '[WARN] IP ルールを削除できませんでした。Public network access の無効化を続行します。' -ForegroundColor Yellow
}

Write-Host '[INFO] Public network access を無効化します。' -ForegroundColor Yellow
Set-AzStorageAccount `
    -ResourceGroupName $ResourceGroupName `
    -Name $StorageAccountName `
    -PublicNetworkAccess Disabled `
    -Force | Out-Null

$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
$networkRuleSet = Get-AzStorageAccountNetworkRuleSet -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
$publicNetworkAccess = $storageAccount.PublicNetworkAccess
$ipRuleCount = @($networkRuleSet.IpRules | Where-Object { $_.IPAddressOrRange -eq $OperatorPublicIp }).Count

if ($publicNetworkAccess -ne 'Disabled' -or $ipRuleCount -ne 0) {
    throw "[FAIL] Storage firewall を安全な状態へ戻せませんでした (access=$publicNetworkAccess, ipRuleCount=$ipRuleCount)。"
}

Write-Host "[PASS] Public network access: $publicNetworkAccess" -ForegroundColor Green
Write-Host "[PASS] Removed operator IP: $OperatorPublicIp" -ForegroundColor Green
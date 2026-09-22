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

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    throw "Azure にログインしていません。'Connect-AzAccount' を実行してください。"
}

Write-Host '===== Enable Package Upload Access =====' -ForegroundColor Cyan

Write-Host '[INFO] Public network access を有効化します。' -ForegroundColor Yellow
Set-AzStorageAccount `
    -ResourceGroupName $ResourceGroupName `
    -Name $StorageAccountName `
    -PublicNetworkAccess Enabled `
    -Force | Out-Null
Update-AzStorageAccountNetworkRuleSet `
    -ResourceGroupName $ResourceGroupName `
    -Name $StorageAccountName `
    -DefaultAction Deny | Out-Null

Write-Host '[INFO] 操作者 IP を許可します。' -ForegroundColor Yellow
try {
    Add-AzStorageAccountNetworkRule `
        -ResourceGroupName $ResourceGroupName `
        -Name $StorageAccountName `
        -IPAddressOrRange $OperatorPublicIp | Out-Null
}
catch {
    Write-Host '[ERROR] IP ルールを追加できなかったため、Public network access を無効化します。' -ForegroundColor Red
    Set-AzStorageAccount `
        -ResourceGroupName $ResourceGroupName `
        -Name $StorageAccountName `
        -PublicNetworkAccess Disabled `
        -Force | Out-Null
    throw "IP ルール追加に失敗したため中断しました: $($_.Exception.Message)"
}

$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
$networkRuleSet = Get-AzStorageAccountNetworkRuleSet -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
$publicNetworkAccess = $storageAccount.PublicNetworkAccess
$ipRuleCount = @($networkRuleSet.IpRules | Where-Object { $_.IPAddressOrRange -eq $OperatorPublicIp }).Count

if ($publicNetworkAccess -ne 'Enabled' -or $ipRuleCount -ne 1) {
    throw "[FAIL] Storage firewall の許可状態を確認できませんでした (access=$publicNetworkAccess, ipRuleCount=$ipRuleCount)。"
}

Write-Host "[PASS] Public network access: $publicNetworkAccess" -ForegroundColor Green
Write-Host "[PASS] Allowed operator IP: $OperatorPublicIp" -ForegroundColor Green
Write-Host '[INFO] データプレーンへの反映には時間がかかる場合があります。次に upload-package.ps1 を実行してください。' -ForegroundColor Yellow
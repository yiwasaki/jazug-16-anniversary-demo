# ============================================================
# cleanup.ps1
# prepare が作成した Resource Group と基盤リソースを削除する
# ============================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) が見つかりません。'
}

$accountId = az account show --query id --output tsv 2>$null
if (-not $accountId) {
    throw 'az login が必要です。'
}

$resourceGroup = az group show --name $ResourceGroupName --output json 2>$null | ConvertFrom-Json
if (-not $resourceGroup) {
    Write-Host "[INFO] Resource Group は既に存在しません: $ResourceGroupName" -ForegroundColor Yellow
    exit 0
}

Write-Host "[INFO] Resource Group $ResourceGroupName を削除します (非同期)。" -ForegroundColor Yellow
az group delete --name $ResourceGroupName --yes --no-wait --output none
if ($LASTEXITCODE -ne 0) {
    throw "Resource Group の削除開始に失敗しました: $ResourceGroupName"
}
Write-Host '[PASS] Resource Group 削除リクエストを送信しました。' -ForegroundColor Green
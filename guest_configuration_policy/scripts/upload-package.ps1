# ============================================================
# upload-package.ps1
# Guest Configuration パッケージを private Blob container にアップロードする (PowerShell 版)
#
# Usage:
#   pwsh ./scripts/upload-package.ps1 `
#        -StorageAccountName <sa> `
#        [-ContainerName machine-configuration] `
#        -PackagePath ./package/MachineBaseline_1.0.0.zip
#
# 前提条件:
#   enable-package-upload-access.ps1 実行済みで Public endpoint と operator IP が一時許可されていること
#   Connect-AzAccount でログイン済み、対象 container の Storage Blob Data Contributor 権限があること
# ============================================================

#Requires -Modules Az.Accounts, Az.Storage

param(
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $false)]
    [string]$ContainerName = 'machine-configuration',

    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [Parameter(Mandatory = $false)]
    [int]$MaxAttempts = 12,

    [Parameter(Mandatory = $false)]
    [int]$RetryIntervalSeconds = 10
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $PackagePath)) {
    throw "Package file not found: $PackagePath"
}

if (-not (Get-AzContext)) {
    throw "Azure にログインしていません。'Connect-AzAccount' を実行してください。"
}

$storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
$blobName = Split-Path -Path $PackagePath -Leaf
$url = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$blobName"

Write-Host '===== Upload Guest Configuration Package =====' -ForegroundColor Cyan
Write-Host "Container: $ContainerName"
Write-Host "Blob name: $blobName"

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Write-Host "[INFO] Upload attempt: $attempt/$MaxAttempts" -ForegroundColor Yellow
    try {
        Set-AzStorageBlobContent `
            -Context $storageContext `
            -Container $ContainerName `
            -Blob $blobName `
            -File $PackagePath `
            -Force -ErrorAction Stop | Out-Null
        Write-Host '[PASS] Upload complete.' -ForegroundColor Green
        Write-Host "Package URL: $url"
        return
    }
    catch {
        Write-Host "[WARN] $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if ($attempt -lt $MaxAttempts) {
        Write-Host "[WARN] Storage firewall / RBAC 反映待ちとして $RetryIntervalSeconds 秒後に再試行します。" -ForegroundColor Yellow
        Start-Sleep -Seconds $RetryIntervalSeconds
    }
}

throw 'パッケージをアップロードできませんでした。IP ルールと Storage Blob Data Contributor 権限を確認してください。'

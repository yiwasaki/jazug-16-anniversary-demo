# ============================================================
# test-drift.ps1
# 管理対象ファイルを意図的に削除して drift を注入し、
# ApplyAndAutoCorrect による自動修復を上限時間付きで確認する。
#
# Usage:
#   .\test-drift.ps1 -ResourceGroupName rg-gcpolicy -VmName gcpolicy-vm
#   .\test-drift.ps1 -ResourceGroupName rg-gcpolicy -VmName gcpolicy-vm -ManagedFilePath /tmp/machine-baseline.txt
#
# 前提条件:
#   Guest Configuration のデプロイが完了し、Guest Assignment が Compliant になっていること
# ============================================================

#Requires -Modules Az.Accounts, Az.Compute

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VmName,

    # 未指定時は policy.config.json の managedFilePath を使う
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^/[A-Za-z0-9._/-]+$')]

    [string]$ManagedFilePath,

    [Parameter(Mandatory = $false)]
    [int]$MaxWaitMinutes = 25
)

$ErrorActionPreference = 'Stop'

if (-not (Get-AzContext)) {
    throw "Azure にログインしていません。'Connect-AzAccount' を実行してください。"
}

$scenarioRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
if (-not $ManagedFilePath) {
    $configPath = Join-Path $scenarioRoot 'policy.config.json'
    if (-not (Test-Path $configPath)) { throw "policy.config.json が見つかりません: $configPath" }
    $policyConfig = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    $ManagedFilePath = $policyConfig.managedFilePath
}
if (-not $ManagedFilePath) { throw 'ManagedFilePath を解決できませんでした。' }

Write-Host '===== Test Drift and AutoCorrect =====' -ForegroundColor Cyan
Write-Host "ManagedFilePath: $ManagedFilePath"

# VM 内でファイルの有無だけを判定する共通スクリプト
$probeCmd = "sudo test -f '$ManagedFilePath' && echo 'managed_file:present' || echo 'managed_file:absent'"

function Invoke-VmProbe {
    param([Parameter(Mandatory = $true)][string]$Script)

    $result = Invoke-AzVMRunCommand `
        -ResourceGroupName $ResourceGroupName `
        -VMName $VmName `
        -CommandId RunShellScript `
        -ScriptString $Script
    if (-not $result -or -not $result.value) { return $null }
    $stdout = ($result.value | Where-Object { $_.code -like '*StdOut*' }).message
    if (-not $stdout) { $stdout = ($result.value | Select-Object -First 1).message }
    return $stdout
}

# ============================================================
# 1. ドリフト前の状態を記録
# ============================================================
Write-Host '[INFO] ドリフト前の状態を記録します。' -ForegroundColor Yellow
$before = Invoke-VmProbe -Script $probeCmd
if (-not $before) { throw 'run-command invoke に失敗しました。VM の状態を確認してください。' }
Write-Host $before

if ($before -notmatch 'managed_file:present') {
    Write-Host '[WARN] ドリフト注入前から管理対象ファイルが存在しません。初回適用の完了を待ってから再実行してください。' -ForegroundColor Yellow
}

# ============================================================
# 2. ドリフトを注入 (管理対象ファイルを削除)
# ============================================================
Write-Host '[INFO] 管理対象ファイルを削除して drift を注入します。' -ForegroundColor Yellow
$driftOut = Invoke-VmProbe -Script "sudo rm -f '$ManagedFilePath'; $probeCmd"
Write-Host $driftOut

if ($driftOut -notmatch 'managed_file:absent') {
    throw "drift を注入できませんでした: $ManagedFilePath"
}

# ============================================================
# 3. AutoCorrect による復元を待機
# ============================================================
Write-Host "[INFO] $MaxWaitMinutes 分間、AutoCorrect による復元を待機します (Machine Configuration の consistency は既定 15 分間隔)。" -ForegroundColor Yellow
$deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
$restored = $false

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 60
    Write-Host "[WAIT] $((Get-Date).ToString('HH:mm:ss')) 復元状態を確認します。" -ForegroundColor Yellow
    $stdout = Invoke-VmProbe -Script $probeCmd
    if ($stdout -match 'managed_file:present') {
        $restored = $true
        Write-Host '[PASS] AutoCorrect により管理対象ファイルが復元されました。' -ForegroundColor Green
        Write-Host $stdout
        break
    }
}

if (-not $restored) {
    Write-Host "[FAIL] $MaxWaitMinutes 分以内に復元を確認できませんでした。verify.ps1 と gc_agent.log を確認してください。" -ForegroundColor Red
    exit 1
}

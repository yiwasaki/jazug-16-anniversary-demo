#Requires -Modules Az.Accounts, Az.Compute

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VmName,

    [Parameter(Mandatory = $false)]
    [string]$ManagedFilePath,

    [Parameter(Mandatory = $false)]
    [int]$MaxWaitMinutes = 25
)

$ErrorActionPreference = 'Stop'

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    throw "Azure にログインしていません。'Connect-AzAccount' を実行してください。"
}

if (-not $ManagedFilePath) {
    $configPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'assignment.config.json'
    if (-not (Test-Path $configPath)) { throw "assignment.config.json が見つかりません: $configPath" }
    $ManagedFilePath = (Get-Content -Path $configPath -Raw | ConvertFrom-Json).managedFilePath
}
if ($ManagedFilePath -notmatch '^/[A-Za-z0-9._/-]+$') {
    throw "ManagedFilePath はLinuxの絶対pathで指定してください: $ManagedFilePath"
}

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

Write-Host '===== Test Direct Assignment Drift and AutoCorrect =====' -ForegroundColor Cyan
$probeCommand = "sudo test -f '$ManagedFilePath' && echo 'managed_file:present' || echo 'managed_file:absent'"
$before = Invoke-VmProbe -Script $probeCommand
if (-not $before) { throw 'VM の状態を取得できませんでした。' }
if ($before -notmatch 'managed_file:present') {
    throw '初回適用が完了していません。verify.ps1 でCompliantを確認してから再実行してください。'
}

$afterDelete = Invoke-VmProbe -Script "sudo rm -f '$ManagedFilePath'; $probeCommand"
if ($afterDelete -notmatch 'managed_file:absent') {
    throw "drift を注入できませんでした: $ManagedFilePath"
}
Write-Host "[PASS] drift を注入しました: $ManagedFilePath" -ForegroundColor Green

$deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 60
    Write-Host "[WAIT] $((Get-Date).ToString('HH:mm:ss')) AutoCorrectを確認します。" -ForegroundColor Yellow
    if ((Invoke-VmProbe -Script $probeCommand) -match 'managed_file:present') {
        Write-Host '[PASS] AutoCorrect により管理対象ファイルが復元されました。' -ForegroundColor Green
        exit 0
    }
}

Write-Host "[FAIL] $MaxWaitMinutes 分以内に復元を確認できませんでした。" -ForegroundColor Red
exit 1
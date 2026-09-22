#Requires -Modules Az.Accounts, Az.Compute, Az.Resources

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VmName,

    [Parameter(Mandatory = $false)]
    [string]$AssignmentName = 'MachineBaseline',

    [Parameter(Mandatory = $false)]
    [int]$DeleteTimeoutSeconds = 300,

    [Parameter(Mandatory = $false)]
    [switch]$KeepExtension
)

$ErrorActionPreference = 'Stop'

$azContext = Get-AzContext -ErrorAction SilentlyContinue
if (-not $azContext) {
    throw "Azure にログインしていません。'Connect-AzAccount' を実行してください。"
}
$subscriptionId = $azContext.Subscription.Id

Write-Host '===== Cleanup Direct Guest Configuration Assignment =====' -ForegroundColor Cyan
$assignmentId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines/$VmName/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/$AssignmentName"
$assignment = Get-AzResource -ResourceId $assignmentId -ApiVersion 2024-04-05 -ErrorAction SilentlyContinue
if ($assignment) {
    Write-Host "[INFO] Assignment を削除します: $AssignmentName" -ForegroundColor Yellow
    Remove-AzResource -ResourceId $assignmentId -ApiVersion 2024-04-05 -Force | Out-Null

    $deadline = (Get-Date).AddSeconds($DeleteTimeoutSeconds)
    do {
        $remaining = Get-AzResource -ResourceId $assignmentId -ApiVersion 2024-04-05 -ErrorAction SilentlyContinue
        if (-not $remaining) { break }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    if ($remaining) { throw "Assignment が $DeleteTimeoutSeconds 秒以内に消滅しませんでした。" }
    Write-Host '[PASS] Assignment を削除しました。' -ForegroundColor Green
}
else {
    Write-Host '[INFO] Assignment は既に存在しません。' -ForegroundColor Yellow
}

if (-not $KeepExtension) {
    $extension = Get-AzVMExtension `
        -ResourceGroupName $ResourceGroupName `
        -VMName $VmName `
        -Name GuestConfiguration `
        -ErrorAction SilentlyContinue
    if ($extension) {
        Write-Host '[INFO] Guest Configuration Extension を削除します。' -ForegroundColor Yellow
        Remove-AzVMExtension `
            -ResourceGroupName $ResourceGroupName `
            -VMName $VmName `
            -Name GuestConfiguration `
            -Force | Out-Null
        Write-Host '[PASS] Guest Configuration Extension を削除しました。' -ForegroundColor Green
    }
    else {
        Write-Host '[INFO] Guest Configuration Extension は既に存在しません。' -ForegroundColor Yellow
    }
}

Write-Host '[PASS] Cleanup 完了' -ForegroundColor Green
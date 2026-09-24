# ============================================================
# cleanup.ps1
# Custom Policy 関連リソースを安全な順序で削除する
#
# 1. remediation task を削除 (存在すれば全件)
# 2. Policy assignment を削除し、消滅を polling で確認
# 3. Policy assignment identity の role assignments を削除
# 4. Guest Assignment と Guest Configuration Extension を削除
# 5. Custom Policy definition を削除し、消滅を polling で確認 (再試行あり)
#
# Usage:
#   .\cleanup.ps1 -ResourceGroupName rg-gcpolicy `
#                 -PolicyAssignmentName gc-machine-baseline `
#                 -PolicyDefinitionName gc-machine-baseline
# ============================================================

#Requires -Modules Az.Accounts, @{ ModuleName = 'Az.Resources'; ModuleVersion = '10.0.0' }, Az.Compute, Az.PolicyInsights

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$PolicyAssignmentName = 'gc-machine-baseline',

    [Parameter(Mandatory = $false)]
    [string]$PolicyDefinitionName = 'gc-machine-baseline',

    [Parameter(Mandatory = $false)]
    [string]$VmName = 'gcpolicy-vm',

    [Parameter(Mandatory = $false)]
    [string]$GuestAssignmentName = 'MachineBaseline',

    [Parameter(Mandatory = $false)]
    [int]$AssignmentDeleteTimeoutSeconds = 300,

    [Parameter(Mandatory = $false)]
    [int]$DefinitionDeleteTimeoutSeconds = 300,

    [Parameter(Mandatory = $false)]
    [int]$DefinitionDeleteMaxAttempts = 5
)

$ErrorActionPreference = 'Stop'
$script:CleanupFailed = $false

Write-Host '===== Cleanup Machine Configuration + Policy 資産 =====' -ForegroundColor Cyan

$subscriptionId = (Get-AzContext).Subscription.Id
if (-not $subscriptionId) { throw 'Azure サブスクリプションを取得できません。Connect-AzAccount を確認してください。' }

$assignmentScope = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName"

# ============================================================
# 1. Remediation task 削除
# ============================================================
Write-Host '[INFO] Remediation task を削除します。' -ForegroundColor Yellow
$rgExists = Get-AzResourceGroup | Where-Object { $_.ResourceGroupName -eq $ResourceGroupName }
if ($rgExists) {
    $remediations = Get-AzPolicyRemediation -ResourceGroupName $ResourceGroupName
    if ($remediations) {
        foreach ($rem in $remediations) {
            Write-Host "  - delete remediation: $($rem.name)"
            Remove-AzPolicyRemediation -ResourceGroupName $ResourceGroupName -Name $rem.Name -Confirm:$false | Out-Null
        }
    }
}
else {
    Write-Host '[INFO] Resource Group が存在しないため remediation 削除はスキップします。' -ForegroundColor Yellow
}

# ============================================================
# 2. Policy assignment 削除 + 消滅 polling
# ============================================================
$principalId = $null
$assignment = if ($rgExists) {
    Get-AzPolicyAssignment -Scope $assignmentScope |
        Where-Object { $_.Name -eq $PolicyAssignmentName -and $_.Scope -eq $assignmentScope }
}
if ($assignment) {
    $principalId = $assignment.IdentityPrincipalId
    Write-Host '[INFO] Policy assignment を削除します。' -ForegroundColor Yellow
    Remove-AzPolicyAssignment -Id $assignment.Id -Confirm:$false | Out-Null

    Write-Host "[INFO] Policy assignment の消滅を最大 $AssignmentDeleteTimeoutSeconds 秒 polling します。" -ForegroundColor Yellow
    $deadline = (Get-Date).AddSeconds($AssignmentDeleteTimeoutSeconds)
    $gone = $false
    do {
        Start-Sleep -Seconds 10
        $probe = Get-AzPolicyAssignment -Scope $assignmentScope |
            Where-Object { $_.Name -eq $PolicyAssignmentName -and $_.Scope -eq $assignmentScope }
        if (-not $probe) { $gone = $true; break }
    } while ((Get-Date) -lt $deadline)
    if ($gone) {
        Write-Host '[PASS] Policy assignment 消滅を確認しました。' -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Policy assignment が $AssignmentDeleteTimeoutSeconds 秒以内に消滅しませんでした。" -ForegroundColor Red
        $script:CleanupFailed = $true
    }
}
else {
    Write-Host '[INFO] Policy assignment は既に存在しません。' -ForegroundColor Yellow
}

# ============================================================
# 3. Policy assignment identity の role assignments 削除
# ============================================================
if ($principalId) {
    Write-Host "[INFO] Policy assignment identity ($principalId) の role assignments を削除します。" -ForegroundColor Yellow
    $ras = Get-AzRoleAssignment -ObjectId $principalId -Scope $assignmentScope -AtScope
    if ($ras) {
        foreach ($ra in $ras) {
            Write-Host "  - delete role assignment: $($ra.roleDefinitionName)"
            Remove-AzRoleAssignment -InputObject $ra | Out-Null
        }
    }
}

# ============================================================
# 4. Guest Assignment + Guest Configuration Extension 削除
# ============================================================
if ($rgExists) {
    $guestAssignmentId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines/$VmName/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/$GuestAssignmentName"
    $guestAssignmentPath = "${guestAssignmentId}?api-version=2024-04-05"
    try {
        $guestAssignment = Invoke-AzRestMethod -Method GET -Path $guestAssignmentPath
        if ($guestAssignment.StatusCode -eq 200) {
            Write-Host "[INFO] Guest Assignment を削除します: $GuestAssignmentName" -ForegroundColor Yellow
            $deleted = Invoke-AzRestMethod -Method DELETE -Path $guestAssignmentPath
            if ($deleted.StatusCode -notin 200, 202, 204) { throw $deleted.Content }
        }
        elseif ($guestAssignment.StatusCode -eq 404) {
            Write-Host '[INFO] Guest Assignment は既に存在しません。' -ForegroundColor Yellow
        }
        else { throw $guestAssignment.Content }
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            Write-Host '[INFO] Guest Assignment は既に存在しません。' -ForegroundColor Yellow
        }
        else {
            Write-Host "[FAIL] Guest Assignment の削除に失敗しました: $($_.Exception.Message)" -ForegroundColor Red
            $script:CleanupFailed = $true
        }
    }

    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName | Where-Object { $_.Name -eq $VmName }
    $extension = if ($vm) {
        Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VmName |
            Where-Object { $_.Name -eq 'GuestConfiguration' }
    }
    if ($extension) {
        Write-Host "[INFO] Guest Configuration Extension を削除します: $VmName/GuestConfiguration" -ForegroundColor Yellow
        try {
            Remove-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VmName -Name GuestConfiguration -Force | Out-Null
        }
        catch {
            Write-Host "[FAIL] Guest Configuration Extension を削除できませんでした: $($_.Exception.Message)" -ForegroundColor Red
            $script:CleanupFailed = $true
        }
    }
    else {
        Write-Host '[INFO] Guest Configuration Extension は既に存在しません。' -ForegroundColor Yellow
    }
}

# ============================================================
# 5. Custom Policy definition 削除 (再試行 + 消滅 polling)
# ============================================================
$defExists = Get-AzPolicyDefinition -SubscriptionId $subscriptionId -Custom |
    Where-Object { $_.Name -eq $PolicyDefinitionName }
if (-not $defExists) {
    Write-Host '[INFO] Policy definition は既に存在しません。' -ForegroundColor Yellow
}
else {
    Write-Host '[INFO] Custom Policy definition を削除します。' -ForegroundColor Yellow
    $defGone = $false
    for ($attempt = 1; $attempt -le $DefinitionDeleteMaxAttempts; $attempt++) {
        Write-Host "  - delete attempt: $attempt/$DefinitionDeleteMaxAttempts"
        try {
            Remove-AzPolicyDefinition -Id $defExists.Id -Confirm:$false | Out-Null
        } catch {
            Write-Host "  [WARN] delete 呼び出しでエラー: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        $deadline = (Get-Date).AddSeconds($DefinitionDeleteTimeoutSeconds)
        do {
            Start-Sleep -Seconds 10
            $probe = Get-AzPolicyDefinition -SubscriptionId $subscriptionId -Custom |
                Where-Object { $_.Name -eq $PolicyDefinitionName }
            if (-not $probe) { $defGone = $true; break }
        } while ((Get-Date) -lt $deadline)

        if ($defGone) {
            Write-Host '[PASS] Policy definition の消滅を確認しました。' -ForegroundColor Green
            break
        }
        Write-Host "[WARN] Policy definition がまだ残存しています。再試行します。" -ForegroundColor Yellow
        Start-Sleep -Seconds 15
    }
    if (-not $defGone) {
        Write-Host "[FAIL] Policy definition '$PolicyDefinitionName' を削除できませんでした。依存 assignment / lock を確認してください。" -ForegroundColor Red
        $script:CleanupFailed = $true
    }
}

Write-Host '===== Cleanup 完了 =====' -ForegroundColor Cyan
if ($script:CleanupFailed) {
    Write-Host '[FAIL] 一部の削除処理が完了しませんでした。上記の FAIL 行を確認してください。' -ForegroundColor Red
    exit 1
}
exit 0

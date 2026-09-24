# ============================================================
# verify.ps1
# Guest Configuration + Policy 検証補助スクリプト
#
# 検査項目 (期待値と照合し PASS/FAIL 判定):
#   - NSG: Internet からの inbound Deny、SSH(TCP/22) は VirtualNetwork から Allow
#   - VM NIC: Standard Public IP が関連付いていること
#   - Storage: publicNetworkAccess=Disabled / allowBlobPublicAccess=false / allowSharedKeyAccess=false
#   - Container: publicAccess=None
#   - Policy definition: metadata.category / contentUri / contentHash / mode / platform
#   - Policy assignment: identity 種別と RBAC (roleDefinitionIds すべて)
#   - Guest Assignment: provisioningState / complianceStatus
#   - Linux Guest Configuration Agent: 1.26.76.0 以上
#   - VM 内: 管理対象ファイル (policy.config.json の managedFilePath) の存在
#
# Usage:
#   .\verify.ps1 -ResourceGroupName rg-gcpolicy `
#                -VmName gcpolicy-vm `
#                -StorageAccountName <sa> `
#                -PackageContainerName machine-configuration `
#                -PolicyAssignmentName gc-machine-baseline `
#                -PolicyDefinitionName gc-machine-baseline `
#                -GuestAssignmentName MachineBaseline `
#                -ExpectedContentUri https://.../MachineBaseline_1.0.0.zip `
#                -ExpectedContentHash <sha256>
#
# 終了コード: FAIL が 1 件以上あれば 1、それ以外は 0
# ============================================================

#Requires -Modules Az.Accounts, @{ ModuleName = 'Az.Resources'; ModuleVersion = '10.0.0' }, Az.Compute, Az.Network, Az.Storage

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VmName,

    [Parameter(Mandatory = $false)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $false)]
    [string]$PackageContainerName = 'machine-configuration',

    [Parameter(Mandatory = $false)]
    [string]$PolicyAssignmentName = 'gc-machine-baseline',

    [Parameter(Mandatory = $false)]
    [string]$PolicyDefinitionName = 'gc-machine-baseline',

    [Parameter(Mandatory = $false)]
    [string]$GuestAssignmentName = 'MachineBaseline',

    [Parameter(Mandatory = $false)]
    [string]$ExpectedPolicyMode = 'ApplyAndAutoCorrect',

    [Parameter(Mandatory = $false)]
    [string]$ExpectedPlatform = 'Linux',

    [Parameter(Mandatory = $false)]
    [string]$ExpectedPolicyCategory = 'Guest Configuration',

    [Parameter(Mandatory = $false)]
    [string]$ExpectedContentUri,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedContentHash,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedAgentMinVersion = '1.26.76.0',

    [Parameter(Mandatory = $false)]
    [string]$VmNsgName,

    # 未指定時は policy.config.json の managedFilePath を使う
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^/[A-Za-z0-9._/-]+$')]

    [string]$ManagedFilePath,

    [Parameter(Mandatory = $false)]
    [switch]$SkipGuestAssignmentFail
)

$ErrorActionPreference = 'Continue'

$subscriptionId = (Get-AzContext).Subscription.Id
if (-not $subscriptionId) {
    throw "Azure にログインしていません。'Connect-AzAccount' を実行してください。"
}

$script:PassCount = 0
$script:FailCount = 0
$script:WarnCount = 0

if (-not $ManagedFilePath) {
    $configPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'policy.config.json'
    if (Test-Path $configPath) {
        $ManagedFilePath = (Get-Content -Path $configPath -Raw | ConvertFrom-Json).managedFilePath
    }
}

function Write-Result {
    param([string]$Verdict, [string]$Message)
    switch ($Verdict) {
        'PASS' { $script:PassCount++; Write-Host "[PASS] $Message" -ForegroundColor Green }
        'FAIL' { $script:FailCount++; Write-Host "[FAIL] $Message" -ForegroundColor Red }
        'WARN' { $script:WarnCount++; Write-Host "[WARN] $Message" -ForegroundColor Yellow }
        default { Write-Host "[$Verdict] $Message" -ForegroundColor Cyan }
    }
}

Write-Host '===== Verify Guest Configuration + Policy =====' -ForegroundColor Cyan

# ============================================================
# 1. NSG 検査
# ============================================================
Write-Host '--- NSG 検査 ---' -ForegroundColor Cyan
if (-not $VmNsgName) {
    # 命名規約: <resourcePrefix>-vm-nsg。VmName の suffix -vm を基に推定
    $prefixGuess = $VmName -replace '-vm$', ''
    $VmNsgName = "$prefixGuess-vm-nsg"
}
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $VmNsgName -ErrorAction SilentlyContinue
if (-not $nsg) {
    Write-Result 'FAIL' "NSG が見つかりません: $VmNsgName (別名の場合は -VmNsgName を指定)"
}
else {
    Write-Result 'PASS' "NSG 取得: $VmNsgName"
    $rules = $nsg.securityRules

    $sshRule = $rules | Where-Object {
        $_.direction -eq 'Inbound' -and $_.access -eq 'Allow' -and $_.protocol -eq 'Tcp' -and
        $_.destinationPortRange -eq '22' -and $_.sourceAddressPrefix -eq 'VirtualNetwork'
    }
    if ($sshRule) {
        Write-Result 'PASS' "NSG SSH allow rule 存在: $($sshRule.name) (priority=$($sshRule.priority))"
    } else {
        Write-Result 'FAIL' 'NSG に SSH(TCP/22) を VirtualNetwork から Allow するルールがありません。'
    }

    $denyRule = $rules | Where-Object {
        $_.direction -eq 'Inbound' -and $_.access -eq 'Deny' -and $_.sourceAddressPrefix -eq 'Internet'
    }
    if ($denyRule) {
        Write-Result 'PASS' "NSG Internet deny rule 存在: $($denyRule.name) (priority=$($denyRule.priority))"
    } else {
        Write-Result 'FAIL' 'NSG に Internet からの inbound を Deny するルールがありません。'
    }
}

# ============================================================
# 2. VM / NIC / Public IP
# ============================================================
Write-Host '--- VM / NIC / Public IP 検査 ---' -ForegroundColor Cyan
$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Result 'FAIL' "VM が見つかりません: $VmName"
}
else {
    if ($vm.identity.type -match 'SystemAssigned') {
        Write-Result 'PASS' 'VM identity: SystemAssigned'
    } else {
        Write-Result 'FAIL' "VM identity が SystemAssigned ではありません: $($vm.identity.type)"
    }

    $nicId = $vm.networkProfile.networkInterfaces[0].id
    $nic = Get-AzNetworkInterface -ResourceGroupName $nicId.Split('/')[4] -Name $nicId.Split('/')[-1]
    $publicIpRef = $nic.ipConfigurations[0].publicIPAddress
    if (-not $publicIpRef) {
        Write-Result 'FAIL' 'VM NIC に Public IP が関連付いていません。'
    }
    else {
        $pip = Get-AzPublicIpAddress -ResourceGroupName $publicIpRef.Id.Split('/')[4] -Name $publicIpRef.Id.Split('/')[-1]
        if ($pip.sku.name -eq 'Standard') {
            Write-Result 'PASS' "VM NIC Public IP SKU: Standard ($($pip.name))"
        } else {
            Write-Result 'FAIL' "VM NIC Public IP SKU が Standard ではありません: $($pip.sku.name)"
        }
    }
}

# ============================================================
# 3. Storage / Container
# ============================================================
if ($StorageAccountName) {
    Write-Host '--- Storage / Container 検査 ---' -ForegroundColor Cyan
    $sa = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction SilentlyContinue
    if (-not $sa) {
        Write-Result 'FAIL' "Storage Account が見つかりません: $StorageAccountName"
    }
    else {
        if ($sa.publicNetworkAccess -eq 'Disabled') {
            Write-Result 'PASS' 'Storage publicNetworkAccess: Disabled'
        } else {
            Write-Result 'FAIL' "Storage publicNetworkAccess=$($sa.publicNetworkAccess) (期待: Disabled)"
        }
        if ($sa.allowBlobPublicAccess -eq $false) {
            Write-Result 'PASS' 'Storage allowBlobPublicAccess: False (anonymous disabled)'
        } else {
            Write-Result 'FAIL' "Storage allowBlobPublicAccess=$($sa.allowBlobPublicAccess) (期待: False)"
        }
        if ($sa.allowSharedKeyAccess -eq $false) {
            Write-Result 'PASS' 'Storage allowSharedKeyAccess: False (Shared Key disabled)'
        } else {
            Write-Result 'FAIL' "Storage allowSharedKeyAccess=$($sa.allowSharedKeyAccess) (期待: False)"
        }

        $container = Get-AzRmStorageContainer `
            -ResourceGroupName $ResourceGroupName `
            -StorageAccountName $StorageAccountName `
            -Name $PackageContainerName `
            -ErrorAction SilentlyContinue
        if (-not $container) {
            Write-Result 'FAIL' "Container が見つかりません: $PackageContainerName"
        }
        elseif ($container.publicAccess -eq 'None') {
            Write-Result 'PASS' 'Container publicAccess: None'
        } else {
            Write-Result 'FAIL' "Container publicAccess=$($container.publicAccess) (期待: None)"
        }
    }
}
else {
    Write-Result 'WARN' 'StorageAccountName 未指定のため Storage 検査をスキップします。'
}

# ============================================================
# 4. Policy definition
# ============================================================
Write-Host '--- Policy definition 検査 ---' -ForegroundColor Cyan
$policyDef = $null
try {
    $definitionPath = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyDefinitions/${PolicyDefinitionName}?api-version=2023-04-01"
    $definitionResponse = Invoke-AzRestMethod -Method GET -Path $definitionPath -ErrorAction Stop
    if ($definitionResponse.StatusCode -ne 200) { throw $definitionResponse.Content }
    $policyDef = ($definitionResponse.Content | ConvertFrom-Json).properties
}
catch {
    Write-Result 'FAIL' "Policy definition を取得できませんでした: $($_.Exception.Message)"
}
if (-not $policyDef) {
    Write-Result 'FAIL' "Policy definition が見つかりません: $PolicyDefinitionName"
}
else {
    # mode
    if ($policyDef.mode -eq 'Indexed' -or $policyDef.mode -eq 'All') {
        Write-Result 'PASS' "Policy mode: $($policyDef.mode)"
    } else {
        Write-Result 'FAIL' "Policy mode=$($policyDef.mode) (期待: Indexed または All)"
    }

    # metadata.category
    if ($policyDef.metadata.category -eq $ExpectedPolicyCategory) {
        Write-Result 'PASS' "Policy metadata.category: $($policyDef.metadata.category)"
    } else {
        Write-Result 'FAIL' "Policy metadata.category=$($policyDef.metadata.category) (期待: $ExpectedPolicyCategory)"
    }

    # policyRule.then.details から assignment type / contentUri / contentHash を抽出
    $details = $policyDef.policyRule.then.details
    $assignments = @()
    if ($details.deployment) {
        # DINE の場合はテンプレート内のリソース定義を探索
        $tmplResources = $details.deployment.properties.template.resources
        foreach ($r in $tmplResources) {
            if ($r.type -like '*guestConfigurationAssignments*') {
                $assignments += $r
            }
        }
    }

    if ($assignments.Count -eq 0) {
        Write-Result 'WARN' 'Policy definition 内に guestConfigurationAssignments テンプレートを検出できません。contentUri/Hash 検査をスキップします。'
    }
    else {
        $ga = $assignments[0]
        $props = $ga.properties.guestConfiguration
        if ($props) {
            $observedMode = $props.assignmentType
            if ($observedMode -eq $ExpectedPolicyMode) {
                Write-Result 'PASS' "Policy assignmentType (mode): $observedMode"
            } else {
                Write-Result 'FAIL' "Policy assignmentType=$observedMode (期待: $ExpectedPolicyMode)"
            }

            $observedContentUri = $props.contentUri
            if ($ExpectedContentUri) {
                if ($observedContentUri -eq $ExpectedContentUri) {
                    Write-Result 'PASS' "Policy contentUri 一致: $observedContentUri"
                } else {
                    Write-Result 'FAIL' "Policy contentUri=$observedContentUri (期待: $ExpectedContentUri)"
                }
            } else {
                Write-Result 'INFO' "Policy contentUri: $observedContentUri (ExpectedContentUri 未指定のため比較スキップ)"
            }

            $observedContentHash = $props.contentHash
            if ($ExpectedContentHash) {
                if ($observedContentHash -and $observedContentHash.ToLowerInvariant() -eq $ExpectedContentHash.ToLowerInvariant()) {
                    Write-Result 'PASS' 'Policy contentHash 一致'
                } else {
                    Write-Result 'FAIL' "Policy contentHash=$observedContentHash (期待: $ExpectedContentHash)"
                }
            } else {
                Write-Result 'INFO' "Policy contentHash: $observedContentHash (ExpectedContentHash 未指定のため比較スキップ)"
            }
        }
    }

    # platform (metadata.guestConfiguration.category / policyRule の Linux フィルタ)
    $platform = $null
    if ($policyDef.metadata.guestConfiguration.category) {
        $platform = $policyDef.metadata.guestConfiguration.category
    }
    elseif ($policyDef.policyRule.if -and ($policyDef.policyRule | ConvertTo-Json -Depth 20) -match 'Linux') {
        $platform = 'Linux'
    }
    if ($platform -eq $ExpectedPlatform) {
        Write-Result 'PASS' "Policy platform: $platform"
    } elseif ($platform) {
        Write-Result 'FAIL' "Policy platform=$platform (期待: $ExpectedPlatform)"
    } else {
        Write-Result 'WARN' 'Policy platform を metadata から特定できません。生成 JSON を確認してください。'
    }
}

# ============================================================
# 5. Policy assignment + RBAC
# ============================================================
Write-Host '--- Policy assignment 検査 ---' -ForegroundColor Cyan
$assignmentScope = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName"
$assignment = Get-AzPolicyAssignment -Name $PolicyAssignmentName -Scope $assignmentScope -ErrorAction SilentlyContinue
if (-not $assignment) {
    Write-Result 'FAIL' "Policy assignment が見つかりません: $PolicyAssignmentName ($assignmentScope)"
}
else {
    if ($assignment.IdentityType -match 'SystemAssigned') {
        Write-Result 'PASS' "Policy assignment identity: SystemAssigned ($($assignment.IdentityPrincipalId))"
    } else {
        Write-Result 'FAIL' "Policy assignment identity 種別=$($assignment.IdentityType) (期待: SystemAssigned)"
    }
    if ($assignment.scope -eq $assignmentScope) {
        Write-Result 'PASS' "Policy assignment scope: $($assignment.scope)"
    } else {
        Write-Result 'FAIL' "Policy assignment scope=$($assignment.scope) (期待: $assignmentScope)"
    }

    # RBAC 検査
    if ($policyDef -and $policyDef.policyRule.then.details.roleDefinitionIds) {
        $expectedRoleIds = @($policyDef.policyRule.then.details.roleDefinitionIds)
        Write-Host "--- Policy assignment RBAC 検査 (期待 $($expectedRoleIds.Count) 件) ---" -ForegroundColor Cyan
        foreach ($rid in $expectedRoleIds) {
            $short = $rid.Split('/')[-1]
            $ra = @(Get-AzRoleAssignment -ObjectId $assignment.IdentityPrincipalId -Scope $assignmentScope -RoleDefinitionId $short -AtScope -ErrorAction SilentlyContinue)
            if ($ra -and $ra.Count -gt 0) {
                Write-Result 'PASS' "Role assignment 確認: $short"
            } else {
                Write-Result 'FAIL' "Role assignment 未検出: $short"
            }
        }
    }
    else {
        Write-Result 'WARN' 'Policy definition から roleDefinitionIds を取得できなかったため RBAC 検査をスキップします。'
    }
}

# ============================================================
# 6. Guest Assignment (compliance)
# ============================================================
Write-Host '--- Guest Assignment 検査 ---' -ForegroundColor Cyan
$guestAssignmentId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines/$VmName/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/$GuestAssignmentName"

$ga = $null
try {
    $gaResponse = Invoke-AzRestMethod -Method GET -Path "${guestAssignmentId}?api-version=2024-04-05" -ErrorAction Stop
    if ($gaResponse.StatusCode -eq 200) {
        $ga = $gaResponse.Content | ConvertFrom-Json
    }
    elseif ($gaResponse.StatusCode -eq 404 -and $SkipGuestAssignmentFail) {
        Write-Result 'WARN' "Guest Assignment が未作成です (SkipGuestAssignmentFail 指定): $guestAssignmentId"
    }
    else { throw "HTTP $($gaResponse.StatusCode): $($gaResponse.Content)" }
}
catch {
    if ($_.Exception.Response.StatusCode -eq 404 -and $SkipGuestAssignmentFail) {
        Write-Result 'WARN' "Guest Assignment が未作成です (SkipGuestAssignmentFail 指定): $guestAssignmentId"
    }
    else {
        Write-Result 'FAIL' "Guest Assignment を取得できませんでした: $($_.Exception.Message)"
    }
}

if ($ga) {
    if ($ga.properties.provisioningState -eq 'Succeeded') {
        Write-Result 'PASS' "Guest Assignment provisioningState: $($ga.properties.provisioningState)"
    } else {
        Write-Result 'FAIL' "Guest Assignment provisioningState=$($ga.properties.provisioningState) (期待: Succeeded)"
    }
    if ($ga.properties.complianceStatus -eq 'Compliant') {
        Write-Result 'PASS' 'Guest Assignment complianceStatus: Compliant'
    } elseif ($ga.properties.complianceStatus) {
        Write-Result 'FAIL' "Guest Assignment complianceStatus=$($ga.properties.complianceStatus) (期待: Compliant)"
    } else {
        Write-Result 'WARN' 'Guest Assignment complianceStatus が空です (初回評価待ち)。'
    }
}

# ============================================================
# 7. VM 内 Agent version / 管理対象ファイル
# ============================================================
Write-Host '--- VM 内 Agent / 管理対象ファイル確認 ---' -ForegroundColor Cyan
$cmd = @"
set +e
if [ -f /var/lib/GuestConfig/gc_agent_logs/gc_agent.log ]; then
  grep -oE 'GC Linux Agent[[:space:]]+Version[[:space:]]+[0-9.]+' /var/lib/GuestConfig/gc_agent_logs/gc_agent.log | tail -n 1 || true
  grep -oE 'Agent[[:space:]]+[Vv]ersion[[:space:]]*[:=]?[[:space:]]*[0-9.]+' /var/lib/GuestConfig/gc_agent_logs/gc_agent.log | tail -n 1 || true
fi
if [ -n '$ManagedFilePath' ]; then
  test -f '$ManagedFilePath' && echo 'managed_file:present' || echo 'managed_file:absent'
fi
"@

$runResult = Invoke-AzVMRunCommand `
    -ResourceGroupName $ResourceGroupName `
    -VMName $VmName `
    -CommandId RunShellScript `
    -ScriptString $cmd `
    -ErrorAction SilentlyContinue

if ($runResult -and $runResult.value) {
    $stdout = ($runResult.value | Where-Object { $_.code -like '*StdOut*' }).message
    if (-not $stdout) { $stdout = ($runResult.value | Select-Object -First 1).message }
    Write-Host $stdout

    $versionMatch = [regex]::Matches($stdout, '([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)') | Select-Object -Last 1
    if ($versionMatch) {
        $observedVersion = [version]$versionMatch.Value
        $minVersion = [version]$ExpectedAgentMinVersion
        if ($observedVersion -ge $minVersion) {
            Write-Result 'PASS' "Guest Configuration Agent version $observedVersion (>= $ExpectedAgentMinVersion)"
        } else {
            Write-Result 'FAIL' "Guest Configuration Agent version $observedVersion (< $ExpectedAgentMinVersion)"
        }
    } else {
        Write-Result 'WARN' 'gc_agent.log から Agent version を抽出できませんでした。'
    }

    if (-not $ManagedFilePath) {
        Write-Result 'WARN' 'ManagedFilePath を解決できなかったため、管理対象ファイルの検査をスキップしました。'
    } elseif ($stdout -match 'managed_file:present') {
        Write-Result 'PASS' "管理対象ファイルが存在します: $ManagedFilePath"
    } elseif ($stdout -match 'managed_file:absent') {
        Write-Result 'FAIL' "管理対象ファイルがありません: $ManagedFilePath (期待: 存在すること)"
    } else {
        Write-Result 'WARN' '管理対象ファイルの存在を判定できませんでした。'
    }
} else {
    Write-Result 'WARN' 'run-command invoke に失敗しました。VM 内検査をスキップします。'
}

# ============================================================
# サマリ
# ============================================================
Write-Host '===== Verify サマリ =====' -ForegroundColor Cyan
Write-Host ("PASS = {0} / FAIL = {1} / WARN = {2}" -f $script:PassCount, $script:FailCount, $script:WarnCount) -ForegroundColor Cyan
if ($script:FailCount -gt 0) {
    Write-Host "[FAIL] 検査に失敗があります。上記の FAIL 行を確認してください。" -ForegroundColor Red
    exit 1
}
else {
    Write-Host '[PASS] 期待値をすべて満たしました。' -ForegroundColor Green
    exit 0
}

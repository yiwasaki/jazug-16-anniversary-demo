#Requires -Modules Az.Accounts, Az.Compute, Az.Resources

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VmName,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedContentUri,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedContentHash,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedAgentMinVersion = '1.26.76.0'
)

$ErrorActionPreference = 'Continue'
$script:PassCount = 0
$script:FailCount = 0
$script:WarnCount = 0

function Write-Result {
    param([string]$Verdict, [string]$Message)

    switch ($Verdict) {
        'PASS' { $script:PassCount++; Write-Host "[PASS] $Message" -ForegroundColor Green }
        'FAIL' { $script:FailCount++; Write-Host "[FAIL] $Message" -ForegroundColor Red }
        'WARN' { $script:WarnCount++; Write-Host "[WARN] $Message" -ForegroundColor Yellow }
        default { Write-Host "[$Verdict] $Message" -ForegroundColor Cyan }
    }
}

$azContext = Get-AzContext -ErrorAction SilentlyContinue
if (-not $azContext) {
    throw "Azure にログインしていません。'Connect-AzAccount' を実行してください。"
}
$subscriptionId = $azContext.Subscription.Id

$scenarioRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$configPath = Join-Path $scenarioRoot 'assignment.config.json'
if (-not (Test-Path $configPath)) {
    throw "assignment.config.json が見つかりません: $configPath"
}
$config = Get-Content -Path $configPath -Raw | ConvertFrom-Json

Write-Host '===== Verify Direct Guest Configuration Assignment =====' -ForegroundColor Cyan

$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Result 'FAIL' "VM が見つかりません: $VmName"
}
elseif ($vm.identity.type -match 'SystemAssigned') {
    Write-Result 'PASS' 'VM identity: SystemAssigned'
}
else {
    Write-Result 'FAIL' "VM identity が SystemAssigned ではありません: $($vm.identity.type)"
}

$extension = Get-AzVMExtension `
    -ResourceGroupName $ResourceGroupName `
    -VMName $VmName `
    -Name GuestConfiguration `
    -ErrorAction SilentlyContinue
if (-not $extension) {
    Write-Result 'FAIL' 'Guest Configuration Extension が見つかりません。'
}
elseif ($extension.provisioningState -eq 'Succeeded') {
    Write-Result 'PASS' 'Guest Configuration Extension provisioningState: Succeeded'
}
else {
    Write-Result 'FAIL' "Guest Configuration Extension provisioningState=$($extension.provisioningState)"
}

$assignmentId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines/$VmName/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/$($config.assignmentName)"
$assignment = Get-AzResource `
    -ResourceId $assignmentId `
    -ApiVersion 2024-04-05 `
    -ExpandProperties `
    -ErrorAction SilentlyContinue

if (-not $assignment) {
    Write-Result 'FAIL' "Guest Configuration Assignment が見つかりません: $($config.assignmentName)"
}
else {
    $guestConfiguration = $assignment.properties.guestConfiguration

    if ($assignment.properties.provisioningState -eq 'Succeeded') {
        Write-Result 'PASS' 'Assignment provisioningState: Succeeded'
    }
    else {
        Write-Result 'FAIL' "Assignment provisioningState=$($assignment.properties.provisioningState)"
    }

    if ($assignment.properties.complianceStatus -eq 'Compliant') {
        Write-Result 'PASS' 'Assignment complianceStatus: Compliant'
    }
    elseif ($assignment.properties.complianceStatus) {
        Write-Result 'FAIL' "Assignment complianceStatus=$($assignment.properties.complianceStatus)"
    }
    else {
        Write-Result 'WARN' 'Assignment complianceStatus が空です。初回評価の完了後に再実行してください。'
    }

    foreach ($expectation in @(
        @{ Name = 'name'; Actual = $guestConfiguration.name; Expected = $config.configurationName },
        @{ Name = 'version'; Actual = $guestConfiguration.version; Expected = $config.configurationVersion },
        @{ Name = 'assignmentType'; Actual = $guestConfiguration.assignmentType; Expected = $config.assignmentType },
        @{ Name = 'contentManagedIdentity'; Actual = $guestConfiguration.contentManagedIdentity; Expected = 'system' }
    )) {
        if ($expectation.Actual -eq $expectation.Expected) {
            Write-Result 'PASS' "Assignment $($expectation.Name): $($expectation.Actual)"
        }
        else {
            Write-Result 'FAIL' "Assignment $($expectation.Name)=$($expectation.Actual) (期待: $($expectation.Expected))"
        }
    }

    if ($ExpectedContentUri) {
        if ($guestConfiguration.contentUri -eq $ExpectedContentUri) {
            Write-Result 'PASS' 'Assignment contentUri 一致'
        }
        else {
            Write-Result 'FAIL' "Assignment contentUri=$($guestConfiguration.contentUri) (期待: $ExpectedContentUri)"
        }
    }
    else {
        Write-Result 'INFO' "Assignment contentUri: $($guestConfiguration.contentUri)"
    }

    if ($ExpectedContentHash) {
        if ($guestConfiguration.contentHash -and $guestConfiguration.contentHash.ToLowerInvariant() -eq $ExpectedContentHash.ToLowerInvariant()) {
            Write-Result 'PASS' 'Assignment contentHash 一致'
        }
        else {
            Write-Result 'FAIL' "Assignment contentHash=$($guestConfiguration.contentHash) (期待: $ExpectedContentHash)"
        }
    }
    else {
        Write-Result 'INFO' "Assignment contentHash: $($guestConfiguration.contentHash)"
    }
}

$managedFilePath = $config.managedFilePath
$command = @"
set +e
if [ -f /var/lib/GuestConfig/gc_agent_logs/gc_agent.log ]; then
  grep -oE 'GC Linux Agent[[:space:]]+Version[[:space:]]+[0-9.]+' /var/lib/GuestConfig/gc_agent_logs/gc_agent.log | tail -n 1 || true
  grep -oE 'Agent[[:space:]]+[Vv]ersion[[:space:]]*[:=]?[[:space:]]*[0-9.]+' /var/lib/GuestConfig/gc_agent_logs/gc_agent.log | tail -n 1 || true
fi
test -f '$managedFilePath' && echo 'managed_file:present' || echo 'managed_file:absent'
"@
$runResult = Invoke-AzVMRunCommand `
    -ResourceGroupName $ResourceGroupName `
    -VMName $VmName `
    -CommandId RunShellScript `
    -ScriptString $command `
    -ErrorAction SilentlyContinue

if ($runResult -and $runResult.value) {
    $stdout = ($runResult.value | Where-Object { $_.code -like '*StdOut*' }).message
    if (-not $stdout) { $stdout = ($runResult.value | Select-Object -First 1).message }

    $versionMatch = [regex]::Matches($stdout, '([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)') | Select-Object -Last 1
    if ($versionMatch -and [version]$versionMatch.Value -ge [version]$ExpectedAgentMinVersion) {
        Write-Result 'PASS' "Guest Configuration Agent version $($versionMatch.Value)"
    }
    elseif ($versionMatch) {
        Write-Result 'FAIL' "Guest Configuration Agent version $($versionMatch.Value) (期待: $ExpectedAgentMinVersion 以上)"
    }
    else {
        Write-Result 'WARN' 'Guest Configuration Agent version を取得できませんでした。'
    }

    if ($stdout -match 'managed_file:present') {
        Write-Result 'PASS' "管理対象ファイルが存在します: $managedFilePath"
    }
    else {
        Write-Result 'FAIL' "管理対象ファイルがありません: $managedFilePath"
    }
}
else {
    Write-Result 'WARN' 'VM 内の状態を取得できませんでした。'
}

Write-Host '===== Verify サマリ =====' -ForegroundColor Cyan
Write-Host ("PASS = {0} / FAIL = {1} / WARN = {2}" -f $script:PassCount, $script:FailCount, $script:WarnCount)
if ($script:FailCount -gt 0) { exit 1 }
exit 0
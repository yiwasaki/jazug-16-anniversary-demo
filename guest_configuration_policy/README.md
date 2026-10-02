# Azure Policy による Machine Configuration 自動適用

`prepare/` で作成済みの Ubuntu VM に、Azure Machine Configuration（Guest Configuration）のカスタム `AuditAndSet` packageを配布します。Azure Policy の `DeployIfNotExists` と `ApplyAndAutoCorrect` により、構成適用とドリフトの自動修復を検証します。

この方式と [直接Assignment方式](../guest_configuration_assignment/README.md) は代替関係です。同じVMへ同じ構成を同時にデプロイしないでください。

このフォルダーの手順は、直接Assignment方式と共通の工程と、Azure Policy方式に固有の工程に分かれます。

| 区分 | 工程 |
| --- | --- |
| 直接Assignment方式と共通 | DSC packageのbuild、private Blob containerへのupload |
| Azure Policy方式に固有 | Guest Configuration Extension、Policy definition、Policy assignment、RBAC、remediation |

packageをStorageへuploadした後が分岐点です。直接Assignment方式ではVMへAssignmentを直接デプロイしますが、この方式ではAzure Policyを登録・割り当てし、対象VMごとのAssignmentを自動作成します。

VM、Network、StorageなどのAzure基盤は [../prepare/README.md](../prepare/README.md) の手順で先に作成してください。

## ディレクトリ構成

```text
guest_configuration_policy/
├── policy.config.json
├── configuration/
│   ├── MachineBaseline.ps1
│   └── modules/MachineBaseline/
├── package/
├── generated/
└── scripts/
```

`package/*.zip`、`.bicep-build/`、生成されるPolicy JSONはGit対象外です。

## 適用する構成

`MachineBaseline` class-based DSC resourceは、`/tmp/machine-baseline.txt` が存在することを保証します。

- `Get()` は対象ファイルの状態と `Reasons` を返します。
- `Test()` は状態を変更せず、desired stateか判定します。
- `Set()` は親ディレクトリを作成してファイルを作成します。
- `TargetPath` は絶対パスのみ受け付けます。

管理対象パスを変更する場合は、`configuration/MachineBaseline.ps1` と `policy.config.json` の `managedFilePath` を同時に更新します。

## 前提条件

- [../prepare/README.md](../prepare/README.md) に従って、基盤リソースのデプロイを完了してください。
- コマンドを実行する端末にPowerShell 7を用意してください。
- Azure PowerShellの `Az.Accounts`、`Az.Resources` (10.0.0以上)、`Az.Compute`、`Az.Network`、`Az.Storage`、`Az.PolicyInsights` (2.0.0以上) モジュールをインストールしてください。
- `GuestConfiguration` と `PSDesiredStateConfiguration` 3.0.0のPowerShellモジュールをインストールしてください。
- 対象サブスクリプションで `Microsoft.GuestConfiguration` と `Microsoft.PolicyInsights` リソースプロバイダーを登録してください。
- サブスクリプションスコープでのPolicy definition作成と、対象Resource Groupでのデプロイ・ロール割り当てに必要な権限を用意してください。

```powershell
# 必要なPowerShellモジュールを、現在のユーザー向けにインストールします。
Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force
Install-Module -Name GuestConfiguration -Scope CurrentUser -Force
Install-Module -Name PSDesiredStateConfiguration `
  -RequiredVersion 3.0.0-beta1 `
  -AllowPrerelease `
  -Scope CurrentUser

# Azureへログインし、この後の操作で使用するサブスクリプションを選択します。
Connect-AzAccount
Set-AzContext -Subscription '<subscription-id-or-name>'
```

## デプロイ

### 直接Assignment方式と共通の手順

prepare deploymentのoutputs取得、DSC packageのbuild、Storageへのuploadは、[直接Assignment方式](../guest_configuration_assignment/README.md) と同じ流れです。設定ファイル名とpathだけが `guest_configuration_policy` 用になります。

#### 共通手順1. prepare deploymentのoutputsを取得

リポジトリルートでPowerShellを開き、prepare deploymentのoutputsを取得します。

```powershell
# prepareで作成したResource Groupと、デプロイ結果のoutputsを取得します。
$resourceGroupName = 'rg-gcpolicy-policy'
$location = (Get-AzResourceGroup -Name $resourceGroupName).Location
$prepareOutputs = (Get-AzResourceGroupDeployment `
  -ResourceGroupName $resourceGroupName `
  -Name 'gcpolicy-prepare').Outputs

# VM名、packageのupload先、uploadに使用するidentityのprincipal IDを取り出します。
$vmName = $prepareOutputs.vmName.value
$storageAccountName = $prepareOutputs.storageAccountName.value
$containerName = $prepareOutputs.packageContainerName.value
$packageBaseUri = $prepareOutputs.packageBaseUri.value.TrimEnd('/')
$packageUploaderPrincipalId = $prepareOutputs.packageUploaderPrincipalId.value
```

#### 共通手順2. DSC packageをbuild

DSC packageをbuildします。この工程は、DSC構成のcompile、`localhost.mof` の生成、custom DSC resourceを含むZIPの作成、SHA-256 hashの計算までを行います。

```powershell
# packageの構成名とversionを設定ファイルから読み込みます。
$policyConfig = Get-Content ./guest_configuration_policy/policy.config.json -Raw | ConvertFrom-Json
$configurationName = $policyConfig.configurationName
$configurationVersion = $policyConfig.configurationVersion

# 前回の一時ファイルを削除し、MOFの出力先を作成します。
$mofOutputPath = "./guest_configuration_policy/.bicep-build/$configurationName"
Remove-Item -Path ./guest_configuration_policy/.bicep-build -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $mofOutputPath -ItemType Directory -Force | Out-Null

# DSC engineに、このrepository内のcustom DSC resourceを読み込ませます。
Import-Module PSDesiredStateConfiguration -RequiredVersion 3.0.0 -Force
$modulePath = (Resolve-Path ./guest_configuration_policy/configuration/modules).Path
$env:PSModulePath = "$modulePath$([IO.Path]::PathSeparator)$env:PSModulePath"

# 先頭の「. と空白」はdot-sourceです。ファイル内の構成定義を現在のPowerShellセッションへ読み込みます。
# Configuration MachineBaseline と定義されているため、MachineBaselineという名前で呼び出せるようになります。
# 名前はファイル名ではなくConfigurationの定義で決まり、Azureへの登録やインストールではありません。
. ./guest_configuration_policy/configuration/MachineBaseline.ps1

# Configurationは通常のfunctionと異なり、呼び出すとDSCが構成をコンパイルします。
# 引数を構成へ当てはめ、リソースのプロパティや型を検証し、NodeごとのMOFを生成します。
# MOF（Managed Object Format）は、使用するDSCリソースと期待する状態を記述したファイルです。
# Node localhost の定義により出力名はlocalhost.mofとなり、DSCが用意する-OutputPathで出力先を指定します。
# この段階ではSet()は呼ばれず、VMも変更されません。状態の確認・修正は配布後にVM内で行われます。
MachineBaseline `
  -ManagedFilePath $policyConfig.managedFilePath `
  -OutputPath $mofOutputPath

# MOFと依存するDSC resourceを、Guest Configuration用のZIPにまとめます。
$generatedPackage = New-GuestConfigurationPackage `
  -Name $configurationName `
  -Configuration "$mofOutputPath/localhost.mof" `
  -Type AuditAndSet `
  -Path ./guest_configuration_policy/package `
  -Version $configurationVersion `
  -Force

# packageをrenameし、URIとSHA-256 hashを作成します。
$packageFileName = "${configurationName}_${configurationVersion}.zip"
$packagePath = "./guest_configuration_policy/package/$packageFileName"
Move-Item -Path $generatedPackage.Path -Destination $packagePath -Force

# 配布するZIPのhashとURIを、Policy JSONの生成と検証でも使用します。
$packageHash = (Get-FileHash -Path $packagePath -Algorithm SHA256).Hash
$contentUri = "$packageBaseUri/$packageFileName"

# compile時に使用した一時ファイルを削除します。
Remove-Item -Path ./guest_configuration_policy/.bicep-build -Recurse -Force
```

#### 共通手順3. packageをStorageへupload

Storageを実行端末のpublic IPだけに一時開放し、packageをuploadしたら必ず再閉鎖します。

```powershell
# Azure PowerShellでZIP packageをBlob Storageへuploadします。
# スクリプト内で実行端末向けの一時アクセスを設定し、upload後に再閉鎖します。
./guest_configuration_policy/scripts/publish-package.ps1 `
  -ResourceGroupName $resourceGroupName `
  -StorageAccountName $storageAccountName `
  -ContainerName $containerName `
  -PackagePath $packagePath `
  -PackageUploaderPrincipalId $packageUploaderPrincipalId
```

### Azure Policy方式に固有の手順

ここからが直接Assignment方式との分岐点です。直接Assignmentを作成する代わりに、各処理をAzure PowerShellコマンドで順番に実行し、Azure Policyから対象VMへGuest Configuration Assignmentをデプロイします。

#### Policy手順1. Guest Configuration Extensionをデプロイ

対象VMへGuest Configuration Extensionをデプロイします。

```powershell
# VM内で構成を評価・適用するGuest Configuration Extensionをインストールします。
# このコマンドでは、packageを指定するGuest Configuration Assignmentはまだ作成しません。
Set-AzVMExtension `
  -ResourceGroupName $resourceGroupName `
  -VMName $vmName `
  -Name 'GuestConfiguration' `
  -Publisher 'Microsoft.GuestConfiguration' `
  -ExtensionType 'ConfigurationforLinux' `
  -TypeHandlerVersion '1.0' `
  -Location $location `
  -Settings @{} `
  -ProtectedSettings @{} `
  -EnableAutomaticUpgrade $true
```

#### Policy手順2. Policy definition用のJSONを生成

`New-GuestConfigurationPolicy` はローカルのZIPからSHA-256 hashを計算し、Policy definition用のJSONへ埋め込みます。生成されたhashがupload済みpackageのhashと一致することも確認します。

```powershell
# 前回生成したPolicy JSONを削除し、今回の出力先を作成します。
$generatedPath = './guest_configuration_policy/generated'
Remove-Item -Path $generatedPath -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $generatedPath -ItemType Directory -Force | Out-Null

# upload先のURIとローカルのZIPから、DeployIfNotExistsのPolicy JSONを生成します。
# ApplyAndAutoCorrectは構成の適用後もドリフトを自動修復するモードです。
# UseSystemAssignedIdentityは、package取得に対象VMのsystem-assigned identityを使用する指定です。
# Policy assignmentのidentityとは別であり、この後の割り当て時に作成するものではありません。
New-GuestConfigurationPolicy `
  -PolicyId ([guid]$policyConfig.policyId) `
  -ContentUri $contentUri `
  -LocalContentPath $packagePath `
  -DisplayName $policyConfig.policyDisplayName `
  -Description $policyConfig.policyDescription `
  -Path $generatedPath `
  -Platform Linux `
  -Mode ApplyAndAutoCorrect `
  -PolicyVersion ([version]$policyConfig.policyVersion) `
  -UseSystemAssignedIdentity `
  -ExcludeArcMachines | Out-Null

# 生成されたJSONを読み込み、packageのhashが意図したbuild結果と一致することを確認します。
$policyFile = (Resolve-Path "$generatedPath/${configurationName}_DeployIfNotExists.json").Path
$policyJson = Get-Content -Path $policyFile -Raw | ConvertFrom-Json
$generatedContentHash = $policyJson.properties.metadata.guestConfiguration.contentHash

if ($generatedContentHash -ine $packageHash) {
  throw "Policy JSONのcontentHashがpackageのhashと一致しません: $generatedContentHash"
}
```

この時点ではPolicy definition用のJSONをローカルに生成しただけで、Azureの構成は変更されていません。

#### Policy手順3. Policy definitionを登録

生成したJSONをCustom Policy definitionとしてサブスクリプションへ登録します。

```powershell
# JSONをサブスクリプションへ登録します。この段階では対象Resource Groupへの割り当ては行いません。
$policyDefinition = New-AzPolicyDefinition `
  -Name $policyConfig.policyDefinitionName `
  -Policy $policyFile
```

#### Policy手順4. Policy definitionをResource Groupへ割り当て

対象Resource Groupのresource IDを作成し、system-assigned identity付きでPolicy definitionを割り当てます。`EnableAutoRemediation` は生成されるPolicy definitionの既定値が `false` のため、`true` を明示します。

```powershell
# 現在のサブスクリプションとResource Groupから、Policyの適用範囲を組み立てます。
$subscriptionId = (Get-AzContext).Subscription.Id
$assignmentScope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName"

# Policyを割り当て、remediationでデプロイを実行するためのidentityを作成します。
# EnableAutoRemediationは生成されたPolicyのパラメーターです。既存VM向けのremediation taskは別途開始します。
$policyAssignment = New-AzPolicyAssignment `
  -Name $policyConfig.policyAssignmentName `
  -Scope $assignmentScope `
  -PolicyDefinition $policyDefinition `
  -DisplayName $policyConfig.policyDisplayName `
  -Location $location `
  -IdentityType SystemAssigned `
  -PolicyParameterObject @{ EnableAutoRemediation = 'true' }
```

#### Policy手順5. Policy assignmentのidentityへロールを割り当て

生成したPolicy definitionが要求するロールをJSONから取得し、Policy assignmentのidentityへ対象Resource Group scopeで割り当てます。

```powershell
# Policy assignmentのidentityと、Policyが要求するロール一覧を取得します。
# VMのidentityはpackage取得用、こちらのidentityはremediationによるデプロイ用です。
$principalId = $policyAssignment.IdentityPrincipalId
$roleDefinitionIds = @(
  $policyJson.properties.policyRule.then.details.roleDefinitionIds
)

# ロールのresource IDからGUIDを取り出し、対象Resource Groupの範囲で権限を付与します。
foreach ($roleDefinitionId in $roleDefinitionIds) {
  $roleGuid = $roleDefinitionId.Split('/')[-1]
  New-AzRoleAssignment `
    -Scope $assignmentScope `
    -ObjectId $principalId `
    -RoleDefinitionId $roleGuid
}
```

Policy assignment作成直後はidentityがMicrosoft Entra IDへ反映されておらず、ロール割り当てに失敗する場合があります。その場合は少し待ってから、上記の `foreach` を再実行します。

#### Policy手順6. 既存VM向けのremediation taskを開始

Policy割り当て前から存在するVMを再評価し、Guest Configuration Assignmentをデプロイするremediation taskを開始します。

```powershell
$remediationName = "gc-rem-$($policyConfig.policyAssignmentName)"

# 既存VMを再評価し、非準拠の対象へGuest Configuration Assignmentをデプロイします。
# NoWaitは完了を待たずに戻る指定です。構成の適用結果は後続のverify.ps1で確認します。
Start-AzPolicyRemediation `
  -Name $remediationName `
  -ResourceGroupName $resourceGroupName `
  -PolicyAssignmentId $policyAssignment.Id `
  -ResourceDiscoveryMode ReEvaluateCompliance `
  -NoWait
```

通常時のVMからBlobへのアクセスはPrivate EndpointとVM identityを使用します。packageを再buildしない場合は、既存ZIPのpathとSHA-256を `$packagePath`、`$packageHash` に設定してpackage upload以降を実行します。

## 検証

上記で設定したStorage名、URI、hashを使って検証します。

```powershell
# Policy、Guest Configuration Assignment、packageのURIとhashなどを確認します。
./guest_configuration_policy/scripts/verify.ps1 `
  -ResourceGroupName $resourceGroupName `
  -VmName $vmName `
  -StorageAccountName $storageAccountName `
  -PackageContainerName $containerName `
  -ExpectedContentUri $contentUri `
  -ExpectedContentHash $packageHash
```

ドリフトと自動修復を確認します。

```powershell
# 管理対象ファイルを削除してドリフトを発生させ、自動修復を確認します。
./guest_configuration_policy/scripts/test-drift.ps1 `
  -ResourceGroupName $resourceGroupName `
  -VmName $vmName
```

## クリーンアップ

このスクリプトはremediation、Policy assignment、そのidentityのrole assignments、Guest Assignment、Guest Configuration Extension、Custom Policy definitionを削除します。Resource Group、VM、Storageは残ります。

```powershell
# Policy方式で追加したリソースと権限を削除します。基盤のVMやStorageは残します。
./guest_configuration_policy/scripts/cleanup.ps1 `
  -ResourceGroupName $resourceGroupName `
  -VmName $vmName `
  -PolicyAssignmentName $policyConfig.policyAssignmentName `
  -PolicyDefinitionName $policyConfig.policyDefinitionName
```

基盤も削除する場合は、Policy cleanupの完了後に実行します。

```powershell
# Resource Group内のVM、Storage、Networkなども含め、基盤全体を削除します。
Remove-AzResourceGroup -Name $resourceGroupName -Force
```

## 設計上の注意

- Arc-enabled serverとArc-enabled VMware VMは対象外です。
- Policy assignmentには `EnableAutoRemediation=true` を明示します。
- package filename、Blob上のfilename、Policy metadataのcontent hashは一致している必要があります。
- `policy.config.json` は構成名、version、Policy名、管理対象パスの単一source of truthです。
# Azure 基盤の準備

Guest Configuration の検証に必要な Azure 基盤を作成します。このフォルダーでは Guest Configuration Extension、DSC package、Azure Policy はデプロイしません。

## 作成するリソース

- Resource Group
- VNet、VM subnet、Private Endpoint subnet、NSG
- Ubuntu 24.04 LTS VM、System-assigned managed identity、outbound 用 Standard Public IP
- Bastion Developer
- Storage Account、private Blob container、Blob Private Endpoint、Private DNS Zone
- package uploader の `Storage Blob Data Contributor`
- VM identity の `Storage Blob Data Reader`

## 前提条件

- Azure PowerShell (`Az.Resources`)
- PATHから実行できるstandalone Bicep CLI
- Resource Group への `Owner`、または `Contributor` と `Role Based Access Control Administrator` の権限を保持していること
- `Microsoft.Compute`、`Microsoft.Network`、`Microsoft.Storage`、`Microsoft.Authorization` providerが登録されていること
- package をアップロードするユーザーの Microsoft Entra object ID

Azure PowerShellは、Azure CLIが内部管理するBicep CLIを利用できません。Windowsでは次のようにstandalone版をインストールし、新しいPowerShellを開いて認識を確認します。

```powershell
winget install -e --id Microsoft.Bicep
bicep --version
```


## デプロイ

リポジトリルートから実行します。

```powershell
$resourceGroupName = 'rg-gcpolicy'
$location = 'japaneast'
$deploymentName = 'gcpolicy-prepare'
$adminPassword = Read-Host -AsSecureString

Connect-AzAccount
$packageUploaderPrincipalId = (Get-AzADUser -SignedIn).Id

New-AzResourceGroup `
  -Name $resourceGroupName `
  -Location $location `
  -Force

New-AzResourceGroupDeployment `
  -Name $deploymentName `
  -ResourceGroupName $resourceGroupName `
  -TemplateFile ./prepare/main.bicep `
  -location $location `
  -adminPassword $adminPassword `
  -packageUploaderPrincipalId $packageUploaderPrincipalId
```

任意のStorage Account名を使う場合は `-storageAccountName` を追加します。未指定の場合は、自動で作成します。
未登録のResource Providerは、事前に `Register-AzResourceProvider -ProviderNamespace <namespace>` で登録します。

デプロイは冪等であり、同じ Resource Group に再実行できます。

## Guest Configuration への引き渡し

ローカルのhandoffファイルは作成しません。固定名のAzure deploymentからoutputsを取得できます。

```powershell
$prepareOutputs = (
  Get-AzResourceGroupDeployment `
    -ResourceGroupName $resourceGroupName `
    -Name $deploymentName
).Outputs

$prepareOutputs.vmName.Value
$prepareOutputs.storageAccountName.Value
$prepareOutputs.packageBaseUri.Value
```

続きは [Policy方式](../guest_configuration_policy/README.md) または [直接Assignment方式](../guest_configuration_assignment/README.md) のいずれか一方を選択してください。

## クリーンアップ

先に選択した方式のGuest Configuration資産を削除してから、基盤を削除します。次はPolicy方式の例です。

```powershell
pwsh ./guest_configuration_policy/scripts/cleanup.ps1 `
  -ResourceGroupName rg-gcpolicy `
  -VmName gcpolicy-vm

pwsh ./prepare/scripts/cleanup.ps1 `
  -ResourceGroupName rg-gcpolicy
```

基盤 cleanup は Resource Group の非同期削除を開始します。
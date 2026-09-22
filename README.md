# jazug-16-anniversary-demo

Azure Machine Configuration (Guest Configuration) の自動適用を検証するデモです。

デプロイは、Azure 基盤の準備と Guest Configuration の適用を独立した2段階で実行します。デプロイ用のwrapper scriptはなく、Azure PowerShell、Azure CLI、用途別の個別scriptを使用します。

## 1. Azure 基盤を準備する

`prepare/` は Resource Group、Network、VM、Bastion、Storage、Private Endpoint、package container の RBAC を作成します。

Azure PowerShellでResource Groupと [`prepare/main.bicep`](prepare/main.bicep) をデプロイします。詳細なコマンドは [prepare/README.md](prepare/README.md) を参照してください。

## 2. Guest Configuration をデプロイする

次のいずれか一方を選択します。同じVMへ両方を同時にデプロイしないでください。

- [Azure Policyによるデプロイ](guest_configuration_policy/README.md): Policy definition/assignmentとremediationで適用する
- [直接Assignmentによるデプロイ](guest_configuration_assignment/README.md): VMへGuest Configuration Assignmentを直接作成する

## クリーンアップ

依存関係と責務に合わせ、Guest Configuration、Azure 基盤の逆順で実行します。

選択した方式のcleanupを実行してから基盤を削除します。直接Assignment方式の場合は次のとおりです。

```powershell
pwsh ./guest_configuration_assignment/scripts/cleanup.ps1 `
  -ResourceGroupName rg-gcpolicy `
  -VmName gcpolicy-vm

pwsh ./prepare/scripts/cleanup.ps1 `
  -ResourceGroupName rg-gcpolicy
```
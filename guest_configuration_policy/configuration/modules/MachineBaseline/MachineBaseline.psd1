@{
    # module を import したときに最初に読み込む実装ファイル
    RootModule           = 'MachineBaseline.psm1'

    # package が依存する module の version。実装変更のたびに更新する
    ModuleVersion        = '1.0.0'

    # module を一意に識別する固定 GUID。新規作成時に 1 回だけ生成し、以後 version を上げても変えない
    GUID                 = 'f8a80bdc-8c86-4498-a690-436c262d7f21'

    Author               = 'blog-lab'
    CompanyName          = 'N/A'
    Copyright            = '(c) blog-lab'
    Description          = '指定した絶対 path にファイルが存在することを監査・適用する最小 DSC リソース'

    # この module から DSC resource として公開する class 名
    DscResourcesToExport = @('MachineBaseline')

    # Linux 対象は PSDesiredStateConfiguration 3.0.0-beta1 系でコンパイルする
    # (docs: azure/governance/machine-configuration/how-to/develop-custom-package/1-set-up-authoring-environment)
    PowerShellVersion    = '7.2'
}

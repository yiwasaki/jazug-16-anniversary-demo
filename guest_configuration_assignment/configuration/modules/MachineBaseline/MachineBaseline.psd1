@{
    RootModule           = 'MachineBaseline.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'f8a80bdc-8c86-4498-a690-436c262d7f21'
    Author               = 'blog-lab'
    CompanyName          = 'N/A'
    Copyright            = '(c) blog-lab'
    Description          = '指定した絶対 path にファイルが存在することを監査・適用する最小 DSC リソース'
    DscResourcesToExport = @('MachineBaseline')
    PowerShellVersion    = '7.2'
}
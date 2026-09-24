Configuration MachineBaseline {
    param(
        [string]$ManagedFilePath
    )

    Import-DscResource -ModuleName MachineBaseline

    Node localhost {
        MachineBaseline Main {
            Ensure     = 'Present'
            Name       = 'machine-baseline'
            TargetPath = $ManagedFilePath
        }
    }
}

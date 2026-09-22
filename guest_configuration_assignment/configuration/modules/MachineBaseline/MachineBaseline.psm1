enum Ensure {
    Absent
    Present
}

class MachineBaselineReason {
    [DscProperty()]
    [string] $Code

    [DscProperty()]
    [string] $Phrase
}

[DscResource()]
class MachineBaseline {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(Mandatory)]
    [Ensure] $Ensure = [Ensure]::Present

    [DscProperty(Mandatory)]
    [string] $TargetPath

    [DscProperty(NotConfigurable)]
    [MachineBaselineReason[]] $Reasons

    hidden [MachineBaselineReason] NewReason([string] $code, [string] $phrase) {
        $reason = [MachineBaselineReason]::new()
        $reason.Code = $code
        $reason.Phrase = $phrase
        return $reason
    }

    hidden [bool] IsValidTargetPath() {
        if ([string]::IsNullOrWhiteSpace($this.TargetPath)) {
            return $false
        }
        return [System.IO.Path]::IsPathRooted($this.TargetPath)
    }

    hidden [bool] IsInDesiredState() {
        if (-not $this.IsValidTargetPath()) {
            return $false
        }

        $exists = Test-Path -LiteralPath $this.TargetPath -PathType Leaf
        if ($this.Ensure -eq [Ensure]::Present) {
            return $exists
        }
        return -not $exists
    }

    [MachineBaseline] Get() {
        $current = [MachineBaseline]::new()
        $current.Name = $this.Name
        $current.Ensure = $this.Ensure
        $current.TargetPath = $this.TargetPath
        $current.Reasons = @()

        if (-not $this.IsValidTargetPath()) {
            $current.Reasons += $this.NewReason(
                'MachineBaseline:MachineBaseline:InvalidTargetPath',
                "TargetPath must be a non-empty absolute path. Actual value: '$($this.TargetPath)'"
            )
            return $current
        }

        $exists = Test-Path -LiteralPath $this.TargetPath -PathType Leaf
        if ($this.Ensure -eq [Ensure]::Present) {
            if ($exists) {
                $current.Reasons += $this.NewReason(
                    'MachineBaseline:MachineBaseline:Compliant',
                    "File exists as desired: $($this.TargetPath)"
                )
            }
            else {
                $current.Reasons += $this.NewReason(
                    'MachineBaseline:MachineBaseline:FileMissing',
                    "File is missing: $($this.TargetPath)"
                )
            }
        }
        else {
            if ($exists) {
                $current.Reasons += $this.NewReason(
                    'MachineBaseline:MachineBaseline:FileShouldBeAbsent',
                    "File should be absent but exists: $($this.TargetPath)"
                )
            }
            else {
                $current.Reasons += $this.NewReason(
                    'MachineBaseline:MachineBaseline:Compliant',
                    "File is absent as desired: $($this.TargetPath)"
                )
            }
        }

        return $current
    }

    [bool] Test() {
        return $this.IsInDesiredState()
    }

    [void] Set() {
        if (-not $this.IsValidTargetPath()) {
            throw "TargetPath must be a non-empty absolute path. Actual value: '$($this.TargetPath)'"
        }

        if ($this.Ensure -eq [Ensure]::Absent) {
            if (Test-Path -LiteralPath $this.TargetPath -PathType Leaf) {
                Remove-Item -LiteralPath $this.TargetPath -Force
            }
            return
        }

        if (Test-Path -LiteralPath $this.TargetPath -PathType Leaf) {
            return
        }

        $parent = Split-Path -Path $this.TargetPath -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -Path $parent -ItemType Directory -Force | Out-Null
        }

        New-Item -Path $this.TargetPath -ItemType File -Force | Out-Null
    }
}
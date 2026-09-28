# Win11Debloat - Apply explicitly configured Windows registry presets.
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Preset = 'Defaults',
    [string]$ConfigPath,
    [switch]$ListPresets,
    [switch]$Approve
)

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Win11Debloat.json'
}

# MARK: Configuration
# Validate and load only the adjacent JSON configuration file.
function Get-PresetConfiguration {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file was not found: $Path"
    }

    try {
        $configuration = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Configuration file is not valid JSON: $Path"
    }

    if ($configuration.Version -ne '1.0' -or -not $configuration.Presets) {
        throw 'Configuration must contain Version "1.0" and a Presets array.'
    }

    return $configuration
}

function Get-RegistryValueKind {
    param([string]$Type)

    $supportedTypes = @('String', 'ExpandString', 'DWord', 'QWord', 'MultiString', 'Binary')
    if ($Type -notin $supportedTypes) {
        throw "Unsupported registry value type: $Type"
    }

    return [Microsoft.Win32.RegistryValueKind]::$Type
}

function Resolve-RegistryPath {
    param([string]$Path)

    return ($Path -replace '^HKCU:', 'Registry::HKEY_CURRENT_USER' `
        -replace '^HKLM:', 'Registry::HKEY_LOCAL_MACHINE' `
        -replace '^HKCR:', 'Registry::HKEY_CLASSES_ROOT' `
        -replace '^HKU:', 'Registry::HKEY_USERS')
}

# MARK: Validation
# Reject malformed paths and values before making any registry change.
function Test-RegistryOperation {
    param($Operation)

    if (-not $Operation.Path -or -not $Operation.Action) {
        throw 'Each operation requires Path and Action.'
    }

    if ($Operation.Path -notmatch '^(HKCU|HKLM|HKCR|HKU):\\') {
        throw "Only HKCU, HKLM, HKCR, and HKU registry paths are allowed: $($Operation.Path)"
    }

    if ($Operation.Action -notin @('SetValue', 'DeleteValue', 'DeleteKey')) {
        throw "Unsupported registry action: $($Operation.Action)"
    }

    if ($Operation.Action -eq 'SetValue') {
        if ($null -eq $Operation.Name -or -not $Operation.Type -or $null -eq $Operation.Value) {
            throw 'SetValue operations require Name, Type, and Value.'
        }
        $null = Get-RegistryValueKind -Type $Operation.Type
    }
    elseif ($Operation.Action -eq 'DeleteValue' -and $null -eq $Operation.Name) {
        throw 'DeleteValue operations require Name.'
    }
}

function Convert-RegistryValue {
    param($Operation)

    switch ($Operation.Type) {
        'DWord' { return [uint32]$Operation.Value }
        'QWord' { return [uint64]$Operation.Value }
        'MultiString' { return [string[]]@($Operation.Value) }
        'Binary' { return [byte[]]@($Operation.Value) }
        default { return [string]$Operation.Value }
    }
}

# MARK: State comparison
# Skip registry operations whose requested state already matches the machine.
function Test-RegistryValueMatches {
    param(
        [Parameter(Mandatory)]$RegistryKey,
        [Parameter(Mandatory)]$Operation
    )

    $valueName = [string]$Operation.Name
    if ($RegistryKey.GetValueNames() -notcontains $valueName) {
        return $false
    }

    $expectedKind = Get-RegistryValueKind -Type $Operation.Type
    if ($RegistryKey.GetValueKind($valueName) -ne $expectedKind) {
        return $false
    }

    $expectedValue = Convert-RegistryValue -Operation $Operation
    $currentValue = $RegistryKey.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    switch ($Operation.Type) {
        'DWord' { return [uint32]$currentValue -eq [uint32]$expectedValue }
        'QWord' { return [uint64]$currentValue -eq [uint64]$expectedValue }
        'Binary' { return (@([byte[]]$currentValue) -join ',') -ceq (@([byte[]]$expectedValue) -join ',') }
        'MultiString' { return (@([string[]]$currentValue) -join "`0") -ceq (@([string[]]$expectedValue) -join "`0") }
        default { return [string]$currentValue -ceq [string]$expectedValue }
    }
}

function Test-RegistryOperationPending {
    param([Parameter(Mandatory)]$Operation)

    $path = Resolve-RegistryPath -Path $Operation.Path
    if ($Operation.Action -eq 'DeleteKey') {
        return (Test-Path -LiteralPath $path)
    }

    if (-not (Test-Path -LiteralPath $path)) {
        return ($Operation.Action -eq 'SetValue')
    }

    $registryKey = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($Operation.Action -eq 'DeleteValue') {
        return ($registryKey.GetValueNames() -contains [string]$Operation.Name)
    }

    return -not (Test-RegistryValueMatches -RegistryKey $registryKey -Operation $Operation)
}

function Get-PendingOperations {
    param([object[]]$Operations)

    $pendingOperations = [System.Collections.Generic.List[object]]::new()
    foreach ($operation in $Operations) {
        try {
            if (Test-RegistryOperationPending -Operation $operation) {
                $pendingOperations.Add($operation)
            }
        }
        catch {
            # Defer unreadable targets to the existing preflight/failure reporting path.
            $pendingOperations.Add($operation)
        }
    }

    return @($pendingOperations)
}

# MARK: Interaction
# Show the pending changes and require confirmation before registry writes.
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PresetRequiresElevation {
    param([object[]]$Operations)

    return @($Operations | Where-Object { $_.Path -match '^(HKLM|HKU|HKCR):\\' }).Count -gt 0
}

function Get-OperationSummary {
    param($Operation)

    $target = if ($Operation.Action -eq 'DeleteKey') { $Operation.Path } else { "$($Operation.Path)\$($Operation.Name)" }
    switch ($Operation.Action) {
        'SetValue' {
            $value = if ($Operation.Type -eq 'Binary') { "$(@($Operation.Value).Count) bytes" } elseif ($Operation.Type -eq 'MultiString') { "$(@($Operation.Value).Count) values" } else { $Operation.Value }
            return "Set $($Operation.Type) value '$($Operation.Name)' to '$value' at $target"
        }
        'DeleteValue' { return "Remove registry value '$($Operation.Name)' at $target" }
        'DeleteKey' { return "Remove registry key $target" }
    }
}

function Show-StartupInfo {
    param(
        [string]$PresetName,
        [bool]$RequiresElevation
    )

    Write-Host ''
    Write-Host 'Win11Debloat registry preset runner' -ForegroundColor Cyan
    Write-Host "Selected preset: $PresetName"
    if (Test-IsAdministrator) {
        Write-Host 'Elevation: Administrator' -ForegroundColor Green
    }
    elseif ($RequiresElevation) {
        Write-Warning "Preset '$PresetName' changes machine or service registry settings and requires Administrator rights."
        if (-not $WhatIfPreference) {
            throw 'Restart PowerShell as Administrator and try again.'
        }
    }
    else {
        Write-Host 'Elevation: Standard user (current-user registry changes only)' -ForegroundColor Yellow
    }
}

function Show-PresetPlan {
    param(
        $SelectedPreset,
        [object[]]$Operations,
        [object[]]$PendingOperations
    )

    Write-Host ''
    Write-Host $SelectedPreset.Description -ForegroundColor White
    $groups = $Operations | Group-Object {
        if ($_.Description) { $_.Description } else { $SelectedPreset.Description }
    }
    $alreadyMatchedCount = $Operations.Count - $PendingOperations.Count
    Write-Host "Intent: $($Operations.Count) operations across $($groups.Count) change categories." -ForegroundColor Cyan
    Write-Host "Current baseline: $alreadyMatchedCount already match; $($PendingOperations.Count) pending." -ForegroundColor Cyan
    $groups = $Operations | Group-Object {
        if ($_.Description) { $_.Description } else { $SelectedPreset.Description }
    }
    foreach ($group in $groups) {
        $pendingInGroup = @($PendingOperations | Where-Object {
            $description = if ($_.Description) { $_.Description } else { $SelectedPreset.Description }
            $description -eq $group.Name
        })
        $matchedInGroup = $group.Count - $pendingInGroup.Count
        Write-Host "- $($group.Name): intended $($group.Count); matched $matchedInGroup; pending $($pendingInGroup.Count)"
        if ($pendingInGroup.Count -eq 1) {
            Write-Host "  $(Get-OperationSummary -Operation $pendingInGroup[0])" -ForegroundColor DarkGray
        }
    }
}

function Confirm-PresetApplication {
    param([switch]$Bypass)

    if ($WhatIfPreference -or $Bypass) {
        return $true
    }

    return (Read-Host 'Apply these changes? [y/N]') -match '^[Yy]$'
}

function Wait-ForInteractiveExit {
    if (-not $Approve -and -not $WhatIfPreference) {
        $null = Read-Host 'Press Enter to exit'
    }
}

function Test-RegistryPathWritable {
    param([string]$Path)

    $probePath = $Path
    while (-not (Test-Path -LiteralPath $probePath)) {
        $separatorIndex = $probePath.LastIndexOf('\')
        if ($separatorIndex -lt 0) {
            throw "Cannot determine an existing writable parent for registry path '$Path'."
        }
        $probePath = $probePath.Substring(0, $separatorIndex)
    }

    try {
        $key = Get-Item -LiteralPath $probePath -ErrorAction Stop
        $writableKey = $key.OpenSubKey('', $true)
        if (-not $writableKey) {
            throw "The registry key '$probePath' cannot be opened for writing."
        }
        $writableKey.Close()
    }
    catch {
        throw "Write access check failed for '$Path': $($_.Exception.Message)"
    }
}

function Test-PresetWriteAccess {
    param([object[]]$Operations)

    if ($WhatIfPreference) {
        return @()
    }

    $testedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $failures = [System.Collections.Generic.List[object]]::new()
    foreach ($operation in $Operations) {
        $path = Resolve-RegistryPath -Path $operation.Path
        if ($testedPaths.Add($path)) {
            try {
                Test-RegistryPathWritable -Path $path
            }
            catch {
                $failures.Add([PSCustomObject]@{
                    Path = $path
                    Error = $_.Exception.Message
                })
            }
        }
    }

    return @($failures)
}

# MARK: Apply
# Apply one named preset after all of its operations pass validation.
function Invoke-Preset {
    param(
        [Parameter(Mandatory)]$SelectedPreset,
        [object[]]$PreflightFailures = @()
    )

    $operations = @($SelectedPreset.Operations)
    if ($operations.Count -eq 0) {
        throw "Preset '$($SelectedPreset.Name)' has no operations."
    }

    foreach ($operation in $operations) {
        Test-RegistryOperation -Operation $operation
    }

    if ((Test-PresetRequiresElevation -Operations $operations) -and -not (Test-IsAdministrator) -and -not $WhatIfPreference) {
        throw "Preset '$($SelectedPreset.Name)' requires Administrator rights because it changes HKLM, HKU, or HKCR. No changes were applied."
    }

    $preflightFailureLookup = @{}
    foreach ($failure in $PreflightFailures) {
        $preflightFailureLookup[$failure.Path] = $failure.Error
    }
    $failures = [System.Collections.Generic.List[object]]::new()

    foreach ($operation in $operations) {
        $path = Resolve-RegistryPath -Path $operation.Path
        $target = if ($operation.Action -eq 'DeleteKey') { $operation.Path } else { "$($operation.Path)\$($operation.Name)" }

        if ($preflightFailureLookup.ContainsKey($path)) {
            $failures.Add([PSCustomObject]@{ Action = $operation.Action; Target = $target; Error = $preflightFailureLookup[$path] })
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($target, $operation.Action)) {
            continue
        }

        try {
            switch ($operation.Action) {
                'SetValue' {
                    $value = Convert-RegistryValue -Operation $operation
                    $kind = Get-RegistryValueKind -Type $operation.Type
                    if (-not (Test-Path -LiteralPath $path)) {
                        New-Item -Path $path -Force -ErrorAction Stop | Out-Null
                    }
                    New-ItemProperty -Path $path -Name $operation.Name -Value $value -PropertyType $kind -Force -ErrorAction Stop | Out-Null
                }
                'DeleteValue' {
                    if (Test-Path -LiteralPath $path) {
                        $registryKey = Get-Item -LiteralPath $path -ErrorAction Stop
                        if ($registryKey.GetValueNames() -contains $operation.Name) {
                            Remove-ItemProperty -LiteralPath $path -Name $operation.Name -ErrorAction Stop
                        }
                    }
                }
                'DeleteKey' {
                    if (Test-Path -LiteralPath $path) {
                        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                    }
                }
            }
        }
        catch {
            $failures.Add([PSCustomObject]@{ Action = $operation.Action; Target = $target; Error = $_.Exception.Message })
            continue
        }

        Write-Host "$($operation.Action): $target"
    }

    return @($failures)
}

# MARK: Entry point
# Locate the requested preset and run it only when explicitly selected.
try {
    $configuration = Get-PresetConfiguration -Path $ConfigPath
    $presets = @($configuration.Presets)

    if ($ListPresets) {
        $presets | ForEach-Object { "{0}: {1}" -f $_.Name, $_.Description }
        return
    }

    $selectedPreset = @($presets | Where-Object { $_.Name -ieq $Preset })
    if ($selectedPreset.Count -ne 1) {
        $availablePresets = ($presets.Name | Sort-Object) -join ', '
        throw "Preset '$Preset' was not found. Available presets: $availablePresets"
    }

    $operations = @($selectedPreset[0].Operations)
    if ($operations.Count -eq 0) {
        throw "Preset '$Preset' has no operations."
    }
    foreach ($operation in $operations) {
        Test-RegistryOperation -Operation $operation
    }

    $pendingOperations = @(Get-PendingOperations -Operations $operations)
    if (-not $Approve -and -not $WhatIfPreference) {
        Clear-Host
    }

    Show-StartupInfo -PresetName $selectedPreset[0].Name -RequiresElevation:(Test-PresetRequiresElevation -Operations $pendingOperations)
    Show-PresetPlan -SelectedPreset $selectedPreset[0] -Operations $operations -PendingOperations $pendingOperations
    if ($pendingOperations.Count -eq 0) {
        Write-Host 'Current registry state already matches the selected preset. No changes were applied.' -ForegroundColor Green
        Wait-ForInteractiveExit
        return
    }

    $preflightFailures = @(Test-PresetWriteAccess -Operations $pendingOperations)
    if ($preflightFailures.Count -gt 0) {
        Write-Warning "$($preflightFailures.Count) registry target(s) cannot be written and will be skipped."
    }
    if (-not (Confirm-PresetApplication -Bypass:$Approve)) {
        Write-Host 'No changes were applied.' -ForegroundColor Yellow
        Wait-ForInteractiveExit
        return
    }

    $pendingPreset = [PSCustomObject]@{ Name = $selectedPreset[0].Name; Operations = $pendingOperations }
    $failures = @(Invoke-Preset -SelectedPreset $pendingPreset -PreflightFailures $preflightFailures)
    if ($failures.Count -gt 0) {
        Write-Host ''
        Write-Host "Completed: $($pendingOperations.Count - $failures.Count) applied; $($operations.Count - $pendingOperations.Count) already matched; $($failures.Count) issue(s)." -ForegroundColor Yellow
        foreach ($failure in $failures) {
            Write-Host "- $($failure.Action): $($failure.Target)" -ForegroundColor Yellow
            Write-Host "  $($failure.Error)" -ForegroundColor DarkYellow
        }
        Wait-ForInteractiveExit
        exit 1
    }

    Write-Host ''
    Write-Host "Completed: $($pendingOperations.Count) applied; $($operations.Count - $pendingOperations.Count) already matched." -ForegroundColor Green
    Wait-ForInteractiveExit
}
catch {
    Write-Error $_.Exception.Message
    Wait-ForInteractiveExit
    exit 1
}
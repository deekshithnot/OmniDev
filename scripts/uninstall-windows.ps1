#requires -Version 5.1
<#
.SYNOPSIS
    Removes the OmniDev Windows MSI and, with explicit confirmation, its local data.

.DESCRIPTION
    Windows Installer removes the application files. This script additionally
    removes the engine home (SQLite database, credentials, logs and default
    projects). A project root configured outside the engine home is preserved
    unless its exact path is separately confirmed with -DeleteExternalProjects.

    Run from a normal PowerShell session. Windows Installer may request elevation.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$KeepUserData,
    [switch]$DeleteUserData,
    [switch]$DeleteExternalProjects
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($KeepUserData -and ($DeleteUserData -or $DeleteExternalProjects)) {
    throw 'KeepUserData cannot be combined with a data-deletion option.'
}

function Resolve-OmniDevPath {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    $resolved = [Environment]::ExpandEnvironmentVariables($Value.Trim())
    if (($resolved.StartsWith('"') -and $resolved.EndsWith('"')) -or
        ($resolved.StartsWith("'") -and $resolved.EndsWith("'"))) {
        $resolved = $resolved.Substring(1, $resolved.Length - 2)
    }

    if (-not [System.IO.Path]::IsPathRooted($resolved)) {
        $resolved = Join-Path $BasePath $resolved
    }
    return [System.IO.Path]::GetFullPath($resolved)
}

function Assert-SafeDeletionPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $driveRoot = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd('\')
    $userProfile = [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
    $windowsDirectory = [System.IO.Path]::GetFullPath($env:WINDIR).TrimEnd('\')

    if ([string]::IsNullOrWhiteSpace($fullPath) -or
        $fullPath -eq $driveRoot -or
        $fullPath -eq $userProfile -or
        $fullPath -eq $windowsDirectory) {
        throw "Refusing to remove a protected or dangerously broad path: $Path"
    }
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return $fullPath.Equals($fullParent, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullParent + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ConfiguredProjectRoot {
    param([Parameter(Mandatory = $true)][string]$HomePath)

    $configured = $env:PROJECT_ROOT
    if ([string]::IsNullOrWhiteSpace($configured)) {
        $envFile = Join-Path $HomePath '.env'
        if (Test-Path -LiteralPath $envFile -PathType Leaf) {
            $line = Get-Content -LiteralPath $envFile |
                Where-Object { $_ -match '^\s*PROJECT_ROOT\s*=' } |
                Select-Object -Last 1
            if ($line -match '^\s*PROJECT_ROOT\s*=\s*(.*?)\s*$') {
                $configured = $Matches[1]
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($configured)) {
        return [System.IO.Path]::GetFullPath((Join-Path $HomePath 'projects'))
    }
    return Resolve-OmniDevPath -Value $configured -BasePath $HomePath
}

function Get-InstalledOmniDevMsi {
    $registryLocations = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $seen = @{}
    foreach ($location in $registryLocations) {
        $entries = Get-ItemProperty -Path $location -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq 'OmniDev' }

        foreach ($entry in $entries) {
            $productCode = $null
            if ($entry.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') {
                $productCode = $entry.PSChildName
            }
            elseif ($entry.UninstallString -match '\{[0-9A-Fa-f-]{36}\}') {
                $productCode = $Matches[0]
            }

            if (-not $productCode) {
                throw "Found an OmniDev uninstall entry but could not read its MSI product code: $($entry.DisplayName)"
            }
            if (-not $seen.ContainsKey($productCode)) {
                $seen[$productCode] = $true
                [pscustomobject]@{
                    ProductCode = $productCode
                    DisplayName = $entry.DisplayName
                }
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    throw 'USERPROFILE is not available. Run this script in the Windows user account that owns the OmniDev installation.'
}

$customHome = -not [string]::IsNullOrWhiteSpace($env:OMNIDEV_HOME)
if ($customHome) {
    $dataHome = Resolve-OmniDevPath -Value $env:OMNIDEV_HOME -BasePath (Get-Location).Path
}
else {
    $dataHome = [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.omnidev'))
}
Assert-SafeDeletionPath -Path $dataHome

Write-Host ''
Write-Host 'OmniDev complete uninstaller' -ForegroundColor Cyan
Write-Host "Data location: $dataHome"
Write-Host ''

$installed = @(Get-InstalledOmniDevMsi)
if ($installed.Count -eq 0) {
    Write-Host 'No registered OmniDev MSI was found. Continuing with the data cleanup step.'
}
else {
    foreach ($app in $installed) {
        Write-Host "Removing $($app.DisplayName) ($($app.ProductCode))..."
        if ($PSCmdlet.ShouldProcess($app.ProductCode, 'Uninstall OmniDev Windows Installer package')) {
            $msiexec = Join-Path $env:WINDIR 'System32\msiexec.exe'
            $result = Start-Process -FilePath $msiexec -ArgumentList @('/x', $app.ProductCode, '/passive', '/norestart') -Wait -PassThru
            if ($result.ExitCode -notin @(0, 1605, 3010)) {
                throw "Windows Installer returned exit code $($result.ExitCode). User data was not removed."
            }
            if ($result.ExitCode -eq 3010) {
                Write-Warning 'Windows requested a restart to finish removing the application.'
            }
        }
    }
}

if ($KeepUserData) {
    Write-Host "Keeping all OmniDev data at: $dataHome" -ForegroundColor Yellow
    Write-Host 'The application uninstall step is complete.'
    return
}

if (Test-Path -LiteralPath $dataHome) {
    if (-not $DeleteUserData -and -not $WhatIfPreference) {
        if ($customHome) {
            $expectedConfirmation = $dataHome
            Write-Warning 'OMNIDEV_HOME points to a custom folder.'
            $prompt = 'Type the full data path shown above to permanently delete it'
        }
        else {
            $expectedConfirmation = 'DELETE ALL OMNIDEV DATA'
            $prompt = 'Type DELETE ALL OMNIDEV DATA to permanently remove the database, credentials, logs and default projects'
        }

        $confirmation = Read-Host $prompt
        if ($confirmation -cne $expectedConfirmation) {
            Write-Host "User data was kept at: $dataHome" -ForegroundColor Yellow
            return
        }
    }

    if ($PSCmdlet.ShouldProcess($dataHome, 'Permanently delete OmniDev database, credentials, logs and files')) {
        Remove-Item -LiteralPath $dataHome -Recurse -Force
        Write-Host "Removed OmniDev data: $dataHome" -ForegroundColor Green
    }
}
else {
    Write-Host 'No OmniDev data folder was found.'
}

$projectRoot = Get-ConfiguredProjectRoot -HomePath $dataHome
if (-not (Test-PathInside -Path $projectRoot -Parent $dataHome)) {
    if ($DeleteExternalProjects -and (Test-Path -LiteralPath $projectRoot)) {
        Assert-SafeDeletionPath -Path $projectRoot
        Write-Warning "A custom project folder is outside the OmniDev data folder: $projectRoot"
        if (-not $WhatIfPreference) {
            $projectConfirmation = Read-Host 'Type the exact custom project path to permanently delete it'
            if ($projectConfirmation -cne $projectRoot) {
                Write-Host "Custom project files were kept at: $projectRoot" -ForegroundColor Yellow
                return
            }
        }
        if ($PSCmdlet.ShouldProcess($projectRoot, 'Permanently delete the external project folder')) {
            Remove-Item -LiteralPath $projectRoot -Recurse -Force
            Write-Host "Removed custom project folder: $projectRoot" -ForegroundColor Green
        }
    }
    else {
        Write-Host "Preserved custom project folder outside OmniDev data: $projectRoot" -ForegroundColor Yellow
        Write-Host 'To remove it too, rerun with -DeleteExternalProjects and confirm its exact path.'
    }
}

Write-Host ''
Write-Host 'OmniDev uninstall finished.' -ForegroundColor Green

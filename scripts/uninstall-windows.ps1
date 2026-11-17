#requires -Version 5.1
<#
.SYNOPSIS
    Interactive complete uninstaller for OmniDev on Windows.

.DESCRIPTION
    Option 1 removes the Windows MSI and preserves all user data.
    Option 2 removes the Windows MSI, engine data, credentials, logs,
    default projects, app-specific WebView2 profile, and configured projects.

    A project folder outside the engine home is shown and requires the user
    to type its exact path before it can be deleted. The shared WebView2
    runtime and data belonging to other applications are never removed.

    Run this script as the Windows account that owns the OmniDev installation.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:TauriIdentifier = 'com.omnidev.desktop'

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
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

    $fullPath = Get-NormalizedPath -Path $Path
    $driveRoot = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd('\')
    $userProfile = Get-NormalizedPath -Path $env:USERPROFILE
    $windowsDirectory = Get-NormalizedPath -Path $env:WINDIR

    if ([string]::IsNullOrWhiteSpace($fullPath) -or
        $fullPath -eq $driveRoot -or
        $fullPath -eq $userProfile -or
        $fullPath -eq $windowsDirectory) {
        throw "Refusing to remove a protected or dangerously broad path: $Path"
    }

    if (Test-Path -LiteralPath $fullPath) {
        $item = Get-Item -LiteralPath $fullPath -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to recursively remove a junction or symbolic link: $fullPath"
        }
    }
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $fullPath = Get-NormalizedPath -Path $Path
    $fullParent = Get-NormalizedPath -Path $Parent
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
    $locations = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $seen = @{}

    foreach ($location in $locations) {
        $entries = @(Get-ItemProperty -Path $location -ErrorAction SilentlyContinue)

        foreach ($entry in $entries) {
            # Uninstall registry keys are not uniform: Windows and other
            # applications create entries without DisplayName or MSI fields.
            # Under StrictMode, direct access to a missing property throws.
            $displayNameProperty = $entry.PSObject.Properties['DisplayName']
            if ($null -eq $displayNameProperty -or
                $displayNameProperty.Value -ne 'OmniDev') {
                continue
            }

            $productCode = $null
            $childNameProperty = $entry.PSObject.Properties['PSChildName']
            if ($null -ne $childNameProperty -and
                $childNameProperty.Value -match '^\{[0-9A-Fa-f-]{36}\}$') {
                $productCode = $childNameProperty.Value
            }
            else {
                $uninstallProperty = $entry.PSObject.Properties['UninstallString']
                if ($null -ne $uninstallProperty -and
                    $uninstallProperty.Value -match '\{[0-9A-Fa-f-]{36}\}') {
                    $productCode = $Matches[0]
                }
            }

            if (-not $productCode) {
                throw "Found OmniDev in the uninstall registry but could not read its MSI product code."
            }

            if (-not $seen.ContainsKey($productCode)) {
                $seen[$productCode] = $true
                [pscustomobject]@{
                    ProductCode = $productCode
                    DisplayName = 'OmniDev'
                }
            }
        }
    }
}

function Stop-OmniDevBeforeRemoval {
    $desktopProcesses = @(Get-Process -Name 'OmniDev' -ErrorAction SilentlyContinue)
    foreach ($process in $desktopProcesses) {
        if ($process.MainWindowHandle -ne 0) {
            [void]$process.CloseMainWindow()
        }
    }

    if ($desktopProcesses.Count -gt 0) {
        Start-Sleep -Seconds 3
    }

    $remainingDesktop = @(Get-Process -Name 'OmniDev' -ErrorAction SilentlyContinue)
    $engineProcesses = @(Get-Process -Name 'omnidev-cli' -ErrorAction SilentlyContinue)
    if ($remainingDesktop.Count -gt 0 -or $engineProcesses.Count -gt 0) {
        throw 'Close OmniDev and stop any manually started omnidev-cli engine, then run the uninstaller again. No user data has been removed.'
    }
}

if ([string]::IsNullOrWhiteSpace($env:USERPROFILE) -or
    [string]::IsNullOrWhiteSpace($env:WINDIR)) {
    throw 'Required Windows environment paths are unavailable.'
}

$customHome = -not [string]::IsNullOrWhiteSpace($env:OMNIDEV_HOME)
if ($customHome) {
    $dataHome = Resolve-OmniDevPath -Value $env:OMNIDEV_HOME -BasePath (Get-Location).Path
}
else {
    $dataHome = [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.omnidev'))
}
Assert-SafeDeletionPath -Path $dataHome

$projectRoot = Get-ConfiguredProjectRoot -HomePath $dataHome
$externalProjectRoot = -not (Test-PathInside -Path $projectRoot -Parent $dataHome)
if ($externalProjectRoot -and (Test-PathInside -Path $dataHome -Parent $projectRoot)) {
    throw "The configured project root is a parent of the OmniDev data folder. Refusing unsafe deletion: $projectRoot"
}

$localAppData = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
$roamingAppData = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::ApplicationData)
$dataPaths = @(
    $dataHome,
    (Join-Path $localAppData $script:TauriIdentifier),
    (Join-Path $roamingAppData $script:TauriIdentifier)
) | Select-Object -Unique

Write-Host ''
Write-Host 'OMNIDEV UNINSTALLER' -ForegroundColor Cyan
Write-Host 'Choose what to remove:'
Write-Host ''
Write-Host '  [1] Remove OmniDev application only'
Write-Host '      Keep projects, API keys, database, chat history, settings and caches.'
Write-Host ''
Write-Host '  [2] Remove OmniDev application AND ALL OmniDev data'
Write-Host '      Remove projects, API keys, database, chat history, settings, logs,'
Write-Host '      connection tokens, app-specific WebView data and caches.'
Write-Host ''
if ($externalProjectRoot) {
    Write-Host "  Custom project folder detected: $projectRoot" -ForegroundColor Yellow
    Write-Host '  Option 2 will offer to delete this folder after showing its exact path.'
    Write-Host ''
}
Write-Host 'The shared Microsoft Edge WebView2 runtime will not be removed.'
Write-Host ''

$choice = Read-Host 'Enter 1 or 2'
if ($choice -notin @('1', '2')) {
    Write-Host 'Uninstall cancelled. Nothing was changed.' -ForegroundColor Yellow
    return
}

if ($choice -eq '2') {
    Write-Host ''
    Write-Host 'The following OmniDev data locations will be removed if they exist:'
    foreach ($path in $dataPaths) {
        Write-Host "  - $path"
    }
    if ($externalProjectRoot) {
        Write-Host "  - Custom project folder: $projectRoot"
    }
    Write-Host ''
    $confirmation = Read-Host 'Type DELETE ALL OMNIDEV DATA to continue'
    if ($confirmation -cne 'DELETE ALL OMNIDEV DATA') {
        Write-Host 'Uninstall cancelled. Nothing was changed.' -ForegroundColor Yellow
        return
    }

    if ($externalProjectRoot -and (Test-Path -LiteralPath $projectRoot)) {
        Write-Host ''
        Write-Warning 'This project folder is outside the OmniDev data directory.'
        Write-Host "Project folder: $projectRoot"
        $projectConfirmation = Read-Host 'Type the exact project path to include it in the deletion'
        if ($projectConfirmation -cne $projectRoot) {
            Write-Host 'Custom projects will be preserved. OmniDev app and its internal data can still be removed.'
            $externalProjectRoot = $false
        }
    }
}

Stop-OmniDevBeforeRemoval

$installed = @(Get-InstalledOmniDevMsi)
if ($installed.Count -eq 0) {
    Write-Host 'No registered OmniDev MSI was found. Continuing with the selected data option.'
}
else {
    foreach ($app in $installed) {
        Write-Host "Uninstalling $($app.DisplayName)..."
        if ($PSCmdlet.ShouldProcess($app.ProductCode, 'Uninstall OmniDev Windows Installer package')) {
            $msiexec = Join-Path $env:WINDIR 'System32\msiexec.exe'
            $result = Start-Process -FilePath $msiexec -ArgumentList @('/x', $app.ProductCode, '/passive', '/norestart') -Wait -PassThru
            if ($result.ExitCode -notin @(0, 1605, 3010)) {
                throw "Windows Installer returned exit code $($result.ExitCode). Data cleanup was stopped."
            }
            if ($result.ExitCode -eq 3010) {
                Write-Warning 'Windows requested a restart to finish removing the application.'
            }
        }
    }
}

if ($choice -eq '1') {
    Write-Host ''
    Write-Host 'OmniDev application removed. Your projects, API keys and all user data were kept.' -ForegroundColor Green
    return
}

foreach ($path in $dataPaths) {
    if (Test-Path -LiteralPath $path) {
        Assert-SafeDeletionPath -Path $path
        if ($PSCmdlet.ShouldProcess($path, 'Permanently delete OmniDev-owned data and app-specific WebView profile')) {
            Remove-Item -LiteralPath $path -Recurse -Force
            Write-Host "Removed: $path" -ForegroundColor Green
        }
    }
}

if ($externalProjectRoot -and (Test-Path -LiteralPath $projectRoot)) {
    Assert-SafeDeletionPath -Path $projectRoot
    if ($PSCmdlet.ShouldProcess($projectRoot, 'Permanently delete the separately confirmed custom project folder')) {
        Remove-Item -LiteralPath $projectRoot -Recurse -Force
        Write-Host "Removed custom project folder: $projectRoot" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'OmniDev and its selected data have been removed.' -ForegroundColor Green

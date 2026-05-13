<#
.SYNOPSIS
Admin entrypoint for publishing Browsium release binaries.

.DESCRIPTION
Runs setup validation first. If validation passes, launches the interactive
release upload wizard. Validation failures stop the release flow before any
upload decisions are made.
#>

[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$RcloneRemote = "browsium-r2",
    [string]$Bucket = "browsium-releases",
    [string]$AccountId = "2b2861c0bba0855e5f6ed79a9451e6b2",
    [string]$PublicBaseUrl = "https://release.browsium.com",
    [switch]$CleanupRcloneRemote,
    [switch]$KeepRcloneRemote,
    [switch]$SkipWrangler,
    [switch]$SkipPublicUrlCheck
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$ScriptVersion = "0.1.2"

function Get-ScriptPath {
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        return $PSCommandPath
    }
    return $MyInvocation.ScriptName
}

function Confirm-Yes {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,
        [bool]$DefaultNo = $true
    )

    $suffix = if ($DefaultNo) { "[y/N]" } else { "[Y/n]" }
    $value = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return -not $DefaultNo
    }
    return $value -match '^(y|yes)$'
}

function Invoke-CommandText {
    param(
        [Parameter(Mandatory)]
        [string]$Command,
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $escapedArguments = foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') {
            '"' + ($argument -replace '"', '\"') + '"'
        } else {
            $argument
        }
    }

    $resolvedCommand = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
    $commandPath = if ($resolvedCommand -and $resolvedCommand.Source) { $resolvedCommand.Source } else { $Command }
    $argumentText = ($escapedArguments -join " ")

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    if ($commandPath -match '\.ps1$') {
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$commandPath`" $argumentText"
    } elseif ($commandPath -match '\.(cmd|bat)$') {
        $psi.FileName = $env:ComSpec
        $psi.Arguments = "/d /c `"$commandPath`" $argumentText"
    } else {
        $psi.FileName = $commandPath
        $psi.Arguments = $argumentText
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi

    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } catch {
        $stdout = ""
        $stderr = $_.Exception.Message
        $exitCode = 1
    } finally {
        $process.Dispose()
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output = (@($stdout, $stderr) -join "`n").Trim()
    }
}

function Test-RcloneRemoteExists {
    param([Parameter(Mandatory)][string]$RemoteName)

    $result = Invoke-CommandText -Command "rclone" -Arguments @("config", "show", $RemoteName)
    return $result.ExitCode -eq 0
}

function Remove-RcloneRemote {
    param([Parameter(Mandatory)][string]$RemoteName)

    if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
        Write-Host "rclone is not available; no local rclone remote was removed." -ForegroundColor Yellow
        return $false
    }

    if (-not (Test-RcloneRemoteExists -RemoteName $RemoteName)) {
        Write-Host "No local rclone remote named '$RemoteName' was found." -ForegroundColor DarkGray
        return $true
    }

    $result = Invoke-CommandText -Command "rclone" -Arguments @("config", "delete", $RemoteName)
    if ($result.ExitCode -eq 0) {
        Write-Host "Removed local rclone remote '$RemoteName'." -ForegroundColor Green
        Write-Host "This did not delete the R2 bucket or revoke the Cloudflare API token." -ForegroundColor DarkGray
        return $true
    }

    Write-Host "Failed to remove local rclone remote '$RemoteName'." -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
        Write-Host $result.Output -ForegroundColor Red
    }
    return $false
}

function Invoke-RcloneCleanupPrompt {
    param([Parameter(Mandatory)][string]$RemoteName)

    Write-Host ""
    Write-Host "Cleanup and reset rclone settings" -ForegroundColor Cyan
    Write-Host "This removes the local rclone profile '$RemoteName' and its stored R2 publish credentials from this machine." -ForegroundColor DarkGray
    Write-Host "It does not delete the R2 bucket, remove uploaded files, revoke the Cloudflare token, or log out Wrangler." -ForegroundColor DarkGray

    if ($KeepRcloneRemote) {
        Write-Host "Keeping local rclone remote because -KeepRcloneRemote was supplied." -ForegroundColor Yellow
        return
    }

    if ($CleanupRcloneRemote -or (Confirm-Yes -Prompt "Cleanup and reset local rclone settings now?" -DefaultNo $false)) {
        [void](Remove-RcloneRemote -RemoteName $RemoteName)
    } else {
        Write-Host "Keeping local rclone remote '$RemoteName'." -ForegroundColor Yellow
    }
}

$toolsRoot = Split-Path -Parent (Get-ScriptPath)
$repoRoot = Split-Path -Parent $toolsRoot
$setupScript = Join-Path $toolsRoot "Test-BrowsiumReleaseSetup.ps1"
$releaseScript = Join-Path $toolsRoot "Sync-BrowsiumReleaseR2.ps1"

if (-not (Test-Path -LiteralPath $setupScript -PathType Leaf)) {
    throw "Setup validation script not found: $setupScript"
}
if (-not (Test-Path -LiteralPath $releaseScript -PathType Leaf)) {
    throw "Release sync script not found: $releaseScript"
}

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $currentDir = (Get-Location).ToString()
    $currentName = Split-Path -Leaf $currentDir

    if ($currentDir -eq $repoRoot -or $currentDir -eq $toolsRoot) {
        $SourceDir = Join-Path $repoRoot "release"
    } elseif ($currentName -eq "release") {
        $SourceDir = $currentDir
    } else {
        $SourceDir = $currentDir
    }
}

Write-Host ""
Write-Host "ReleaseTime v$ScriptVersion" -ForegroundColor Cyan
Write-Host "Step 1: setup validation. Step 2: release upload wizard." -ForegroundColor DarkGray
Write-Host ""

$setupArgs = @{
    SourceDir = $SourceDir
    RcloneRemote = $RcloneRemote
    Bucket = $Bucket
    AccountId = $AccountId
    PublicBaseUrl = $PublicBaseUrl
    ReportDir = (Join-Path $repoRoot ".reports/r2-setup")
    NonInteractive = $true
    Repair = $true
}
if ($SkipWrangler) {
    $setupArgs.SkipWrangler = $true
}
if ($SkipPublicUrlCheck) {
    $setupArgs.SkipPublicUrlCheck = $true
}

& $setupScript @setupArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "ReleaseTime stopped because setup validation did not pass." -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "Setup validation passed. Launching release wizard..." -ForegroundColor Green

try {
    & $releaseScript `
        -SourceDir $SourceDir `
        -RcloneRemote $RcloneRemote `
        -Bucket $Bucket `
        -ScopeMode Wizard `
        -ReportDir (Join-Path $repoRoot ".reports/r2-sync")

    $releaseExitCode = $LASTEXITCODE
} catch {
    $releaseExitCode = 1
    Write-Host ""
    Write-Host "Release wizard failed: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Invoke-RcloneCleanupPrompt -RemoteName $RcloneRemote
}

exit $releaseExitCode

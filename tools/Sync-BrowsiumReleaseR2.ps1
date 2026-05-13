<#
.SYNOPSIS
Interactive uploader for Browsium release binaries to Cloudflare R2.

.DESCRIPTION
Scans a local release directory, filters release binaries by file, minor version,
or major version, compares them against an R2 bucket through rclone, and runs a
dry run by default. Upload mode must be selected explicitly.
#>

[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$RcloneRemote = "browsium-r2",
    [string]$Bucket = "browsium-releases",
    [ValidateSet("Wizard", "File", "Minor", "Major")]
    [string]$ScopeMode = "Wizard",
    [string]$FileName,
    [string]$MinorVersion,
    [string]$MajorVersion,
    [switch]$IncludeSpecialBuilds,
    [switch]$Upload,
    [switch]$DryRun,
    [switch]$VerifyOnly,
    [string]$ReportDir
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$ScriptVersion = "0.1.2"

$SpecialBuildPattern = '(?i)(pre[-_ ]?release|prerelease|beta|alpha|eval|evaluation|test|sso|debug|dump|bxsdk|msedge)'
$BinaryExtensions = @(".zip", ".exe")

function Convert-VersionSelector {
    param(
        [Parameter(Mandatory)]
        [string]$Value,
        [Parameter(Mandatory)]
        [ValidateSet("Minor", "Major")]
        [string]$RequestedScope
    )

    $normalized = $Value.Trim()
    if ($normalized -match '^(?<major>\d+)(?:\.(?:x|X|\*))$') {
        return [pscustomobject]@{
            Scope = "Major"
            Value = $Matches["major"]
            Display = "$($Matches["major"]).X"
        }
    }
    if ($normalized -match '^(?<major>\d+)$') {
        return [pscustomobject]@{
            Scope = "Major"
            Value = $Matches["major"]
            Display = "$($Matches["major"]).X"
        }
    }
    if ($normalized -match '^(?<major>\d+)\.(?<minor>\d+)$') {
        return [pscustomobject]@{
            Scope = "Minor"
            Value = "$($Matches["major"]).$($Matches["minor"])"
            Display = "$($Matches["major"]).$($Matches["minor"])"
        }
    }

    if ($RequestedScope -eq "Minor") {
        throw "Version must look like '4.9' for a minor release or '4.X' for all 4.x releases."
    }
    throw "Version must look like '4' or '4.X' for all 4.x releases."
}

function Convert-VersionSelectorList {
    param(
        [Parameter(Mandatory)]
        [string]$Value,
        [Parameter(Mandatory)]
        [ValidateSet("Minor", "Major")]
        [string]$RequestedScope
    )

    $parts = @($Value -split '[,; ]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts.Count -eq 0) {
        throw "Enter at least one version selector."
    }

    $parts | ForEach-Object {
        Convert-VersionSelector -Value $_ -RequestedScope $RequestedScope
    }
}

function Get-ReleaseVersionInfo {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File
    )

    $match = [regex]::Match($File.BaseName, '(?<!\d)(?<major>\d+)[\._](?<minor>\d+)(?:[\._](?<patch>\d+))?')
    if (-not $match.Success) {
        return $null
    }

    [pscustomobject]@{
        Major = $match.Groups["major"].Value
        Minor = "$($match.Groups["major"].Value).$($match.Groups["minor"].Value)"
        Raw = $match.Value
    }
}

function Get-ScriptPath {
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        return $PSCommandPath
    }
    return $MyInvocation.ScriptName
}

function Get-DefaultSourceDir {
    $scriptDir = Split-Path -Parent (Get-ScriptPath)
    $repoRoot = Split-Path -Parent $scriptDir
    $currentDir = (Get-Location).ToString()

    if ($currentDir -eq $repoRoot -or $currentDir -eq $scriptDir) {
        return (Join-Path $repoRoot "release")
    }

    return $currentDir
}

function Read-Defaulted {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,
        [string]$Default
    )

    if ([string]::IsNullOrWhiteSpace($Default)) {
        return (Read-Host $Prompt)
    }

    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value
}

function Read-Choice {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,
        [Parameter(Mandatory)]
        [string[]]$Choices,
        [Parameter(Mandatory)]
        [string]$Default
    )

    $choiceText = ($Choices | ForEach-Object {
        if ($_ -eq $Default) { "$_ (default)" } else { $_ }
    }) -join " / "

    while ($true) {
        $value = Read-Host "$Prompt ($choiceText)"
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $Default
        }
        $match = $Choices | Where-Object { $_.ToLowerInvariant().StartsWith($value.ToLowerInvariant()) } | Select-Object -First 1
        if ($match) {
            return $match
        }
        Write-Host "Please choose one of: $($Choices -join ', ')" -ForegroundColor Yellow
    }
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

function Invoke-Wizard {
    Write-Host ""
    Write-Host "Browsium R2 Release Upload Wizard v$ScriptVersion" -ForegroundColor Cyan
    Write-Host "Default behavior is dry-run. Upload requires an explicit choice." -ForegroundColor DarkGray
    Write-Host ""

    if ([string]::IsNullOrWhiteSpace($script:SourceDir)) {
        $script:SourceDir = Read-Defaulted -Prompt "Source directory" -Default (Get-DefaultSourceDir)
    }
    if ([string]::IsNullOrWhiteSpace($script:RcloneRemote)) {
        $script:RcloneRemote = Read-Defaulted -Prompt "rclone remote name" -Default "browsium-r2"
    } else {
        $script:RcloneRemote = Read-Defaulted -Prompt "rclone remote name" -Default $script:RcloneRemote
    }
    if ([string]::IsNullOrWhiteSpace($script:Bucket)) {
        $script:Bucket = Read-Defaulted -Prompt "R2 bucket" -Default "browsium-releases"
    } else {
        $script:Bucket = Read-Defaulted -Prompt "R2 bucket" -Default $script:Bucket
    }

    $scope = Read-Choice -Prompt "What do you want to publish?" -Choices @("File", "Minor", "Major") -Default "Major"
    $script:ScopeMode = $scope

    switch ($scope) {
        "File" {
            $script:FileName = Read-Defaulted -Prompt "Exact file name or path" -Default $script:FileName
        }
        "Minor" {
            $script:MinorVersion = Read-Defaulted -Prompt "Minor version(s), for example 4.7, 4.8, 4.9. Use 4.X for all 4.x releases" -Default $(if ($script:MinorVersion) { $script:MinorVersion } else { "4.9" })
        }
        "Major" {
            $script:MajorVersion = Read-Defaulted -Prompt "Major version, for example 4 or 4.X" -Default $(if ($script:MajorVersion) { $script:MajorVersion } else { "4.X" })
        }
    }

    $includeSpecial = Confirm-Yes -Prompt "Include beta/eval/test/prerelease/debug/dump style files?" -DefaultNo $true
    if ($includeSpecial) {
        $confirmSpecial = Confirm-Yes -Prompt "Confirm this run is intentionally publishing non-standard/special builds" -DefaultNo $true
        if (-not $confirmSpecial) {
            throw "Special-build inclusion was requested but not confirmed."
        }
        $script:IncludeSpecialBuilds = $true
    }

    $mode = Read-Choice -Prompt "Run mode" -Choices @("DryRun", "Upload", "VerifyOnly") -Default "DryRun"
    $script:DryRun = $false
    $script:Upload = $false
    $script:VerifyOnly = $false
    switch ($mode) {
        "DryRun" { $script:DryRun = $true }
        "Upload" {
            $script:Upload = $true
            if (-not (Confirm-Yes -Prompt "Upload to $($script:RcloneRemote):$($script:Bucket) now?" -DefaultNo $true)) {
                throw "Upload was selected but not confirmed."
            }
        }
        "VerifyOnly" { $script:VerifyOnly = $true }
    }
}

function Assert-Tool {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' was not found on PATH."
    }
}

function Get-ReleaseCandidates {
    param(
        [Parameter(Mandatory)]
        [string]$Directory
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Source directory does not exist: $Directory"
    }

    $allFiles = Get-ChildItem -LiteralPath $Directory -File

    $selected = switch ($ScopeMode) {
        "File" {
            if ([string]::IsNullOrWhiteSpace($FileName)) {
                throw "FileName is required for File scope."
            }
            $candidatePath = if ([System.IO.Path]::IsPathRooted($FileName)) {
                $FileName
            } else {
                Join-Path $Directory $FileName
            }
            if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
                throw "Selected file does not exist: $candidatePath"
            }
            Get-Item -LiteralPath $candidatePath
        }
        "Minor" {
            $selectors = @(Convert-VersionSelectorList -Value $MinorVersion -RequestedScope "Minor")
            $majorSelectors = @($selectors | Where-Object { $_.Scope -eq "Major" } | Select-Object -ExpandProperty Value -Unique)
            $minorSelectors = @($selectors | Where-Object { $_.Scope -eq "Minor" } | Select-Object -ExpandProperty Value -Unique)

            if ($majorSelectors.Count -gt 0 -and $minorSelectors.Count -gt 0) {
                throw "Do not mix major selectors like 4.X with minor selectors like 4.9 in the same Minor selection."
            }

            if ($majorSelectors.Count -gt 0) {
                $allFiles | Where-Object {
                    $versionInfo = Get-ReleaseVersionInfo -File $_
                    $versionInfo -and $majorSelectors -contains $versionInfo.Major
                }
            } else {
                $allFiles | Where-Object {
                    $versionInfo = Get-ReleaseVersionInfo -File $_
                    $versionInfo -and $minorSelectors -contains $versionInfo.Minor
                }
            }
        }
        "Major" {
            $selector = Convert-VersionSelector -Value $MajorVersion -RequestedScope "Major"
            if ($selector.Scope -ne "Major") {
                throw "MajorVersion must look like '4' or '4.X'. Use Minor mode for '$($selector.Display)'."
            }
            $allFiles | Where-Object {
                $versionInfo = Get-ReleaseVersionInfo -File $_
                $versionInfo -and $versionInfo.Major -eq $selector.Value
            }
        }
        default {
            throw "Unsupported scope mode: $ScopeMode"
        }
    }

    $selected |
        Where-Object { $BinaryExtensions -contains $_.Extension.ToLowerInvariant() } |
        Where-Object { $_.Extension.ToLowerInvariant() -ne ".pdf" } |
        Where-Object { $IncludeSpecialBuilds -or $_.Name -notmatch $SpecialBuildPattern } |
        Sort-Object Name
}

function Get-RemoteObjectInfo {
    param(
        [Parameter(Mandatory)]
        [string]$Remote,
        [Parameter(Mandatory)]
        [string]$BucketName,
        [Parameter(Mandatory)]
        [string]$Key
    )

    $target = "$Remote`:$BucketName/$Key"
    $output = & rclone lsl $target 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $text = ($output | Out-String).Trim()
        if ($text -match '(?i)(not found|NoSuchKey|404)') {
            return [pscustomobject]@{
                Exists = $false
                Size = $null
                Error = $null
            }
        }
        return [pscustomobject]@{
            Exists = $false
            Size = $null
            Error = $text
        }
    }

    $line = ($output | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($line)) {
        return [pscustomobject]@{
            Exists = $false
            Size = $null
            Error = $null
        }
    }

    if ($line -match '^\s*(\d+)\s+') {
        return [pscustomobject]@{
            Exists = $true
            Size = [int64]$Matches[1]
            Error = $null
        }
    }

    return [pscustomobject]@{
        Exists = $false
        Size = $null
        Error = "Unable to parse rclone lsl output: $line"
    }
}

function New-ReportRow {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,
        [Parameter(Mandatory)]
        [object]$RemoteInfo
    )

    $status = if ($RemoteInfo.Error) {
        "RemoteCheckError"
    } elseif (-not $RemoteInfo.Exists) {
        "Missing"
    } elseif ([int64]$RemoteInfo.Size -eq [int64]$File.Length) {
        "PresentSameSize"
    } else {
        "SizeMismatch"
    }

    [pscustomobject]@{
        Version = $ScriptVersion
        Name = $File.Name
        LocalPath = $File.FullName
        LocalBytes = [int64]$File.Length
        LocalMB = [math]::Round($File.Length / 1MB, 2)
        Remote = "$RcloneRemote`:$Bucket/$($File.Name)"
        RemoteExists = [bool]$RemoteInfo.Exists
        RemoteBytes = $RemoteInfo.Size
        Status = $status
        Error = $RemoteInfo.Error
    }
}

if ($ScopeMode -eq "Wizard") {
    Invoke-Wizard
}

if (-not $Upload -and -not $VerifyOnly) {
    $DryRun = $true
}

Assert-Tool -Name "rclone"

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $SourceDir = Get-DefaultSourceDir
}

if ([string]::IsNullOrWhiteSpace($ReportDir)) {
    $ReportDir = Join-Path (Get-Location) ".reports/r2-sync"
}
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$candidates = @(Get-ReleaseCandidates -Directory $SourceDir)
if ($candidates.Count -eq 0) {
    throw "No files matched the selected scope and filters."
}

$inventoryPath = Join-Path $ReportDir "$timestamp-inventory.csv"
$planPath = Join-Path $ReportDir "$timestamp-plan.csv"
$logPath = Join-Path $ReportDir "$timestamp-upload.log"

$candidates |
    Select-Object @{Name = "Version"; Expression = { $ScriptVersion } }, Name, FullName, @{Name = "Bytes"; Expression = { $_.Length } }, @{Name = "MB"; Expression = { [math]::Round($_.Length / 1MB, 2) } } |
    Export-Csv -NoTypeInformation -Path $inventoryPath

Write-Host ""
Write-Host "Selected $($candidates.Count) file(s)." -ForegroundColor Cyan
Write-Host "Inventory: $inventoryPath"

$plan = foreach ($file in $candidates) {
    $remoteInfo = Get-RemoteObjectInfo -Remote $RcloneRemote -BucketName $Bucket -Key $file.Name
    New-ReportRow -File $file -RemoteInfo $remoteInfo
}

$plan | Export-Csv -NoTypeInformation -Path $planPath
Write-Host "Plan: $planPath"

$summary = $plan | Group-Object Status | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{ Status = $_.Name; Count = $_.Count }
}
$summary | Format-Table -AutoSize

$uploadRows = @($plan | Where-Object { $_.Status -in @("Missing", "SizeMismatch") })
$errorRows = @($plan | Where-Object { $_.Status -eq "RemoteCheckError" })

if ($errorRows.Count -gt 0) {
    Write-Host "Remote check errors were found. Fix rclone credentials/permissions before upload." -ForegroundColor Yellow
    $errorRows | Select-Object Name, Error | Format-Table -AutoSize
    if ($Upload) {
        throw "Upload blocked because remote object checks failed."
    }
}

if ($VerifyOnly) {
    Write-Host "Verify-only mode complete." -ForegroundColor Green
    exit 0
}

if ($DryRun -and -not $Upload) {
    Write-Host "Dry run complete. No files uploaded." -ForegroundColor Green
    if ($uploadRows.Count -gt 0) {
        Write-Host "Files that would upload: $($uploadRows.Count)" -ForegroundColor Cyan
        $uploadRows | Select-Object Name, LocalMB, Status | Format-Table -AutoSize
    }
    exit 0
}

if ($Upload) {
    if ($uploadRows.Count -eq 0) {
        Write-Host "Nothing to upload." -ForegroundColor Green
        exit 0
    }

    "Upload started at $(Get-Date -Format o)" | Out-File -FilePath $logPath -Encoding utf8
    foreach ($row in $uploadRows) {
        Write-Host "Uploading $($row.Name)..." -ForegroundColor Cyan
        "Uploading $($row.LocalPath) to $($row.Remote)" | Out-File -FilePath $logPath -Encoding utf8 -Append
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & rclone copyto $row.LocalPath $row.Remote `
                --size-only `
                --s3-no-check-bucket `
                --s3-chunk-size 64M `
                --s3-upload-concurrency 4 `
                --retries 10 `
                --low-level-retries 20 `
                --progress 2>&1 |
                Tee-Object -FilePath $logPath -Append
            $uploadExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($uploadExitCode -ne 0) {
            Write-Host "Upload failed for $($row.Name). See $logPath" -ForegroundColor Red
            throw "rclone upload failed for $($row.Name). See $logPath"
        }
    }
    "Upload finished at $(Get-Date -Format o)" | Out-File -FilePath $logPath -Encoding utf8 -Append
    Write-Host "Upload complete. Log: $logPath" -ForegroundColor Green
}

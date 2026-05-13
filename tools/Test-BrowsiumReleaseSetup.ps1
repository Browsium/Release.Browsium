<#
.SYNOPSIS
Validates local setup for publishing Browsium release binaries to Cloudflare R2.

.DESCRIPTION
Checks PowerShell, rclone, Wrangler login, R2 bucket visibility, rclone remote
configuration, source directory access, and optional public-domain reachability.
If the rclone remote is missing or points at another account endpoint, the
wizard can configure/update the local rclone remote.
#>

[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$RcloneRemote = "browsium-r2",
    [string]$Bucket = "browsium-releases",
    [string]$AccountId = "2b2861c0bba0855e5f6ed79a9451e6b2",
    [string]$PublicBaseUrl = "https://release.browsium.com",
    [switch]$NonInteractive,
    [switch]$Repair,
    [switch]$SkipWrangler,
    [switch]$SkipPublicUrlCheck,
    [string]$ReportDir
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

function ConvertFrom-SecureStringToPlainText {
    param([Parameter(Mandatory)][securestring]$SecureString)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Add-Check {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [ValidateSet("PASS", "FAIL", "WARN", "INFO")]
        [string]$Status,
        [string]$Detail = "",
        [bool]$Required = $true,
        [string]$Fix = ""
    )

    $script:Checks.Add([pscustomobject]@{
        Version = $ScriptVersion
        Name = $Name
        Status = $Status
        Required = $Required
        Detail = $Detail
        Fix = $Fix
    }) | Out-Null

    $color = switch ($Status) {
        "PASS" { "Green" }
        "FAIL" { "Red" }
        "WARN" { "Yellow" }
        default { "DarkGray" }
    }
    Write-Host ("[{0}] {1} {2}" -f $Status, $Name, $Detail) -ForegroundColor $color
    if (($Status -eq "FAIL" -or $Status -eq "WARN") -and -not [string]::IsNullOrWhiteSpace($Fix)) {
        Write-Host ("      Fix: {0}" -f $Fix) -ForegroundColor Yellow
    }
}

function Write-ValidationSummary {
    param(
        [object[]]$FailedRequired,
        [object[]]$Warnings
    )

    if ($null -eq $FailedRequired) {
        $FailedRequired = @()
    }
    if ($null -eq $Warnings) {
        $Warnings = @()
    }

    if ($FailedRequired.Count -gt 0) {
        Write-Host ""
        Write-Host "Required fixes before ReleaseTime can continue:" -ForegroundColor Red
        $index = 1
        foreach ($failure in $FailedRequired) {
            Write-Host ("{0}. {1}" -f $index, $failure.Name) -ForegroundColor Red
            if (-not [string]::IsNullOrWhiteSpace($failure.Detail)) {
                Write-Host ("   Problem: {0}" -f $failure.Detail)
            }
            if (-not [string]::IsNullOrWhiteSpace($failure.Fix)) {
                Write-Host ("   Fix: {0}" -f $failure.Fix) -ForegroundColor Yellow
            }
            $index++
        }
    }

    if ($Warnings.Count -gt 0) {
        Write-Host ""
        Write-Host "Warnings to review:" -ForegroundColor Yellow
        foreach ($warning in $Warnings) {
            Write-Host ("- {0}: {1}" -f $warning.Name, $warning.Detail) -ForegroundColor Yellow
            if (-not [string]::IsNullOrWhiteSpace($warning.Fix)) {
                Write-Host ("  Suggested action: {0}" -f $warning.Fix) -ForegroundColor Yellow
            }
        }
    }
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

    $output = @($stdout, $stderr) -join "`n"
    [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output.Trim()
    }
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

function Get-RcloneRemoteConfig {
    param([Parameter(Mandatory)][string]$RemoteName)

    $result = Invoke-CommandText -Command "rclone" -Arguments @("config", "redacted")
    if ($result.ExitCode -ne 0) {
        return $null
    }

    $lines = $result.Output -split "`r?`n"
    $inRemote = $false
    $values = @{}
    foreach ($line in $lines) {
        if ($line -match '^\[(.+)\]$') {
            $inRemote = ($Matches[1] -eq $RemoteName)
            continue
        }
        if ($inRemote -and $line -match '^([^=]+?)\s*=\s*(.*)$') {
            $values[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $values
}

function Test-RcloneObjectWrite {
    param(
        [Parameter(Mandatory)]
        [string]$RemoteName,
        [Parameter(Mandatory)]
        [string]$BucketName
    )

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "browsium-r2-setup-probe-$stamp.txt"
    $objectName = ".release-setup-probe-$stamp.txt"
    $remotePath = "$RemoteName`:$BucketName/$objectName"

    [System.IO.File]::WriteAllText($tempPath, "Browsium ReleaseSetup probe $stamp`r`n")
    try {
        $copyResult = Invoke-CommandText -Command "rclone" -Arguments @(
            "copyto", $tempPath, $remotePath,
            "--s3-no-check-bucket",
            "--retries", "1",
            "--low-level-retries", "1"
        )
        if ($copyResult.ExitCode -ne 0) {
            return [pscustomobject]@{
                Success = $false
                Detail = $copyResult.Output
            }
        }

        $deleteResult = Invoke-CommandText -Command "rclone" -Arguments @(
            "deletefile", $remotePath,
            "--s3-no-check-bucket"
        )
        if ($deleteResult.ExitCode -ne 0) {
            return [pscustomobject]@{
                Success = $false
                Detail = "Probe uploaded but cleanup failed: $($deleteResult.Output)"
            }
        }

        return [pscustomobject]@{
            Success = $true
            Detail = "Created and deleted $objectName"
        }
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function Configure-RcloneRemote {
    param(
        [Parameter(Mandatory)]
        [string]$RemoteName,
        [Parameter(Mandatory)]
        [string]$Endpoint,
        [ValidateSet("create", "update")]
        [string]$Action = "create"
    )

    Write-Host ""
    Write-Host "Configure local rclone remote '$RemoteName'" -ForegroundColor Cyan
    Write-Host "This creates or updates a local rclone profile only. It does not create a new R2 bucket." -ForegroundColor DarkGray
    Write-Host ""
    $tokenUrl = "https://dash.cloudflare.com/$AccountId/r2/api-tokens"
    Write-R2TokenInstructions -TokenUrl $tokenUrl -Endpoint $Endpoint

    if (Confirm-Yes -Prompt "Open the Cloudflare R2 API token page now?" -DefaultNo $false) {
        Start-Process $tokenUrl
        Write-Host ""
        Write-Host "The browser is open. Complete the numbered dashboard steps above, then return here." -ForegroundColor Yellow
    } else {
        Write-Host "Open this page manually: $tokenUrl" -ForegroundColor Yellow
    }

    if (-not (Confirm-Yes -Prompt "Do you have the Access Key ID and Secret Access Key ready?" -DefaultNo $true)) {
        Write-Host "Skipping rclone configuration until credentials are available." -ForegroundColor Yellow
        return $false
    }

    $accessKey = Read-Host "R2 Access Key ID"
    $secretSecure = Read-Host "R2 Secret Access Key" -AsSecureString
    $secretKey = ConvertFrom-SecureStringToPlainText -SecureString $secretSecure

    try {
        if ($Action -eq "create") {
            $rcloneArgs = @(
                "config", "create", $RemoteName, "s3",
                "provider", "Cloudflare",
                "access_key_id", $accessKey,
                "secret_access_key", $secretKey,
                "endpoint", $Endpoint
            )
        } else {
            $rcloneArgs = @(
                "config", "update", $RemoteName,
                "provider", "Cloudflare",
                "access_key_id", $accessKey,
                "secret_access_key", $secretKey,
                "endpoint", $Endpoint
            )
        }

        $result = Invoke-CommandText -Command "rclone" -Arguments $rcloneArgs
        if ($result.ExitCode -ne 0) {
            Write-Host $result.Output -ForegroundColor Red
            Write-Host "rclone config $Action failed." -ForegroundColor Red
            return $false
        }
        Write-Host "rclone remote '$RemoteName' configured." -ForegroundColor Green
        return $true
    } finally {
        $secretKey = $null
    }
}

function Write-R2TokenInstructions {
    param(
        [Parameter(Mandatory)]
        [string]$TokenUrl,
        [Parameter(Mandatory)]
        [string]$Endpoint
    )

    Write-Host "Manual Cloudflare step required: create R2 S3 credentials" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Why this is manual:" -ForegroundColor Yellow
    Write-Host "Cloudflare shows the R2 Secret Access Key only once. ReleaseSetup can configure rclone after you paste it, but an admin must create/copy the token in the dashboard."
    Write-Host ""
    Write-Host "Use these exact settings:" -ForegroundColor Cyan
    Write-Host "Account ID: $AccountId"
    Write-Host "R2 bucket:  $Bucket"
    Write-Host "Endpoint:   $Endpoint"
    Write-Host "Permission: Object Read & Write"
    Write-Host "Scope:      bucket '$Bucket' only"
    Write-Host ""
    Write-Host "Dashboard steps:" -ForegroundColor Cyan
    Write-Host "1. Sign in to Cloudflare as an admin for the Browsium account."
    Write-Host "2. Open R2 object storage."
    Write-Host "3. Find Account Details on the R2 overview page."
    Write-Host "4. Next to API Tokens, choose Manage."
    Write-Host "5. Choose Create Account API token if available. If not, choose Create User API token."
    Write-Host "6. Set Permissions to Object Read & Write."
    Write-Host "7. Scope the token to bucket '$Bucket'. Do not choose all buckets unless you intentionally want broader access."
    Write-Host "8. Create the token."
    Write-Host "9. Copy both values immediately:"
    Write-Host "   - Access Key ID, sometimes shown as Client ID"
    Write-Host "   - Secret Access Key, sometimes shown as Client Secret"
    Write-Host "10. Return to this PowerShell window and paste the values when prompted."
    Write-Host ""
    Write-Host "Token page:" -ForegroundColor Cyan
    Write-Host $TokenUrl
    Write-Host ""

    $copyText = @"
Browsium R2 setup values
Account ID: $AccountId
Bucket: $Bucket
Endpoint: $Endpoint
Permission: Object Read & Write
Scope: bucket '$Bucket' only
"@
    if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
        if (Confirm-Yes -Prompt "Copy these setup values to the clipboard?" -DefaultNo $false) {
            $copyText | Set-Clipboard
            Write-Host "Copied setup values to clipboard." -ForegroundColor Green
        }
    }
}

function Invoke-RepairWorkflow {
    param(
        [Parameter(Mandatory)]
        [object[]]$FailedRequired,
        [Parameter(Mandatory)]
        [string]$Endpoint
    )

    $didRepair = $false

    foreach ($failure in $FailedRequired) {
        switch ($failure.Name) {
            "rclone installed" {
                Write-Host ""
                Write-Host "Repair option: install rclone" -ForegroundColor Cyan
                if (Get-Command winget -ErrorAction SilentlyContinue) {
                    if (Confirm-Yes -Prompt "Install rclone using winget now?" -DefaultNo $true) {
                        winget install --id Rclone.Rclone --exact --source winget
                        $didRepair = $true
                    }
                } else {
                    Write-Host "winget was not found. Opening rclone install instructions." -ForegroundColor Yellow
                    Start-Process "https://rclone.org/install/"
                }
            }
            "Wrangler/npx available" {
                Write-Host ""
                Write-Host "Repair option: install Node.js/npm" -ForegroundColor Cyan
                if (Get-Command winget -ErrorAction SilentlyContinue) {
                    if (Confirm-Yes -Prompt "Install Node.js LTS using winget now?" -DefaultNo $true) {
                        winget install --id OpenJS.NodeJS.LTS --exact --source winget
                        $didRepair = $true
                    }
                } else {
                    Start-Process "https://nodejs.org/"
                }
            }
            "Wrangler login" {
                Write-Host ""
                Write-Host "Repair option: Wrangler login" -ForegroundColor Cyan
                if (Confirm-Yes -Prompt "Run npx wrangler login now?" -DefaultNo $false) {
                    & npx wrangler login
                    $didRepair = $true
                }
            }
            "rclone remote config" {
                if (Confirm-Yes -Prompt "Set up rclone remote '$RcloneRemote' now?" -DefaultNo $false) {
                    if (Configure-RcloneRemote -RemoteName $RcloneRemote -Endpoint $Endpoint -Action "create") {
                        $didRepair = $true
                    }
                }
            }
            "rclone remote endpoint" {
                if (Confirm-Yes -Prompt "Update rclone remote '$RcloneRemote' now?" -DefaultNo $false) {
                    if (Configure-RcloneRemote -RemoteName $RcloneRemote -Endpoint $Endpoint -Action "update") {
                        $didRepair = $true
                    }
                }
            }
            "rclone bucket list" {
                Write-Host ""
                Write-Host "Repair guidance: rclone can find the remote, but R2 rejected bucket listing." -ForegroundColor Yellow
                Write-Host "Create a new R2 S3 token scoped to '$Bucket' with Object Read & Write, then update '$RcloneRemote'." -ForegroundColor Yellow
                if (Confirm-Yes -Prompt "Update rclone remote '$RcloneRemote' with a new R2 token now?" -DefaultNo $false) {
                    if (Configure-RcloneRemote -RemoteName $RcloneRemote -Endpoint $Endpoint -Action "update") {
                        $didRepair = $true
                    }
                }
            }
            "rclone object write" {
                Write-Host ""
                Write-Host "Repair guidance: rclone can list the bucket, but R2 rejected object write/delete." -ForegroundColor Yellow
                Write-Host "Create a new R2 S3 token scoped to '$Bucket' with Object Read & Write, then update '$RcloneRemote'." -ForegroundColor Yellow
                if (Confirm-Yes -Prompt "Update rclone remote '$RcloneRemote' with a new R2 token now?" -DefaultNo $false) {
                    if (Configure-RcloneRemote -RemoteName $RcloneRemote -Endpoint $Endpoint -Action "update") {
                        $didRepair = $true
                    }
                }
            }
        }
    }

    return $didRepair
}

if (-not $NonInteractive) {
    Write-Host ""
    Write-Host "Browsium Release Setup Validation v$ScriptVersion" -ForegroundColor Cyan
    Write-Host "This validates local tools, Cloudflare access, rclone access, and the source directory." -ForegroundColor DarkGray
    Write-Host ""

    $defaultSourceDir = if ($SourceDir) { $SourceDir } else { Get-DefaultSourceDir }
    $SourceDir = Read-Defaulted -Prompt "Source directory" -Default $defaultSourceDir
    $RcloneRemote = Read-Defaulted -Prompt "rclone remote name" -Default $RcloneRemote
    $Bucket = Read-Defaulted -Prompt "R2 bucket" -Default $Bucket
    $AccountId = Read-Defaulted -Prompt "Cloudflare account ID" -Default $AccountId
    $PublicBaseUrl = Read-Defaulted -Prompt "Public release base URL" -Default $PublicBaseUrl
} else {
    Write-Host "Browsium Release Setup Validation v$ScriptVersion" -ForegroundColor Cyan
}

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $SourceDir = Get-DefaultSourceDir
}

if ([string]::IsNullOrWhiteSpace($ReportDir)) {
    $scriptDir = Split-Path -Parent (Get-ScriptPath)
    $repoRoot = Split-Path -Parent $scriptDir
    $ReportDir = Join-Path $repoRoot ".reports/r2-setup"
}
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

$script:Checks = [System.Collections.Generic.List[object]]::new()
$endpoint = "https://$AccountId.r2.cloudflarestorage.com"

Add-Check -Name "PowerShell version" -Status $(if ($PSVersionTable.PSVersion.Major -ge 5) { "PASS" } else { "FAIL" }) -Detail $PSVersionTable.PSVersion.ToString()

if (Test-Path -LiteralPath $SourceDir -PathType Container) {
    $fileCount = @(Get-ChildItem -LiteralPath $SourceDir -File).Count
    Add-Check -Name "Source directory" -Status "PASS" -Detail "$SourceDir ($fileCount files)"
} else {
    Add-Check -Name "Source directory" -Status "FAIL" -Detail "Missing: $SourceDir" -Fix "Run ReleaseTime from the repo or pass -SourceDir with the folder containing release ZIP/EXE files."
}

if (Get-Command rclone -ErrorAction SilentlyContinue) {
    $version = Invoke-CommandText -Command "rclone" -Arguments @("version")
    $firstLine = ($version.Output -split "`r?`n" | Select-Object -First 1)
    Add-Check -Name "rclone installed" -Status "PASS" -Detail $firstLine
} else {
    Add-Check -Name "rclone installed" -Status "FAIL" -Detail "Install rclone before publishing." -Fix "Install rclone, then open a new PowerShell window and rerun tools\ReleaseTime.ps1."
}

if (-not $SkipWrangler) {
    if (Get-Command npx -ErrorAction SilentlyContinue) {
        $whoami = Invoke-CommandText -Command "npx" -Arguments @("wrangler", "whoami")
        if ($whoami.ExitCode -eq 0 -and $whoami.Output -match [regex]::Escape($AccountId)) {
            Add-Check -Name "Wrangler login" -Status "PASS" -Detail "Logged into account $AccountId"
        } elseif ($whoami.ExitCode -eq 0) {
            Add-Check -Name "Wrangler login" -Status "WARN" -Detail "Wrangler is logged in, but output did not show expected account $AccountId" -Required $false -Fix "Run npx wrangler whoami and confirm the account is the Browsium account before uploading."
        } else {
            Add-Check -Name "Wrangler login" -Status "FAIL" -Detail "Run: npx wrangler login" -Fix "Run npx wrangler login, authenticate as admin@browsium.com, then rerun tools\ReleaseTime.ps1."
        }

        $bucketInfo = Invoke-CommandText -Command "npx" -Arguments @("wrangler", "r2", "bucket", "info", $Bucket)
        if ($bucketInfo.ExitCode -eq 0) {
            $summary = (($bucketInfo.Output -split "`r?`n") | Where-Object { $_ -match 'object_count|bucket_size|name:' }) -join "; "
            Add-Check -Name "Wrangler bucket access" -Status "PASS" -Detail $summary
        } else {
            Add-Check -Name "Wrangler bucket access" -Status "FAIL" -Detail $bucketInfo.Output -Fix "Confirm the bucket name is '$Bucket' and Wrangler is logged into account $AccountId."
        }
    } else {
        Add-Check -Name "Wrangler/npx available" -Status "FAIL" -Detail "npx was not found." -Fix "Install Node.js/npm so npx wrangler is available, or pass -SkipWrangler only for offline troubleshooting."
    }
} else {
    Add-Check -Name "Wrangler checks" -Status "INFO" -Detail "Skipped" -Required $false
}

if (Get-Command rclone -ErrorAction SilentlyContinue) {
    $skipRcloneList = $false
    $remoteConfig = Get-RcloneRemoteConfig -RemoteName $RcloneRemote
    if ($null -eq $remoteConfig -or $remoteConfig.Count -eq 0) {
        $fix = "Create the local rclone profile with: rclone config create $RcloneRemote s3 provider Cloudflare access_key_id <ACCESS_KEY_ID> secret_access_key <SECRET_ACCESS_KEY> endpoint $endpoint"
        Add-Check -Name "rclone remote config" -Status "FAIL" -Detail "Remote '$RcloneRemote' was not found." -Fix $fix
        $skipRcloneList = $true
    } else {
        $configuredEndpoint = if ($remoteConfig.ContainsKey("endpoint")) { $remoteConfig["endpoint"] } else { "" }
        if ($configuredEndpoint -eq $endpoint) {
            Add-Check -Name "rclone remote endpoint" -Status "PASS" -Detail "$RcloneRemote -> $configuredEndpoint"
        } else {
            $fix = "Update or recreate '$RcloneRemote' so its endpoint is $endpoint. The existing remote likely points at another Cloudflare account."
            Add-Check -Name "rclone remote endpoint" -Status "FAIL" -Detail "$RcloneRemote endpoint is '$configuredEndpoint', expected '$endpoint'" -Fix $fix
            $skipRcloneList = $true
        }
    }

    if (-not $skipRcloneList) {
        $listResult = Invoke-CommandText -Command "rclone" -Arguments @("lsf", "$RcloneRemote`:$Bucket", "--files-only", "--max-depth", "1")
        if ($listResult.ExitCode -eq 0) {
            $listedCount = @(($listResult.Output -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
            Add-Check -Name "rclone bucket list" -Status "PASS" -Detail "$listedCount objects listed at depth 1"

            $writeProbe = Test-RcloneObjectWrite -RemoteName $RcloneRemote -BucketName $Bucket
            if ($writeProbe.Success) {
                Add-Check -Name "rclone object write" -Status "PASS" -Detail $writeProbe.Detail
            } else {
                Add-Check -Name "rclone object write" -Status "FAIL" -Detail $writeProbe.Detail -Fix "Create/update the R2 S3 token with Object Read & Write for '$Bucket', then rerun ReleaseTime."
            }
        } else {
            Add-Check -Name "rclone bucket list" -Status "FAIL" -Detail $listResult.Output -Fix "Confirm the R2 S3 token has Object Read & Write/List access to '$Bucket'."
        }
    }
}

if (-not $SkipPublicUrlCheck -and -not [string]::IsNullOrWhiteSpace($PublicBaseUrl)) {
    try {
        $testUrl = $PublicBaseUrl.TrimEnd("/") + "/"
        $response = Invoke-WebRequest -Uri $testUrl -Method Head -TimeoutSec 20 -MaximumRedirection 0 -ErrorAction Stop
        Add-Check -Name "Public base URL" -Status "PASS" -Detail "$testUrl returned $([int]$response.StatusCode)" -Required $false
    } catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "No response" }
        Add-Check -Name "Public base URL" -Status "WARN" -Detail "$PublicBaseUrl returned $status for HEAD /" -Required $false -Fix "This is not blocking. The root path may 404 even when individual release files work."
    }
}

$failedRequired = @($script:Checks | Where-Object { $_.Required -and $_.Status -eq "FAIL" })
$warnings = @($script:Checks | Where-Object { $_.Status -eq "WARN" })
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$reportPath = Join-Path $ReportDir "$timestamp-setup-validation.csv"
$script:Checks | Export-Csv -NoTypeInformation -Path $reportPath

Write-Host ""
Write-Host "Validation report: $reportPath"

if ($failedRequired.Count -gt 0) {
    Write-ValidationSummary -FailedRequired $failedRequired -Warnings $warnings

    if ($Repair) {
        Write-Host ""
        Write-Host "ReleaseSetup can attempt supported repairs now." -ForegroundColor Cyan
        $didRepair = Invoke-RepairWorkflow -FailedRequired $failedRequired -Endpoint $endpoint
        if ($didRepair) {
            Write-Host ""
            Write-Host "Repair attempted. Re-running setup validation..." -ForegroundColor Cyan
            $self = Get-ScriptPath
            $rerunArgs = @{
                SourceDir = $SourceDir
                RcloneRemote = $RcloneRemote
                Bucket = $Bucket
                AccountId = $AccountId
                PublicBaseUrl = $PublicBaseUrl
                ReportDir = $ReportDir
                NonInteractive = $true
            }
            if ($SkipWrangler) {
                $rerunArgs.SkipWrangler = $true
            }
            if ($SkipPublicUrlCheck) {
                $rerunArgs.SkipPublicUrlCheck = $true
            }
            & $self @rerunArgs
            exit $LASTEXITCODE
        }
    }

    Write-Host ""
    Write-Host "Setup validation failed. Release upload should not run yet." -ForegroundColor Red
    exit 1
}

Write-ValidationSummary -FailedRequired @() -Warnings $warnings
Write-Host "Setup validation passed." -ForegroundColor Green
exit 0

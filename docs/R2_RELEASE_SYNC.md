# Browsium R2 Release Sync

Admins should normally start with `tools\ReleaseTime.ps1` from the repository root:

```powershell
.\tools\ReleaseTime.ps1
```

`ReleaseTime.ps1` first runs setup validation, then launches the release upload wizard only if validation passes.

The release flow publishes Browsium release binaries from a local folder to the existing Cloudflare R2 bucket:

```text
browsium-releases
```

The utility uses `rclone` because Cloudflare dashboard uploads reject files around 300 MB, and Wrangler is also not suitable for large bulk uploads. `rclone` uses the S3-compatible R2 API and handles multipart upload.

## Script Layout

```text
tools/ReleaseTime.ps1                   # Admin entrypoint
tools/Test-BrowsiumReleaseSetup.ps1     # Setup and readiness validator
tools/Sync-BrowsiumReleaseR2.ps1        # Release upload wizard
```

Current script version: `0.1.2`.

Each script prints its version at startup, and generated CSV reports include the script version.

## One-Time Setup

Create an R2 S3 token in Cloudflare:

1. Go to Cloudflare Dashboard > R2 > Manage API Tokens.
2. Create a token with Object Read & Write access.
3. Scope it to `browsium-releases`.
4. Copy the Access Key ID and Secret Access Key.

Configure a local rclone remote. This creates a local connection profile only; it does not create a new bucket.

```powershell
rclone config create browsium-r2 s3 provider Cloudflare `
  access_key_id "<ACCESS_KEY_ID>" `
  secret_access_key "<SECRET_ACCESS_KEY>" `
  endpoint "https://2b2861c0bba0855e5f6ed79a9451e6b2.r2.cloudflarestorage.com"
```

Verify access:

```powershell
rclone lsf browsium-r2:browsium-releases --files-only
```

You can also let `tools/Test-BrowsiumReleaseSetup.ps1` walk through this. If the local rclone remote is missing or points at the wrong Cloudflare account endpoint, it prints step-by-step dashboard instructions, opens the Cloudflare R2 API token page, and configures/updates the remote after you provide the R2 S3 Access Key ID and Secret Access Key.

The R2 S3 Secret Access Key is only shown once in Cloudflare. The setup tool cannot safely retrieve it later. An admin must create the token in the dashboard, copy both values, and paste them into the setup prompt.

## Admin Release Flow

Run:

```powershell
.\tools\ReleaseTime.ps1
```

The first stage validates:

- PowerShell version
- source directory exists
- `rclone` is installed
- Wrangler login can see the expected Cloudflare account
- the `browsium-releases` bucket is visible to Wrangler
- local rclone remote points at the expected R2 account endpoint
- rclone can list the bucket
- rclone can create and delete a small probe object
- public release URL responds

If any required check fails, `ReleaseTime.ps1` stops before upload. If validation passes, it launches the release upload wizard.

For supported setup blockers, `ReleaseTime.ps1` offers to repair the issue immediately and then re-runs validation. Supported repairs include:

- installing `rclone` with `winget`
- installing Node.js LTS with `winget` when `npx` is missing
- running `npx wrangler login`
- opening the Cloudflare R2 API token page
- creating or updating the local `browsium-r2` rclone remote after the admin pastes the R2 S3 Access Key ID and Secret Access Key

The rclone repair only configures a local connection profile. It does not create a new bucket.

At the end of the release wizard, `ReleaseTime.ps1` asks whether to cleanup and reset local rclone settings. The default is yes. This deletes the local `browsium-r2` rclone profile and its stored R2 S3 credentials from the machine. It does not delete the bucket, remove uploaded files, revoke the Cloudflare API token, or log out Wrangler.

For a dedicated release machine, an admin can keep the local rclone profile by answering no or by running:

```powershell
.\tools\ReleaseTime.ps1 -KeepRcloneRemote
```

For automated cleanup without the final prompt, run:

```powershell
.\tools\ReleaseTime.ps1 -CleanupRcloneRemote
```

If you need a full credential reset, also revoke the R2 API token in the Cloudflare dashboard.

## Upload Wizard

The upload wizard can also be run directly:

```powershell
.\tools\Sync-BrowsiumReleaseR2.ps1
```

The wizard asks for:

1. Source directory.
2. rclone remote name.
3. R2 bucket name.
4. Publish scope:
   - exact file
   - minor version, for example `4.9` or multiple values like `4.7, 4.8, 4.9`
   - major version, for example `4`, `4.X`, or `5.X`
5. Whether to include special builds.
6. Run mode:
   - dry run, the default
   - upload
   - verify only

Special builds include filenames containing:

```text
prerelease, pre-release, beta, alpha, eval, evaluation, test, sso, debug, dump, bxsdk, msedge
```

The script excludes those by default. If you intentionally need to publish beta, eval, test, or similar files, the wizard asks for a second confirmation before including them.

## Non-Interactive Examples

Dry-run all official 4.x binaries:

```powershell
.\tools\Sync-BrowsiumReleaseR2.ps1 `
  -SourceDir "C:\Users\Matt\Documents\Projects\Release.Browsium\release" `
  -RcloneRemote "browsium-r2" `
  -Bucket "browsium-releases" `
  -ScopeMode Major `
  -MajorVersion 4.X
```

Upload missing or size-mismatched official 4.9 binaries:

```powershell
.\tools\Sync-BrowsiumReleaseR2.ps1 `
  -SourceDir "C:\Users\Matt\Documents\Projects\Release.Browsium\release" `
  -RcloneRemote "browsium-r2" `
  -Bucket "browsium-releases" `
  -ScopeMode Minor `
  -MinorVersion 4.9 `
  -Upload
```

Dry-run several official minor lines:

```powershell
.\tools\Sync-BrowsiumReleaseR2.ps1 `
  -SourceDir "C:\Users\Matt\Documents\Projects\Release.Browsium\release" `
  -RcloneRemote "browsium-r2" `
  -Bucket "browsium-releases" `
  -ScopeMode Minor `
  -MinorVersion "4.7, 4.8, 4.9"
```

Upload a specific beta or eval build:

```powershell
.\tools\Sync-BrowsiumReleaseR2.ps1 `
  -SourceDir "C:\Users\Matt\Documents\Projects\Release.Browsium\release" `
  -RcloneRemote "browsium-r2" `
  -Bucket "browsium-releases" `
  -ScopeMode File `
  -FileName "Example-Beta-4.10.0.zip" `
  -IncludeSpecialBuilds `
  -Upload
```

## Reports

Each run writes reports under:

```text
.reports/r2-sync/
```

Reports include:

- selected local inventory
- upload/verification plan
- upload log when upload mode is used

The script compares by object name and size. Files already present with the same size are skipped.

## Troubleshooting

If upload fails with `CreateBucket` and `AccessDenied`, use script version `0.1.1` or newer. The upload command must pass `--s3-no-check-bucket` because the R2 token is intentionally scoped to object access for the existing `browsium-releases` bucket.

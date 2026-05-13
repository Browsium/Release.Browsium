# release.browsium.com Cloudflare Operations Guide

This document explains how `release.browsium.com` is organized now that release downloads have moved to Cloudflare. It is written for engineering and release admins who need to understand where the files live, how publishing works, and which PowerShell tools to use when adding new releases.

## Current Architecture

`release.browsium.com` is a direct Cloudflare R2-backed download service for Browsium release binaries.

```text
Customer or admin download
        |
        v
release.browsium.com
        |
        v
Cloudflare custom domain on R2
        |
        v
R2 bucket: browsium-releases
        |
        v
ZIP and EXE release objects
```

There is no application server in the request path. Files are served directly from Cloudflare's edge using the public custom domain mapped to the R2 bucket.

## Cloudflare Resources

| Resource | Value | Purpose |
| --- | --- | --- |
| Production URL | `https://release.browsium.com` | Public release download host |
| R2 bucket | `browsium-releases` | Stores release ZIP and EXE files |
| Cloudflare account ID | `2b2861c0bba0855e5f6ed79a9451e6b2` | Expected account for Wrangler and R2 S3 credentials |
| R2 S3 endpoint | `https://2b2861c0bba0855e5f6ed79a9451e6b2.r2.cloudflarestorage.com` | Used by `rclone` for uploads |
| GitHub repo | `Browsium/Release.Browsium` | Tracks scripts, docs, and local release inventory structure |

The R2 bucket is the source of truth for files that are live on the public domain. Uploading an object to `browsium-releases` makes that object available immediately at:

```text
https://release.browsium.com/<file-name>
```

## Repository Layout

```text
Release.Browsium/
  docs/
    CLOUDFLARE_RELEASE_OPERATIONS.md   # This guide
    R2_RELEASE_SYNC.md                  # Detailed sync tool reference
    ADMIN_GUIDE.md                      # Earlier admin overview
    SESSION_SUMMARY.md                  # Migration summary
  release/
    .gitkeep                            # Keeps the folder in Git
    *.zip, *.exe, *.pdf                 # Local release files, ignored by Git
  staging/
    *.zip                               # Optional local staging set, ignored by Git
  tools/
    ReleaseTime.ps1                     # Recommended admin entrypoint
    Test-BrowsiumReleaseSetup.ps1       # Local setup and Cloudflare access validator
    Sync-BrowsiumReleaseR2.ps1          # R2 upload, dry-run, and verify wizard
  .reports/
    r2-setup/                           # Setup validation CSV output, ignored by Git
    r2-sync/                            # Inventory, plan, and upload logs, ignored by Git
```

Large binaries are intentionally ignored by Git. The repository keeps the scripts and folder structure; R2 stores the live release artifacts.

## Publishing Model

Use PowerShell from the repository root:

```powershell
cd C:\Users\Matt\Documents\Projects\Release.Browsium
.\tools\ReleaseTime.ps1
```

`ReleaseTime.ps1` is the normal release-admin entrypoint. It runs setup validation first, then starts the upload wizard only when the environment passes required checks.

The setup stage validates:

- PowerShell version.
- Source folder exists.
- `rclone` is installed.
- `npx wrangler` can see the expected Cloudflare account.
- The `browsium-releases` bucket is visible.
- The local `rclone` remote points at the expected R2 endpoint.
- `rclone` can list the bucket.
- `rclone` can write and delete a small probe object.
- The public base URL responds, when that check is enabled.

The upload stage can publish by:

- Exact file name.
- Minor version, such as `4.9`.
- Multiple minor versions, such as `4.7, 4.8, 4.9`.
- Major version, such as `4` or `4.X`.

Dry run is the default. Upload requires an explicit selection and confirmation.

## One-Time Admin Setup

Each admin machine needs local tools and credentials before it can publish.

Required local tools:

- PowerShell 5 or newer.
- Node.js/npm so `npx wrangler` is available.
- Cloudflare Wrangler login for the Browsium account.
- `rclone`.
- A local `rclone` remote named `browsium-r2`.

The easiest setup path is:

```powershell
cd C:\Users\Matt\Documents\Projects\Release.Browsium
.\tools\ReleaseTime.ps1
```

If setup is incomplete, `ReleaseTime.ps1` calls `Test-BrowsiumReleaseSetup.ps1` with repair mode enabled. It can guide the admin through installing missing tools, running Wrangler login, opening the Cloudflare R2 API token page, and creating or updating the local `rclone` remote.

If configuring manually, create an R2 S3 token in Cloudflare with:

- Permission: Object Read & Write.
- Scope: bucket `browsium-releases` only.
- Account: `2b2861c0bba0855e5f6ed79a9451e6b2`.

Then configure `rclone`:

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

Cloudflare shows the R2 Secret Access Key only once. If it is lost, create a new token and update the local `rclone` remote.

## Normal Release Procedure

1. Copy new release artifacts into `release/`.
2. Open PowerShell in the repo root.
3. Run:

```powershell
.\tools\ReleaseTime.ps1
```

4. Confirm setup validation passes.
5. In the wizard, choose the publish scope.
6. Run a dry run first and review the plan.
7. Re-run or continue in upload mode when the selected files are correct.
8. Check the generated CSV plan and upload log under `.reports/r2-sync/`.
9. Verify one or more public URLs with `curl.exe -I`.

Example verification:

```powershell
curl.exe -I https://release.browsium.com/Browsium-Ion-4.9.7.zip
```

Expected signals:

- HTTP status is `200`.
- `Content-Length` matches the local file size.
- Large files advertise range support, typically through `Accept-Ranges`.

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

Upload one specific special build:

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

Special builds are excluded by default when their filenames include terms such as `prerelease`, `beta`, `eval`, `test`, `sso`, `debug`, `dump`, `bxsdk`, or `msedge`.

## Credential Cleanup

By default, `ReleaseTime.ps1` asks whether to clean up the local `rclone` remote at the end of the run. Cleanup removes the local `browsium-r2` profile and its stored R2 S3 credentials from that machine.

Cleanup does not:

- Delete the R2 bucket.
- Remove uploaded files.
- Revoke the Cloudflare API token.
- Log out Wrangler.

For a dedicated release machine, keep the local `rclone` profile:

```powershell
.\tools\ReleaseTime.ps1 -KeepRcloneRemote
```

For automatic cleanup without the final prompt:

```powershell
.\tools\ReleaseTime.ps1 -CleanupRcloneRemote
```

To fully retire credentials, revoke the R2 API token in the Cloudflare dashboard.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Setup stops before upload | Review `.reports/r2-setup/` and rerun `.\tools\ReleaseTime.ps1` after applying the suggested fix. |
| `rclone` remote missing | Let `ReleaseTime.ps1` repair it, or create `browsium-r2` manually with the R2 S3 endpoint. |
| Bucket list fails | Confirm the token has Object Read & Write access scoped to `browsium-releases`. |
| Upload fails with `CreateBucket` or `AccessDenied` | Use script version `0.1.1` or newer. The uploader passes `--s3-no-check-bucket` for scoped R2 tokens. |
| Public URL returns 404 | Confirm the object name exactly matches the URL path. R2 object names and URLs are case-sensitive. |
| File appears partially uploaded | Re-run the upload. The sync plan compares object name and size and uploads missing or size-mismatched files. |

## Related Documents

- `docs/R2_RELEASE_SYNC.md` for detailed script behavior and examples.
- `docs/SESSION_SUMMARY.md` for the migration summary.
- `docs/ADMIN_GUIDE.md` for the earlier admin overview.

# Finishing the R2 Population and Testing

This document outlines the steps to complete the migration of `release.browsium.com` from Azure to Cloudflare.

## Current Setup
*   **Storage**: Cloudflare R2 bucket `browsium-releases`.
*   **Front-end**: Cloudflare Pages `release-browsium`.
*   **Domain**: `new-release.browsium.com` (Target).

## 1. Populate R2 Storage
To upload the remaining ~32GB of data, use the Cloudflare Wrangler CLI.

### Prerequisites
Ensure you have `wrangler` installed and authenticated.

### Sync Command
Run this command from the root of this project:
```bash
npx wrangler r2 object sync ./release browsium-releases
```

*Note: The sync command is efficient; it will only upload files that are missing or changed.*

## 2. Verify MIME Types
Cloudflare R2 automatically detects standard MIME types, but for specific binaries, you can force them during upload if needed:
```bash
npx wrangler r2 object put browsium-releases/BCMS-Setup.exe --file ./release/BCMS-Setup.exe --content-type application/octet-stream
```

## 3. Configuration & Domain Mapping
1.  **Map Domain to R2**:
    *   In the Cloudflare Dashboard, go to **R2** -> **Buckets** -> `browsium-releases`.
    *   Go to **Settings** -> **Public Bucket** -> **Custom Domains**.
    *   Add `new-release.browsium.com`.
2.  **Verify Access**:
    *   Test a large file download: `https://new-release.browsium.com/BCMS-Setup.exe`.
    *   Check for 200 OK status and correct file size.

## 4. Final Cutover
Once testing is verified on `new-release.browsium.com`:
1.  Go to the R2 bucket settings.
2.  Add the final production domain `release.browsium.com`.
3.  Update your DNS to point `release.browsium.com` to the R2 bucket.

## Version 4.X Files Only (Refined Sync)

If you only want to migrate the official 4.X release ZIP files (excluding PDFs, prereleases, and old 3.X versions), use this specialized sync approach.

### 1. Preparation (Local Cleanup)
To ensure only the required files are uploaded, it is easiest to copy them to a clean folder before syncing:

```powershell
# Create a staging folder
mkdir staging

# Copy only the 4.x ZIP files (excluding prereleases and Ion 3.4.x)
Get-ChildItem -Path ./release -File | Where-Object { 
    $_.Name -like "*4.*" -and 
    $_.Name -like "*.zip" -and 
    $_.Name -notlike "*prerelease*" -and 
    $_.Name -notlike "*pre-release*" -and
    $_.Name -notmatch "^Browsium-Ion-3\.4\."
} | Copy-Item -Destination ./staging
```

### 2. Sync to R2
Once the staging folder is ready, sync it to the bucket:

```bash
npx wrangler r2 object sync ./staging browsium-releases
```

### 3. Estimated Cost for this Set
* **Total Size**: ~24 GB
* **Free Tier**: 10 GB
* **Billable**: 14 GB
* **Monthly Cost**: ~$0.21

## Troubleshooting
*   **Large Uploads**: If the sync fails due to network issues, robocopy or the AWS CLI (configured for R2) may be more resilient.
*   **Cost**: Remember that storage over 10GB is billed at $0.015/GB. The ~32GB total will cost approximately $0.33/month.

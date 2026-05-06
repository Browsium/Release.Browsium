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

## Troubleshooting
*   **Large Uploads**: If the sync fails due to network issues, robocopy or the AWS CLI (configured for R2) may be more resilient.
*   **Cost**: Remember that storage over 10GB is billed at $0.015/GB. The ~32GB total will cost approximately $0.33/month.

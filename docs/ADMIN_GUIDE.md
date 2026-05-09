# Release Service Administrator Guide

## 1. System Architecture
The `release.browsium.com` service hosts large binary installers (EXE, ZIP) and documentation for all Browsium products.

*   **Platform**: Cloudflare R2 (Object Storage)
*   **Front-end Control**: Cloudflare Pages (for metadata/documentation)
*   **Storage Model**: Directly addressable bucket with Custom Domain mapping.
*   **Traffic Flow**: User Download Request -> `release.browsium.com` -> Cloudflare R2 Bucket -> Binary File.

## 2. Tech Stack
*   **Cloudflare R2**: S3-compatible object storage with $0 egress fees.
*   **Wrangler CLI**: Primary tool for managing and syncing large file sets.
*   **GitHub**: Repository (`Browsium/Release.Browsium`) for tracking this guide and deployment metadata.

## 3. How to Add a New Product Release
Because installers are large, they are **not** stored in Git. Follow these steps to upload new binaries:

### Method A: Single File Upload (Simplest)
```bash
npx wrangler r2 object put browsium-releases/Your-New-File.zip --file ./path/to/Your-New-File.zip --remote
```

### Method B: Folder Sync (Best for batches)
1.  Add the new files to your local `release/` directory.
2.  Run the sync command:
    ```bash
    npx wrangler r2 object sync ./release browsium-releases
    ```
    *Note: This will compare local vs. remote and only upload new/changed files.*

## 4. How to Update the Live Site
*   **Current Endpoint**: `new-release.browsium.com`.
*   **Publishing**: Files are live the moment the upload completes. There is no separate "publish" step.
*   **Production Cutover**: 
    1.  Go to **R2** -> **Buckets** -> `browsium-releases` -> **Settings**.
    2.  In **Custom Domains**, add `release.browsium.com`.
    3.  Update DNS to point to the R2 bucket.

## 5. Troubleshooting
*   **Access Denied / 404**: 
    *   Verify the file exists in the bucket: `npx wrangler r2 bucket info browsium-releases`.
    *   Ensure the bucket has "Public Access" enabled (currently enabled via custom domain).
*   **Slow Uploads**: For very large sets (10GB+), ensure you have a stable connection. The `sync` command can be resumed if interrupted.
*   **MIME Type Issues**: If a browser tries to "play" a file instead of downloading, force the content type during upload:
    ```bash
    npx wrangler r2 object put browsium-releases/file.exe --file ./file.exe --content-type application/octet-stream --remote
    ```

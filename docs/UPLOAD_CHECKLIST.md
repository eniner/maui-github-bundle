# Upload Checklist

1. Create a new GitHub repository.
2. Upload the full contents of this folder (`maui_github_bundle`).
3. Add screenshots under `docs/images/`.
4. Update `README.md` image references to match your final filenames.
5. Tag a release (optional) and attach a zip.

## Optional: Create zip locally

PowerShell:

```powershell
Compress-Archive -Path .\maui_github_bundle\* -DestinationPath .\maui_github_bundle.zip -Force
```

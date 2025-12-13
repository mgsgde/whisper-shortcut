# GitHub Actions Release Setup Guide

This guide explains how to set up the required secrets and certificates for automated builds and releases.

## Prerequisites

- A macOS machine with Xcode installed
- Access to your Apple Developer account
- A GitHub repository with Actions enabled

## Step 1: Export Your Developer ID Application Certificate

### Option A: Export from Keychain Access (Recommended)

1. **Open Keychain Access** on your Mac
   - Press `Cmd + Space` and search for "Keychain Access"
   - Or go to Applications > Utilities > Keychain Access

2. **Find your certificate**
   - In the left sidebar, select "login" keychain
   - Select "My Certificates" category
   - Look for "Developer ID Application: [Your Name]" (or similar)
   - Make sure it's the **Developer ID Application** certificate (not Developer ID Installer)

3. **Export the certificate**
   - Right-click on the certificate and select "Export [Certificate Name]"
   - Choose a location to save (e.g., Desktop)
   - Select file format: **Personal Information Exchange (.p12)**
   - Click "Save"
   - **Set a password** for the .p12 file (you'll need this for GitHub Secrets)
   - Click "OK"
   - You may be prompted for your Mac's admin password

### Option B: Export from Xcode

1. Open Xcode
2. Go to **Xcode > Settings** (or Preferences)
3. Click on **Accounts** tab
4. Select your Apple ID
5. Click **Manage Certificates...**
6. Find your "Developer ID Application" certificate
7. Right-click and select **Export**
8. Save as .p12 with a password

## Step 2: Encode Certificate to Base64

Run this command in Terminal (replace the path with your actual .p12 file path):

```bash
base64 -i ~/Desktop/DeveloperID.p12 -o - | pbcopy
```

Or if you prefer to save to a file first:

```bash
base64 -i ~/Desktop/DeveloperID.p12 > certificate_base64.txt
cat certificate_base64.txt
```

**Copy the entire output** - this is what you'll paste into GitHub Secrets.

## Step 3: Generate App-Specific Password for Notarization

1. Go to [appleid.apple.com](https://appleid.apple.com)
2. Sign in with your Apple ID
3. In the **Security** section, find **App-Specific Passwords**
4. Click **Generate Password...**
5. Give it a label like "GitHub Actions Notarization"
6. Click **Create**
7. **Copy the password immediately** - you won't be able to see it again!

## Step 4: Add Secrets to GitHub

1. Go to your GitHub repository
2. Click **Settings** (top menu)
3. In the left sidebar, click **Secrets and variables** > **Actions**
4. Click **New repository secret** for each of the following:

### Required Secrets

| Secret Name | Description | Example |
|------------|-------------|---------|
| `BUILD_CERTIFICATE_BASE64` | The base64-encoded .p12 certificate from Step 2 | (long base64 string) |
| `P12_PASSWORD` | The password you set when exporting the .p12 file | `mySecurePassword123` |
| `NOTARY_USERNAME` | Your Apple ID email address | `your.email@example.com` |
| `NOTARY_PASSWORD` | The app-specific password from Step 3 | `abcd-efgh-ijkl-mnop` |
| `TEAM_ID` | Your Apple Team ID | `Z59J7V26UT` |

### Optional Secret

| Secret Name | Description | Default |
|------------|-------------|---------|
| `KEYCHAIN_PASSWORD` | Password for temporary keychain (optional) | Auto-generated |

## Step 5: Verify Your Team ID

Your Team ID is already configured in the workflow as `Z59J7V26UT`. If you need to verify or change it:

1. Go to [developer.apple.com/account](https://developer.apple.com/account)
2. Sign in
3. Your Team ID is displayed in the top right corner

## Step 6: Test the Workflow

1. Create a test tag:

   ```bash
   git tag v1.0.0-test
   git push origin v1.0.0-test
   ```

2. Go to your GitHub repository > **Actions** tab
3. Watch the workflow run
4. If successful, you'll see a new Release with the DMG file

## Troubleshooting

### Certificate Issues

- **"No signing certificate found"**: Make sure you exported the **Developer ID Application** certificate, not the Installer certificate
- **"Invalid certificate"**: Ensure the certificate hasn't expired. Check in Keychain Access

### Notarization Issues

- **"Invalid credentials"**: Double-check your Apple ID email and app-specific password
- **"Team ID mismatch"**: Verify your Team ID matches the one in `exportOptions-release.plist`

### Build Issues

- **"Scheme not found"**: Ensure the scheme name matches exactly: `WhisperShortcut`
- **"Archive failed"**: Check that all dependencies are properly configured in Xcode

## Security Notes

- Never commit your .p12 certificate file to the repository
- Never commit your passwords or secrets
- The certificate is stored securely in GitHub Secrets (encrypted)
- App-specific passwords can be revoked at any time from appleid.apple.com

## Next Steps

Once set up, every time you push a tag starting with `v` (e.g., `v1.0.0`), the workflow will:

1. Build the app
2. Sign it with your certificate
3. Notarize it with Apple
4. Create a DMG
5. Upload it to GitHub Releases

To create a new release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

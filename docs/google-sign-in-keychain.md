# Fixing Google Sign-In "keychain error"

If Sign in with Google fails with **"keychain error"** in the app logs, the Google Sign-In SDK cannot write to the keychain because the app is missing the required entitlement.

## Reference

The working setup is the same as in commit **fea19a1** (Enhancement: Integrate Google Sign-In for Gemini API access): keychain-access-groups with **`$(AppIdentifierPrefix)com.google.GIDSignIn`** only.

## Fix

1. **Apple Developer Portal**
   - Go to [Identifiers](https://developer.apple.com/account/resources/identifiers/list) → select **com.magnusgoedde.whispershortcut** (or your app’s Bundle ID).
   - Enable **Keychain Sharing** and add the group: **`com.google.GIDSignIn`** (Apple will store it with your team prefix).
   - Save.

2. **Xcode**
   - Open the project → select the **WhisperShortcut** target → **Signing & Capabilities**.
   - Click **+ Capability** → add **Keychain Sharing**.
   - Add the group **`com.google.GIDSignIn`** (Xcode will use `$(AppIdentifierPrefix)com.google.GIDSignIn` in the entitlements).
   - Let Xcode refresh the provisioning profile (Xcode → Settings → Accounts → Download Manual Profiles if needed).

3. **Entitlements file** (already set in this repo, matching fea19a1)
   - `WhisperShortcut.entitlements` should contain:
   ```xml
   <key>keychain-access-groups</key>
   <array>
     <string>$(AppIdentifierPrefix)com.google.GIDSignIn</string>
   </array>
   ```

4. **Rebuild**
   - Clean build folder (Product → Clean Build Folder), then build and run again.

If the build fails with *"Provisioning profile doesn't match the entitlements file's value for the keychain-access-groups"*, the profile does not yet include Keychain Sharing for this App ID. Update the App ID in the developer portal (step 1), then re-download or regenerate the provisioning profile in Xcode.

---

## 403: "Generative Language API has not been used ... or it is disabled"

This error **only occurs when the app calls the Gemini API directly** (not via the backend). Architecture:

- **When signed in (intended):** The app always uses the **whisper-api** backend (Cloud Run) → Vertex AI for Gemini. The backend URL is **fixed in the app**; the user does not configure it. This 403 does not apply.

- **When using API key only (no sign-in):** App → **generativelanguage.googleapis.com** (Gemini API) directly. If you see this 403 while signed in, the app should be using the backend; ensure you are signed in and the app is up to date.

**If you want to keep using direct Gemini (no proxy) with OAuth:**

1. Open the API page for the project in the error (e.g. [project 797100884157](https://console.developers.google.com/apis/api/generativelanguage.googleapis.com/overview?project=797100884157)).
2. Click **Enable** for the Generative Language API.
3. Wait a few minutes, then retry.

**Recommended:** Sign in with Google so the app uses the backend (Vertex); then this 403 is irrelevant. The backend URL is set by the app, not by the user.

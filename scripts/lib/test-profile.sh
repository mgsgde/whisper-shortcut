#!/bin/bash
# Test profiles: an isolated copy of the Debug build for agents (see WhisperShortcut/TestProfile.swift).
# Sourced by scripts/rebuild-and-restart.sh (--profile), the run-whisper-shortcut driver
# (WS_PROFILE=<name>) and scripts/test-profile-selfcheck.sh.
#
# A profile is the freshly built "WhisperShortcut Dev.app", copied to build/profiles/<name>/, with
#   - its own bundle identifier com.magnusgoedde.whispershortcut.dev.profile.<name>, so macOS gives
#     it its own sandbox container: UserDefaults, Application Support, Documents, Caches and Logs
#     never touch the release's or the Dev build's;
#   - Info.plist keys WSTestProfile* that switch the app into profile mode (in-memory keychain,
#     no telemetry, no model downloads unless allowed, always a sidecar);
#   - entitlements re-signed WITHOUT keychain-access-groups, the provisioning-profile ids, the
#     Sparkle mach-lookup and the HIToolbox shared-preference exceptions, and WITH read-only
#     exceptions for the shared model folders of the source container (unless --no-models).
# The app refuses to run (exit 78) when any of that is not in place.

PROFILE_BUNDLE_PREFIX="com.magnusgoedde.whispershortcut.dev.profile."
# Relative to a container's Data folder. Keep in sync with TestProfile.sharedModelPaths.
PROFILE_MODEL_PATHS=(
  "Library/Application Support/WhisperShortcut/WhisperKit"
  "Library/Application Support/WhisperShortcut/MLXModels"
  "Library/Application Support/WhisperShortcut/Qwen3Models"
  "Library/Application Support/FluidAudio"
  "Documents/huggingface"
)

profile_valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; }
profile_bundle_id() { printf '%s%s\n' "$PROFILE_BUNDLE_PREFIX" "$1"; }
# $1 = project dir, $2 = name
profile_app_path() { printf '%s/build/profiles/%s/WhisperShortcut Dev.app\n' "$1" "$2"; }
profile_container() { printf '%s/Library/Containers/%s\n' "$HOME" "$(profile_bundle_id "$1")"; }
profile_defaults_plist() {
  printf '%s/Data/Library/Preferences/%s.plist\n' "$(profile_container "$1")" "$(profile_bundle_id "$1")"
}
profile_app_support() { printf '%s/Data/Library/Application Support/WhisperShortcut\n' "$(profile_container "$1")"; }

# The container whose models a profile links to, read-only. WS_PROFILE_MODELS_FROM=dev|release
# picks one; default: the Dev build's container if it holds any model folder, else the release's.
profile_model_source() {
  local id data rel
  case "${WS_PROFILE_MODELS_FROM:-}" in
    dev) id=com.magnusgoedde.whispershortcut.dev ;;
    release) id=com.magnusgoedde.whispershortcut ;;
    "") id="" ;;
    *) echo "WS_PROFILE_MODELS_FROM must be dev or release" >&2; return 1 ;;
  esac
  for candidate in ${id:-com.magnusgoedde.whispershortcut.dev com.magnusgoedde.whispershortcut}; do
    data="$HOME/Library/Containers/$candidate/Data"
    for rel in "${PROFILE_MODEL_PATHS[@]}"; do
      if [[ -d "$data/$rel" ]]; then printf '%s\n' "$data"; return 0; fi
    done
  done
  return 0   # nothing downloaded anywhere: the profile simply sees no models
}

# Delete one profile's container (settings + data) and its Application Scripts folder. Refuses any
# name that does not map to a profile identifier. The caller makes sure the profile is not running.
wipe_profile() {
  local name="$1" id container plist
  profile_valid_name "$name" || { echo "❌ invalid profile name: $name" >&2; return 1; }
  id="$(profile_bundle_id "$name")"
  container="$(profile_container "$name")"
  plist="$(profile_defaults_plist "$name")"
  [[ "$id" == "$PROFILE_BUNDLE_PREFIX"* && "$container" == "$HOME/Library/Containers/$PROFILE_BUNDLE_PREFIX"* ]] \
    || { echo "❌ refusing to wipe $container" >&2; return 1; }
  # Through cfprefsd first, so it does not hand the old values back to the next launch.
  [[ -f "$plist" ]] && defaults delete "${plist%.plist}" >/dev/null 2>&1
  rm -rf "$container" "$HOME/Library/Application Scripts/$id"
  if [[ -e "$container" ]]; then
    echo "❌ could not delete $container" >&2
    return 1
  fi
  echo "🧽 Wiped profile \"$name\" ($container)"
}

# make_profile_bundle <built Dev .app> <project dir> <name> <shared|none> <true|false allow downloads>
# Writes build/profiles/<name>/WhisperShortcut Dev.app and verifies it. Non-zero on any failure:
# the caller must not launch anything then.
make_profile_bundle() {
  local src="$1" project="$2" name="$3" models="$4" allow="$5"
  local id dest dir ent info source="" authority identity flags rel exceptions=()
  profile_valid_name "$name" || { echo "❌ invalid profile name \"$name\" (a-z, 0-9, -; max 32)" >&2; return 1; }
  [[ -d "$src" ]] || { echo "❌ no build at $src" >&2; return 1; }
  id="$(profile_bundle_id "$name")"
  dest="$(profile_app_path "$project" "$name")"
  dir="$(dirname "$dest")"
  [[ "$dir" == "$project/build/profiles/$name" ]] || return 1

  rm -rf "$dest"
  mkdir -p "$dir"
  ditto "$src" "$dest" || return 1

  info="$dest/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" "$info" || return 1
  /usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "$info" >/dev/null 2>&1
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string WhisperShortcut Profile $name" "$info" || return 1
  /usr/libexec/PlistBuddy -c "Delete :WSTestProfile" "$info" >/dev/null 2>&1
  /usr/libexec/PlistBuddy -c "Add :WSTestProfile string $name" "$info" || return 1
  /usr/libexec/PlistBuddy -c "Delete :WSTestProfileAllowModelDownloads" "$info" >/dev/null 2>&1
  /usr/libexec/PlistBuddy -c "Add :WSTestProfileAllowModelDownloads bool $allow" "$info" || return 1
  /usr/libexec/PlistBuddy -c "Delete :WSTestProfileModelSource" "$info" >/dev/null 2>&1
  if [[ "$models" == shared ]]; then
    source="$(profile_model_source)" || return 1
  fi
  /usr/libexec/PlistBuddy -c "Add :WSTestProfileModelSource string $source" "$info" || return 1

  # Entitlements: start from what the build was signed with, drop everything that ties the copy
  # to the Dev build's identity or reaches outside the profile, add read-only model exceptions.
  ent="$dir/profile.entitlements"
  codesign -d --entitlements - --xml "$src" > "$ent" 2>/dev/null || return 1
  local key
  for key in keychain-access-groups com.apple.application-identifier com.apple.developer.team-identifier \
    com.apple.security.temporary-exception.mach-lookup.global-name \
    com.apple.security.temporary-exception.shared-preference.read-write \
    com.apple.security.temporary-exception.files.absolute-path.read-only; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$ent" >/dev/null 2>&1
  done
  if [[ -n "$source" ]]; then
    for rel in "${PROFILE_MODEL_PATHS[@]}"; do
      [[ -d "$source/$rel" ]] && exceptions+=("$source/$rel/")
    done
    if [[ ${#exceptions[@]} -gt 0 ]]; then
      /usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-only array" "$ent" || return 1
      local i=0
      for rel in "${exceptions[@]}"; do
        /usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-only:$i string $rel" "$ent" || return 1
        i=$((i + 1))
      done
    fi
  fi
  rm -f "$dest/Contents/embedded.provisionprofile"

  # Same certificate as the build (keeps the team, so TCC grants and the container survive
  # rebuilds); ad-hoc when the build was ad-hoc.
  authority="$(codesign -dvv "$src" 2>&1 | sed -n 's/^Authority=//p' | head -n1)"
  identity="-"
  if [[ -n "$authority" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$authority\"" | head -n1 | awk '{print $2}')"
    [[ -n "$identity" ]] || { echo "❌ signing identity \"$authority\" not found" >&2; return 1; }
  fi
  flags=()
  codesign -dvv "$src" 2>&1 | grep -q 'flags=.*runtime' && flags=(--options runtime)
  codesign --force --sign "$identity" ${flags[@]+"${flags[@]}"} --entitlements "$ent" --timestamp=none "$dest" >/dev/null 2>&1 \
    || { echo "❌ re-signing the profile bundle failed" >&2; return 1; }

  # Verify instead of trusting the steps above.
  codesign --verify --strict "$dest" 2>/dev/null || { echo "❌ profile bundle signature does not verify" >&2; return 1; }
  [[ "$(codesign -dv "$dest" 2>&1 | sed -n 's/^Identifier=//p')" == "$id" ]] \
    || { echo "❌ profile bundle is not signed as $id" >&2; return 1; }
  if codesign -d --entitlements - --xml "$dest" 2>/dev/null | grep -q 'keychain-access-groups'; then
    echo "❌ profile bundle still carries keychain-access-groups" >&2
    return 1
  fi
  echo "🧪 Profile bundle: $dest"
  echo "   bundle id $id · models: ${source:-none} · downloads: $( [[ "$allow" == true ]] && echo allowed || echo blocked) · signed: $( [[ "$identity" == - ]] && echo ad-hoc || echo "$authority")"
}

# iOS incremental xcodebuild

Checklist for iOS projects where CLI builds are slow because `xcodebuild`
invalidates more than Xcode does, or because Crashlytics runs on every simulator
build.

## CLI build command

Run from the folder that contains the `.xcodeproj` or `.xcworkspace`:

```bash
xcodebuild \
  -project 'App.xcodeproj' \
  -scheme 'App' \
  -configuration Debug \
  -destination 'id=<BOOTED_SIMULATOR_ID>' \
  -disableAutomaticPackageResolution \
  -skipPackagePluginValidation \
  -quiet \
  build
```

For a workspace, replace `-project 'App.xcodeproj'` with:

```bash
-workspace 'App.xcworkspace'
```

Find the booted simulator:

```bash
xcrun simctl list devices available
```

Rules:

- do not run `clean`;
- do not pass a custom `-derivedDataPath` when you want to share Xcode's cache;
- always pass `-configuration Debug`;
- always pass an explicit `-destination`, preferably by simulator id;
- use `-disableAutomaticPackageResolution` only after packages are already
  resolved in Xcode or via `xcodebuild -list`;
- use `-quiet` for normal compile checks.

## Crashlytics dSYM script phase

If the build log says:

```text
Run script build phase 'Upload Crashlytics dSYMs' will be run during every build
because the option to run the script phase "Based on dependency analysis" is unchecked.
```

the Crashlytics phase is forced to run on every build. That is usually wasted
time for local Debug simulator builds.

In Xcode:

1. Open the app target.
2. Open `Build Phases`.
3. Find `Upload Crashlytics dSYMs`.
4. Enable `Based on dependency analysis`.
5. Keep Firebase's input files.
6. Add this output file:

```text
$(DERIVED_FILE_DIR)/CrashlyticsUpload-$(CONFIGURATION)-$(PLATFORM_NAME).stamp
```

Use this script:

```bash
STAMP_FILE="${DERIVED_FILE_DIR}/CrashlyticsUpload-${CONFIGURATION}-${PLATFORM_NAME}.stamp"

if [ "${CONFIGURATION}" = "Debug" ] && [ "${PLATFORM_NAME}" = "iphonesimulator" ]; then
  echo "Skipping Crashlytics dSYM upload for Debug simulator build."
  mkdir -p "$(dirname "${STAMP_FILE}")"
  touch "${STAMP_FILE}"
  exit 0
fi

"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"
STATUS=$?
if [ ${STATUS} -eq 0 ]; then
  mkdir -p "$(dirname "${STAMP_FILE}")"
  touch "${STAMP_FILE}"
fi
exit ${STATUS}
```

In `.pbxproj`, the phase should not contain:

```text
alwaysOutOfDate = 1;
```

## Verification

Run the same command twice:

```bash
time xcodebuild ... -quiet build
time xcodebuild ... -quiet build
```

The second run should be faster, and the build log should no longer warn that
the Crashlytics phase runs because dependency analysis is unchecked.

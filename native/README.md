# Native HRT Tracker

The SwiftUI app targets iOS 17 and later. The Capacitor target remains under `ios/`.
The native target uses `com.hellolaoyang.hrttracker.dev` during development.

## Build and run

From this directory, run `xcodegen generate`, open `HRTTracker.xcodeproj`, and run the
`HRTTracker` scheme on an iPhone simulator. Add `--demo` to the scheme's Run arguments
to load the synthetic design-review dataset into an in-memory store. Normal launches
start with local SwiftData storage.

## Check

- Run `swift test --package-path Packages/HRTEngine` for Swift engine regressions and
  the Web TypeScript reference fixtures.
- Run the `HRTTracker` scheme's UI tests on an iPhone simulator to capture the
  light and dark design review. The tests launch with the synthetic dataset.

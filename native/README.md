# Native HRT Tracker

The SwiftUI app targets iOS 17 and later. The Capacitor target remains under `ios/`.
The native target uses `com.hellolaoyang.hrttracker.dev` during development.

## Build and run

From this directory, run `xcodegen generate`, open `HRTTracker.xcodeproj`, and run the
`HRTTracker` scheme on an iPhone simulator. Add `--demo` to the scheme's Run arguments
to load the synthetic design-review dataset into an in-memory store. Normal launches
start with local SwiftData storage.

## Feedback

Settings → About → Feedback submits the title and description that the user
enters to the [feedback relay](../feedback-worker/README.md). A GitHub App
publishes that text to the public project repository. HRTrace does not send
an account, device identifier, or any data from the user's health records.
Cloudflare processes the request IP for rate limiting. The relay does not
include the IP in the Issue.

After deploying the Worker, set `HRT_FEEDBACK_ENDPOINT_URL` in
[`Feedback.xcconfig`](./Feedback.xcconfig) to the public HTTPS URL, including
`/feedback`. Use `https:/$()/` so Xcode keeps both slashes instead of reading
`//` as a comment.

```xcconfig
HRT_FEEDBACK_ENDPOINT_URL = https:/$()/feedback.example.com/feedback
```

The configuration applies to both Debug and Release. Rebuild the iPhone app
after changing the URL. Builds with an empty endpoint show feedback as
unavailable. Keep GitHub App credentials in the Worker's Cloudflare Secrets.

## Record assistant

The central AI tab item opens a sheet from the current screen. Review and visit
reports are available from the on-device records. Q&A uses Apple’s on-device
model when available, or an HTTPS OpenAI-compatible service selected by the user
in Settings → AI models. Provider credentials remain in the device Keychain.

One conversation, its compacted summaries, and user-saved memories remain in a
separate local store outside the health backup and cloud sync. The app uses a
256,000-token ceiling, limited by the active model and space for its answer.
Each compatible-service request shows its destination and data before sending.
Previous messages stay local. The user can explicitly include a compacted memory
summary in that request. The selected service's own retention policy still
applies to the data it receives. Clear chat and memory in the assistant to delete
the local AI data.

## Check

- Run `swift test --package-path Packages/HRTEngine` for Swift engine regressions and
  the Web TypeScript reference fixtures.
- Run the `HRTTracker` scheme's UI tests on an iPhone simulator to capture the
  light and dark design review. The tests launch with the synthetic dataset.

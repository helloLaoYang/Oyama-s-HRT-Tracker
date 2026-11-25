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

The HRTrace tab opens a local text assistant powered by Qwen2.5-1.5B-Instruct
through Core AI. On launch, HRTrace prepares the bundled model in the
background. The assistant tab appears once preparation succeeds. Recap and
visit summary open local reports directly from the composer.

The assistant uses up to 4,096 context tokens and reserves up to 256 tokens
for the reply. Its conversation, compacted summaries, and saved memories use
a local store separate from the health backup and cloud sync. Clear chat and
memory in the assistant to delete its local data.

### Offline model device build

The iOS 27 device project links Core AI. The regular project keeps the existing
deployment target and hides the assistant. Use a real device for Core AI testing.

Export the model with the pinned revision of
[Apple Core AI Models](https://github.com/apple/coreai-models) listed in
`project-offline.yml`. Run the export in that repository on macOS 27.

```sh
uv run coreai.llm.export Qwen/Qwen2.5-1.5B-Instruct --platform iOS --output-dir /path/to/export
```

Use the exported folder with `metadata.json`, the model asset, and the
`tokenizer` directory. Name the folder `Qwen2.5-1.5B-Instruct` and retain the
[model's Apache-2.0 license](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct/blob/main/LICENSE)
alongside the weights. Place the folder in `native/OfflineModels`. From
`native`, generate the project and build it in Xcode 27.

```sh
xcodegen generate --spec project-offline.yml
```

The portable `.aimodel` requires specialization the first time it loads. For
a device-specific test build, use the Metal Toolchain's `coreai-build compile`
with the device's `AIModel.deviceArchitectureName` and a Neural Engine
preference. Bundle the matching `.aimodelc` and point `assets.main` in
`metadata.json` to its filename.

## Check

- Run `swift test --package-path Packages/HRTEngine` for Swift engine regressions and
  the Web TypeScript reference fixtures.
- Run the `HRTTracker` scheme's UI tests on an iPhone simulator to capture the
  light and dark design review. The tests launch with the synthetic dataset.

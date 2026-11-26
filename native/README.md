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

The HRTrace tab opens a local assistant for the Core AI build. It prepares
the bundled Qwen3-8B-abliterated model when the assistant opens. The
composer shows model preparation and retry status. Recap, visit summaries,
and manual record corrections are available while the model prepares.

- Chat uses the user's message and local conversation history. HRTrace does
  not add a system prompt. Turn on **Records** to include local matches for
  medication, lab, and date terms in the selected range. Answers can open
  the records shared with the model. Lab measurements and curve estimates
  are labeled separately in the record context.
- **Correct a record** opens a separate review for a historical medication or
  lab value in its existing unit. AI can draft a value explicitly entered by
  the user, and the same field accepts manual input. The user reviews the
  before and after values and confirms the write. The sheet can undo that
  write while the saved record version is current.
- **Add input** reads photo text with Vision or transcribes a short recording
  with the on-device Speech framework. The user edits and inserts the
  resulting text into the composer. The assistant stores the submitted text
  in the local conversation. The first use of a speech language may require
  the system to download its speech asset.

Chat, compacted summaries, and saved memories use a local store separate
from the health backup and cloud sync. Clear chat and memory in the
assistant to delete its local data.

### Offline model build

The Core AI build uses the exact
[huihui-ai/Qwen3-8B-abliterated checkpoint](https://huggingface.co/huihui-ai/Qwen3-8B-abliterated)
without a model fallback. Its weights require Hugging Face access.
The regular iOS project keeps its existing deployment target. The offline
project builds for iOS 27 and can be run on Apple Silicon using the
**My Mac (Designed for iPad)** destination.

Use the [pinned Apple Core AI Models revision](project-offline.yml) on macOS 27.
Export for the device that will run the model. The checkpoint is a custom
Qwen3 export, so use the exporter's experimental flag with explicit
precision. The iOS command applies Apple's base Qwen3-8B mixed-precision
recipe. Retain the upstream model license with the export.

```sh
uv run coreai.llm.export huihui-ai/Qwen3-8B-abliterated \
  --experimental --compute-precision float16 --max-context-length 4096 \
  --platform iOS --compression-config models/qwen3/qwen3_8b_mixed_4bit_8bit.yaml \
  --output-dir /path/to/export

uv run coreai.llm.export huihui-ai/Qwen3-8B-abliterated \
  --experimental --compute-precision float16 --max-context-length 4096 \
  --platform macOS --compression 4bit --output-dir /path/to/export
```

Place the exported model asset, `metadata.json`, and the embedded
`tokenizer` directory together in
`native/OfflineModels/Qwen3-8B-abliterated`. This directory is ignored by Git.
From `native`, generate the offline project with XcodeGen.

```sh
xcodegen generate --spec project-offline.yml
```

To compile the offline target before exporting the model, create an empty
`OfflineModels/Qwen3-8B-abliterated` directory before generating the project.
Chat generation then reports that the files are missing. Portable assets specialize on first
load. Model compatibility, first-load time, and peak memory must be
checked on the deployment device. Apple's base 8B iOS recipe is
multi-gigabyte and may exceed an iPhone app's available memory. The
simulator runs assistant interface and data tests with a stubbed model.

Full image understanding and image generation require separate models.
The current photo path supports text recognition and review.

## Check

- Run `swift test --package-path Packages/HRTEngine` for Swift engine regressions and
  the Web TypeScript reference fixtures.
- Run the `HRTTracker` scheme's UI tests on an iPhone simulator to capture the
  light and dark design review. The tests launch with the synthetic dataset.

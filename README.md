# Observer

A macOS 26 menu bar meeting assistant. Observer notices when Zoom, Meet, Teams, FaceTime, Webex, or Slack huddles start, prompts you to record, captures locally, transcribes on-device, and writes a report with Ollama, LM Studio, or OpenRouter.

No bot joins the call. Audio and video stay on this Mac. Only transcript text is sent to the model you choose.

## Requirements

- macOS 26 Tahoe or later
- Xcode 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Optional: [Ollama](https://ollama.com) or [LM Studio](https://lmstudio.ai) for local summaries

## Build

```bash
xcodegen generate
open Observer.xcodeproj
```

Run the **Observer** scheme. The app lives in the menu bar (no Dock icon).

## First launch

1. Grant Screen Recording, Microphone, and Speech Recognition when asked.
2. Open the menu bar extra → **Simulate meeting** to exercise the glass prompt without a real call.
3. In Settings → Models, point Observer at Ollama (`http://127.0.0.1:11434`), LM Studio (`http://127.0.0.1:1234`), or OpenRouter.

Recordings and the SwiftData store live in `~/Library/Application Support/Observer/`.

## Phase 1 scope

Detection, glass record prompt, ScreenCaptureKit capture, live dual-track transcript (You / Others), meeting library, post-meeting summary.

Live research (Tavily), fact-checking, and historical RAG are later phases.

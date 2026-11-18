# ZiBridge

ZiBridge connects a Feishu-edition soundcore D3200 to an Apple Silicon Mac and sends its microphone audio to BlackHole 2ch. Tested with firmware 4.92.3.06 and ZiVoice. For Typeless clients that follow the system input, select BlackHole 2ch in macOS Sound settings and use the usual dictation shortcut. End-to-end Typeless dictation is pending verification.

[中文及英文连接指南 / Setup guide for Typeless](docs/typeless-soundcore-mac.md)

## Build the Mac app

Use an Apple Silicon Mac with Xcode Command Line Tools (Swift), Python 3, and the arm64 Homebrew build of libopus 1.6.1. The build script checks the library at `/opt/homebrew/Cellar/opus/1.6.1/lib/libopus.0.dylib` against its pinned checksum and bundles it with its license. Microphone forwarding also requires [BlackHole 2ch](https://existential.audio/blackhole/).

```sh
git clone https://github.com/372790111z-wq/ZiBridge.git
cd ZiBridge
bash scripts/build-workbench.sh build/workbench
open build/workbench/BridgeWorkbench.app
```

This source build uses a local ad-hoc signature. On first use, allow Bluetooth access, select your own recorder, and start capture when ready. The recorder may retain the session and sync it to Feishu after reconnecting to the phone. Stop capture and confirm the recorder has stopped before disconnecting. When changing the Mac input device, keep your headphones or speakers selected as the output.

Protocol and audio dependency credits are listed in [the notices](native/pilot/NOTICE.md) and [the OpenBean license](LICENSE.openbean).

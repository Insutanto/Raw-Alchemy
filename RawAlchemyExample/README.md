# RawAlchemyExample – iOS

An iOS 16+ SwiftUI example app that demonstrates the full
**RAW → Log** pipeline provided by `RawAlchemyKit`.

```
Raw-Alchemy/
├── RawAlchemySwift/       ← Swift package (RawAlchemyKit)
└── RawAlchemyExample/     ← this Xcode project
```

## Features

| Screen | What it shows |
|--------|---------------|
| **Home** | File picker + pipeline settings (log space, metering mode, manual exposure) |
| **Processing** | Activity spinner while the four-stage pipeline runs on a background thread |
| **Result** | Full-resolution log-encoded preview, metadata, and a share sheet |

## Prerequisites

| Requirement | Version |
|-------------|---------|
| Xcode | 15.0 + |
| iOS Deployment Target | 16.0 + |
| macOS (build host) | 13.0 + |

> **No extra libraries needed.** On iOS the RAW decoder uses Apple's
> `CIRAWFilter` (CoreImage), so there is no dependency on `libraw`.

## Getting Started

1. **Open the project in Xcode**

   ```
   open RawAlchemyExample/RawAlchemyExample.xcodeproj
   ```

   Xcode will automatically resolve the local `RawAlchemySwift` package
   (referenced as `../RawAlchemySwift` relative to the project file).

2. **Set your Development Team**

   In *Project → Signing & Capabilities*, choose your personal or
   organisation Apple Developer team so Xcode can sign the app for a
   real device.

3. **Select an iPhone or iPad target** and press ▶︎ Run.

## Using the App

1. Tap **Select RAW File…** and choose a RAW file from the Files app
   (or AirDrop / import one first).
2. Choose the **Log Space** that matches your camera or NLE workflow.
3. Pick an **Exposure** strategy:
   - *Auto* – one of five metering algorithms analyses the scene and sets
     gain so key-grey → 18 %.
   - *Manual* – set an explicit ±5 EV offset with the slider.
4. Tap **Process** (top-right).  
   The pipeline runs in the background: RAW decode → exposure → colour
   matrix → log encode.
5. The result screen shows the log-encoded preview and processing
   metadata. Tap **Share ↑** to export via AirDrop, Files, or any other
   share destination.

## Architecture

```
ContentView          – SwiftUI Form: file picker + settings
  └─► ConvertView    – processing spinner + result layout
        └─► ProcessingViewModel (@MainActor ObservableObject)
              └─► Task.detached → RawToLogPipeline.process()
                    ├── RAWDecoder      (CIRAWFilter on iOS)
                    ├── ExposureMetering
                    ├── ColorSpace + LogEncoding
                    └── LUTInterpolation (optional)
```

### Key files

| File | Purpose |
|------|---------|
| `RawAlchemyExampleApp.swift` | `@main` entry point |
| `ContentView.swift` | Settings screen with `.fileImporter` |
| `ConvertView.swift` | Processing / result / error states |
| `ProcessingViewModel.swift` | Async pipeline, security-scoped URL handling, UIImage preview |

## Notes on log-encoded previews

Log-encoded images are **intentionally flat and low-contrast** – they
contain more dynamic range than sRGB can display.  The preview in the
app reflects this correctly.  To see the image as it would look after
colour grading:

- Apply a camera-specific LUT (e.g. Sony S-Log3 → Rec.709) in a capable
  app such as DaVinci Resolve, BRAW Toolbox, or FilmConvert.
- Or supply a `.cube` LUT via `RawToLogOptions.lutURL` before calling
  `RawToLogPipeline.process()`.

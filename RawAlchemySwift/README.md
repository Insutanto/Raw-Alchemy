# RawAlchemySwift

Swift port of the four core processing modules from the [Raw Alchemy](https://github.com/Insutanto/Raw-Alchemy) Python project, plus a top-level pipeline that converts a camera RAW file directly to a Log-encoded image.

## Modules

| Module | Swift file | Mirrors Python |
|---|---|---|
| RAW 解码 (RAW decoding) | `RAWDecoder.swift` | `rawpy.postprocess()` in `core.py` |
| 曝光测光 (Exposure metering) | `ExposureMetering.swift` | `metering.py` |
| 色彩矩阵 + Log 曲线 (Color matrix + Log curve) | `ColorSpace.swift` + `LogEncoding.swift` | `core.py` Steps 4.1 & 4.2 |
| LUT 四面体插值 (Tetrahedral LUT interpolation) | `LUTInterpolation.swift` | `utils.apply_lut_inplace()` |
| RAW → Log pipeline | `RawToLog.swift` | `core.process_image()` |

---

## Requirements

* Swift 5.9 +
* macOS 13 + (tested), Linux (with Swift 5.9 toolchain)
* **libraw** installed:
  * macOS: `brew install libraw`
  * Ubuntu/Debian: `apt-get install libraw-dev`

---

## Quick Start

### Swift Package Manager

Add to your `Package.swift`:

```swift
.package(path: "path/to/RawAlchemySwift"),
```

Then import and use:

```swift
import RawAlchemyKit

// Simplest form – RAW → S-Log3 with automatic matrix metering
let result = try RawToLogPipeline.process(
    rawPath:     "/path/to/IMG_0001.ARW",
    logSpace:    .sLog3,
    meteringMode: .matrix
)

// result.pixels  – Float32 interleaved RGB, values in [0, 1] after Log encoding
// result.width / result.height
// result.appliedGain
```

### Pipeline with all options

```swift
var opts = RawToLogOptions()
opts.logSpace       = .arriLogC3          // Target log space
opts.meteringMode   = .hybrid             // Auto-exposure metering
opts.exposureEV     = nil                 // nil = auto, Float = manual EV
opts.targetGray     = 0.18
opts.lutURL         = URL(fileURLWithPath: "/path/to/Film.cube")
opts.highlightMode  = 2                   // 2 = blend (libraw)
opts.demosaicQuality = 11                 // 11 = AAHD

let result = try RawToLogPipeline.process(rawPath: "/path/to/file.CR3",
                                           options: opts)
```

### Supported Log spaces

| Enum case | Log format | Working gamut |
|---|---|---|
| `.sLog3` | Sony S-Log3 | S-Gamut3 |
| `.sLog3Cine` | Sony S-Log3.Cine | S-Gamut3.Cine |
| `.fLog` | Fujifilm F-Log | F-Gamut |
| `.fLog2` | Fujifilm F-Log2 | F-Gamut |
| `.fLog2C` | Fujifilm F-Log2C | F-Gamut C |
| `.vLog` | Panasonic V-Log | V-Gamut |
| `.nLog` | Nikon N-Log | N-Gamut |
| `.lLog` | Leica/Lumix L-Log | BT.2020 |
| `.canonLog2` | Canon Log 2 | Cinema Gamut |
| `.canonLog3` | Canon Log 3 | Cinema Gamut |
| `.arriLogC3` | ARRI LogC3 (EI 800) | ARRI Wide Gamut 3 |
| `.arriLogC4` | ARRI LogC4 | ARRI Wide Gamut 4 |
| `.log3G10` | RED Log3G10 | REDWideGamutRGB |
| `.dLog` | DJI D-Log | DJI D-Gamut |

### Supported metering modes

| Enum case | Description |
|---|---|
| `.average` | Log-average (geometric mean) |
| `.centerWeighted` | Gaussian center-weighted |
| `.highlightSafe` | ETTR / highlight-safe (99th percentile) |
| `.hybrid` | Log-average + highlight ceiling |
| `.matrix` | 7×7 zone evaluation (default) |

---

## Module details

### RAWDecoder

Wraps the libraw C API to produce a **linear-light ProPhoto RGB Float32** image, exactly matching the Python `rawpy.postprocess()` call:

```swift
let img: DecodedRAWImage = try RAWDecoder.decode(path: "/path/to/file.NEF")
// img.pixels – [Float], length = width × height × 3, range [0, 1]
```

### ExposureMetering

Five strategies conforming to `MeteringStrategy`:

```swift
let gain = MatrixMeteringStrategy().calculateGain(
    rgb: buffer, width: w, height: h,
    lumaCoeffs: prophoToYCoeffs, targetGray: 0.18)

// Or use the convenience wrapper:
let appliedGain = applyAutoExposure(rgb: buffer, width: w, height: h,
                                    mode: .hybrid)
```

### ColorSpace + LogEncoding

```swift
// 1. Compute gamut-transform matrix (ProPhoto → S-Gamut3)
let m = LogSpaceMatrix.matrix(for: .sLog3)           // [Float] × 9, row-major
applyMatrix3x3(buffer: buf, pixelCount: w*h, matrix: m)

// 2. Apply log encoding per-pixel
encodeLogBuffer(buffer: buf, pixelCount: w*h, space: .sLog3)
```

### LUT Tetrahedral Interpolation

```swift
// Parse a .cube file
let lut = try parseCubeLUT(contentsOf: URL(fileURLWithPath: "film.cube"))

// Apply to pixel buffer in-place
applyLUT3D(buffer: buf, pixelCount: w*h, lut: lut)
```

---

## Running tests

```bash
cd RawAlchemySwift
swift test
```

Tests cover log encoding, metering strategies, LUT identity/constant cases, and
color-space matrix validity.  Tests that require an actual RAW file are omitted
from the automated suite; see `RawAlchemyKitTests.swift` for extension points.

---

## Algorithm references

* S-Log3: Sony "S-Log3 Technical Summary" (2014)
* F-Log / F-Log2: Fujifilm data sheets (2018, 2019)
* V-Log: Panasonic "V-Log/V-Gamut Reference Manual" (2014)
* N-Log: Nikon "N-Log Specification Document" (2018)
* L-Log: Leica Camera AG "L-Log Reference Manual" (2020)
* Canon Log 2/3: Canon "Cinema EOS" white papers (2018)
* ARRI LogC3/4: ARRI official white papers (2012, 2022)
* RED Log3G10: RED "IPP2 White Paper" (2017)
* DJI D-Log: DJI "D-Log/D-Gamut White Paper" (2017)
* Tetrahedral interpolation: Sakamoto (2002), adopted by the ICC and ACES CLF spec
* Color matrix computation: colour-science methodology (https://colour.readthedocs.io)
* Bradford chromatic adaptation: ICC profile specification

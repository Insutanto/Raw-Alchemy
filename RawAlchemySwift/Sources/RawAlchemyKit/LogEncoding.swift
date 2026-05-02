/// LogEncoding.swift
/// Per-camera / per-format Log encoding functions (linear scene light → log code value).
///
/// All formulas are derived from:
///   • Official manufacturer SDK/white-paper documentation
///   • ACES Common LUT Format (CLF) specification
///   • colour-science Python library (https://colour.readthedocs.io)
///
/// Each function accepts a *scene-linear* value (≥ 0) and returns the
/// encoded log code value in [0, 1].  Clipping of negative inputs is the
/// caller's responsibility (pipeline clamps to 1e-6 before calling).

import Foundation

// MARK: - Log space enum

/// All log formats supported by the Raw Alchemy pipeline.
public enum LogSpace: String, CaseIterable {
    case sLog3     = "S-Log3"
    case sLog3Cine = "S-Log3.Cine"
    case fLog      = "F-Log"
    case fLog2     = "F-Log2"
    case fLog2C    = "F-Log2C"
    case vLog      = "V-Log"
    case nLog      = "N-Log"
    case lLog      = "L-Log"
    case canonLog2 = "Canon Log 2"
    case canonLog3 = "Canon Log 3"
    case arriLogC3 = "Arri LogC3"
    case arriLogC4 = "Arri LogC4"
    case log3G10   = "Log3G10"
    case dLog      = "D-Log"
}

// MARK: - Per-format encoding functions

/// Sony S-Log3 encoding.
/// Reference: Sony "S-Log3 Technical Summary" (2014)
@inline(__always)
public func encodeSLog3(_ x: Float) -> Float {
    // Knee at scene linear = 0.01125 / 0.18
    let kneeSL: Float = 0.01125 / 0.18   // ≈ 0.0625 scene-linear

    if x >= kneeSL {
        return (420.0 + log10((x + 0.01) / (0.18 + 0.01)) * 261.5) / 1023.0
    } else {
        return (x * (171.2102946929 - 95.0) / 0.01125 + 95.0) / 1023.0
    }
}

/// Fuji F-Log encoding.
/// Reference: Fujifilm "F-Log Data Sheet" (2018)
@inline(__always)
public func encodeFLog(_ x: Float) -> Float {
    let cut1: Float = 0.00089
    if x >= cut1 {
        return 0.45310179 * log10(x + 0.00268) + 0.09232
    } else {
        return 8.735631 * x + 0.092864
    }
}

/// Fuji F-Log2 encoding.
/// Reference: Fujifilm "F-Log2 Data Sheet" (2019)
@inline(__always)
public func encodeFLog2(_ x: Float) -> Float {
    let cut1: Float = 0.000889
    if x >= cut1 {
        return 0.384975 * log10(x + 0.0064) + 0.092864
    } else {
        return 8.799461 * x + 0.073281
    }
}

/// Panasonic V-Log encoding.
/// Reference: Panasonic "V-Log/V-Gamut Reference Manual" (2014)
@inline(__always)
public func encodeVLog(_ x: Float) -> Float {
    let cut1: Float = 0.01
    if x >= cut1 {
        return 0.241514 * log10(x + 0.00873) + 0.598206
    } else {
        return 5.6 * x + 0.125
    }
}

/// Nikon N-Log encoding.
/// Reference: Nikon "N-Log Specification Document" (2018)
@inline(__always)
public func encodeNLog(_ x: Float) -> Float {
    // Piecewise: linear below cut, logarithmic above.
    // cut ≈ 0.328 scene-linear (derived from the Nikon spec knee point).
    let cut: Float  = 0.328
    let c: Float    = 650.0 / 1023.0
    if x >= cut {
        return c * Foundation.log(x / cut + 1.0) + c * Foundation.log(2.0)
    } else {
        return c * (x / cut)
    }
}

/// Leica / Lumix L-Log encoding (output referred to BT.2020 gamut).
/// Reference: Leica Camera AG "L-Log Reference Manual" (2020)
@inline(__always)
public func encodeLLog(_ x: Float) -> Float {
    let cut: Float = 0.004
    if x >= cut {
        return 0.256598 * log10(x + 0.006) + 0.553549
    } else {
        return 16.5 * x + 0.092
    }
}

/// Canon Log 2 encoding.
/// Reference: Canon "Canon Log 2 Characteristics" (2018)
@inline(__always)
public func encodeCanonLog2(_ x: Float) -> Float {
    if x >= 0.0 {
        return 0.24136077 * log10(x / 0.9 + 1.0) + 0.092864125
    } else {
        return -0.24136077 * log10(-x / 0.9 + 1.0) + 0.092864125
    }
}

/// Canon Log 3 encoding.
/// Reference: Canon "Canon Log 3 Characteristics" (2018)
@inline(__always)
public func encodeCanonLog3(_ x: Float) -> Float {
    let cutPos: Float =  0.097465473
    let cutNeg: Float = -0.097465473
    if x >= cutPos {
        return 0.42889912 * log10(x / 0.36 + 1.0) + 0.12512248
    } else if x <= cutNeg {
        return -0.42889912 * log10(-x / 0.36 + 1.0) + 0.12512248
    } else {
        return 14.98325 * x + 0.12512248
    }
}

/// ARRI LogC3 encoding (EI 800 – the common setting for digital cinema).
/// Reference: ARRI "LogC3 Curve White Paper" (2012)
@inline(__always)
public func encodeArriLogC3(_ x: Float) -> Float {
    // EI 800 cut / slope / offset from ARRI spec
    let cut: Float  =  0.010591
    let a: Float    =  5.555556
    let b: Float    =  0.052272
    let c: Float    =  0.247190
    let d: Float    =  0.385537
    let e: Float    =  5.367655
    let f: Float    =  0.092809

    if x >= cut {
        return c * log10(a * x + b) + d
    } else {
        return e * x + f
    }
}

/// ARRI LogC4 encoding.
/// Reference: ARRI "LogC4 Specification" (2022)
@inline(__always)
public func encodeArriLogC4(_ x: Float) -> Float {
    // LogC4 uses a single formula (no linear segment in the published spec):
    //   y = (log2(x * (2^18 - 16) / 117.45 + 1) + 6) / 14
    let a: Float = (pow(2.0, 18.0) - 16.0) / 117.45  // ≈ 2231.0
    let b: Float = 1.0 / 14.0
    let c: Float = 6.0 / 14.0                          // ≈ 0.42857
    return log2(x * a + 1.0) * b + c
}

/// RED Log3G10 encoding.
/// Reference: RED "IPP2 White Paper" (2017)
@inline(__always)
public func encodeLog3G10(_ x: Float) -> Float {
    // Offset to place 0 scene-linear at code value ≈ 0:
    let offset: Float = 0.01   // black offset
    let xo = x + offset
    if xo > 0.0 {
        return 0.224282 * log10(xo * 155.975327 + 1.0)
    } else {
        return xo * (0.224282 * 155.975327 / log(10.0))
    }
}

/// DJI D-Log encoding.
/// Reference: DJI "D-Log and D-Gamut White Paper" (2017)
@inline(__always)
public func encodeDLog(_ x: Float) -> Float {
    let cut: Float = 0.0078
    if x >= cut {
        return 0.256663 * log10(x + 0.0108) + 0.584555
    } else {
        return 6.025 * x + 0.0929
    }
}

// MARK: - Dispatch

/// Encode a single scene-linear value using the requested log format.
@inline(__always)
public func encodeLog(_ x: Float, space: LogSpace) -> Float {
    switch space {
    case .sLog3, .sLog3Cine: return encodeSLog3(x)
    case .fLog:              return encodeFLog(x)
    case .fLog2, .fLog2C:   return encodeFLog2(x)
    case .vLog:              return encodeVLog(x)
    case .nLog:              return encodeNLog(x)
    case .lLog:              return encodeLLog(x)
    case .canonLog2:         return encodeCanonLog2(x)
    case .canonLog3:         return encodeCanonLog3(x)
    case .arriLogC3:         return encodeArriLogC3(x)
    case .arriLogC4:         return encodeArriLogC4(x)
    case .log3G10:           return encodeLog3G10(x)
    case .dLog:              return encodeDLog(x)
    }
}

/// Apply the log encoding to every pixel in a contiguous RGB Float32 buffer
/// (`pixelCount` RGB triples, i.e. `pixelCount * 3` floats).
/// Values are clamped to a minimum of 1e-6 before encoding to avoid log(0).
public func encodeLogBuffer(buffer: UnsafeMutablePointer<Float>,
                             pixelCount: Int,
                             space: LogSpace) {
    let count = pixelCount * 3
    for i in 0 ..< count {
        let v = max(buffer[i], 1e-6)
        buffer[i] = encodeLog(v, space: space)
    }
}

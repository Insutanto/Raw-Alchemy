/// LUTInterpolation.swift
/// Swift port of the Numba-accelerated `apply_lut_inplace` in utils.py.
///
/// Implements tetrahedral (Sakamoto) interpolation for 3D LUTs – the industry-
/// standard algorithm used by DaVinci Resolve, Nuke, etc.
///
/// LUT data format (mirrors colour-science LUT3D):
///   table[r][g][b] = (out_r, out_g, out_b)   where indices run [0, size-1]
/// Stored as a flat Float array of length size³ × 3, index-order R-major:
///   table[(r*size + g)*size*3 + b*3 + channel]

import Foundation

// MARK: - LUT3D container

/// A 3D LUT with domain mapping and the flat colour table.
public struct LUT3D {
    /// Number of grid points along each axis.
    public let size: Int
    /// Minimum input value per channel [r, g, b].
    public let domainMin: (Float, Float, Float)
    /// Maximum input value per channel [r, g, b].
    public let domainMax: (Float, Float, Float)
    /// Flat colour table, R-major: [(r*size + g)*size + b] × 3 floats.
    public let table: [Float]

    public init(size: Int,
                domainMin: (Float, Float, Float) = (0, 0, 0),
                domainMax: (Float, Float, Float) = (1, 1, 1),
                table: [Float]) {
        precondition(table.count == size * size * size * 3,
                     "LUT table length mismatch: expected \(size*size*size*3), got \(table.count)")
        self.size = size
        self.domainMin = domainMin
        self.domainMax = domainMax
        self.table = table
    }

    /// Inline helper: look up a lattice node and return (R,G,B).
    @inline(__always)
    func lookup(_ x0: Int, _ y0: Int, _ z0: Int) -> (Float, Float, Float) {
        let base = ((x0 * size + y0) * size + z0) * 3
        return (table[base], table[base+1], table[base+2])
    }
}

// MARK: - Tetrahedral interpolation (single pixel)

/// Applies tetrahedral interpolation for one input RGB triple and returns the
/// mapped output triple.
///
/// The algorithm partitions the unit cube around each sample point into one of
/// 6 tetrahedra (Sakamoto's algorithm) and performs a 4-point barycentric
/// interpolation.  This gives a higher-quality result than trilinear with the
/// same number of LUT lookups (4 vs 8).
@inline(__always)
public func tetrahedralInterpolate(lut: LUT3D,
                                    inR: Float, inG: Float, inB: Float)
    -> (Float, Float, Float) {

    let s = lut.size
    let sf = Float(s - 1)

    // Scale to [0, size-1]
    let (minR, minG, minB) = lut.domainMin
    let (maxR, maxG, maxB) = lut.domainMax

    let scR = sf / (maxR - minR)
    let scG = sf / (maxG - minG)
    let scB = sf / (maxB - minB)

    let idxR = min(max((inR - minR) * scR, 0), sf)
    let idxG = min(max((inG - minG) * scG, 0), sf)
    let idxB = min(max((inB - minB) * scB, 0), sf)

    // Integer floor and delta
    var x0 = Int(idxR); let dx = idxR - Float(x0)
    var y0 = Int(idxG); let dy = idxG - Float(y0)
    var z0 = Int(idxB); let dz = idxB - Float(z0)

    // Clamp upper indices
    let x1 = x0 < s-1 ? x0 + 1 : x0
    let y1 = y0 < s-1 ? y0 + 1 : y0
    let z1 = z0 < s-1 ? z0 + 1 : z0

    // Clamp lower indices (for the case idxR == sf exactly)
    if x0 >= s { x0 = s - 1 }
    if y0 >= s { y0 = s - 1 }
    if z0 >= s { z0 = s - 1 }

    // Read base and far corner (always used in all 6 cases)
    let (p0r, p0g, p0b) = lut.lookup(x0, y0, z0)
    let (p3r, p3g, p3b) = lut.lookup(x1, y1, z1)

    var outR: Float; var outG: Float; var outB: Float

    if dx >= dy {
        if dy >= dz {
            // Case 1: dx ≥ dy ≥ dz  →  P1=(1,0,0), P2=(1,1,0)
            let (p1r,p1g,p1b) = lut.lookup(x1, y0, z0)
            let (p2r,p2g,p2b) = lut.lookup(x1, y1, z0)
            let w0=1-dx; let w1=dx-dy; let w2=dy-dz; let w3=dz
            outR = w0*p0r + w1*p1r + w2*p2r + w3*p3r
            outG = w0*p0g + w1*p1g + w2*p2g + w3*p3g
            outB = w0*p0b + w1*p1b + w2*p2b + w3*p3b
        } else if dx >= dz {
            // Case 2: dx ≥ dz > dy  →  P1=(1,0,0), P2=(1,0,1)
            let (p1r,p1g,p1b) = lut.lookup(x1, y0, z0)
            let (p2r,p2g,p2b) = lut.lookup(x1, y0, z1)
            let w0=1-dx; let w1=dx-dz; let w2=dz-dy; let w3=dy
            outR = w0*p0r + w1*p1r + w2*p2r + w3*p3r
            outG = w0*p0g + w1*p1g + w2*p2g + w3*p3g
            outB = w0*p0b + w1*p1b + w2*p2b + w3*p3b
        } else {
            // Case 3: dz > dx ≥ dy  →  P1=(0,0,1), P2=(1,0,1)
            let (p1r,p1g,p1b) = lut.lookup(x0, y0, z1)
            let (p2r,p2g,p2b) = lut.lookup(x1, y0, z1)
            let w0=1-dz; let w1=dz-dx; let w2=dx-dy; let w3=dy
            outR = w0*p0r + w1*p1r + w2*p2r + w3*p3r
            outG = w0*p0g + w1*p1g + w2*p2g + w3*p3g
            outB = w0*p0b + w1*p1b + w2*p2b + w3*p3b
        }
    } else { // dy > dx
        if dz >= dy {
            // Case 6: dz ≥ dy > dx  →  P1=(0,0,1), P2=(0,1,1)
            let (p1r,p1g,p1b) = lut.lookup(x0, y0, z1)
            let (p2r,p2g,p2b) = lut.lookup(x0, y1, z1)
            let w0=1-dz; let w1=dz-dy; let w2=dy-dx; let w3=dx
            outR = w0*p0r + w1*p1r + w2*p2r + w3*p3r
            outG = w0*p0g + w1*p1g + w2*p2g + w3*p3g
            outB = w0*p0b + w1*p1b + w2*p2b + w3*p3b
        } else if dz >= dx {
            // Case 5: dy ≥ dz > dx  →  P1=(0,1,0), P2=(0,1,1)
            let (p1r,p1g,p1b) = lut.lookup(x0, y1, z0)
            let (p2r,p2g,p2b) = lut.lookup(x0, y1, z1)
            let w0=1-dy; let w1=dy-dz; let w2=dz-dx; let w3=dx
            outR = w0*p0r + w1*p1r + w2*p2r + w3*p3r
            outG = w0*p0g + w1*p1g + w2*p2g + w3*p3g
            outB = w0*p0b + w1*p1b + w2*p2b + w3*p3b
        } else {
            // Case 4: dy > dx ≥ dz  →  P1=(0,1,0), P2=(1,1,0)
            let (p1r,p1g,p1b) = lut.lookup(x0, y1, z0)
            let (p2r,p2g,p2b) = lut.lookup(x1, y1, z0)
            let w0=1-dy; let w1=dy-dx; let w2=dx-dz; let w3=dz
            outR = w0*p0r + w1*p1r + w2*p2r + w3*p3r
            outG = w0*p0g + w1*p1g + w2*p2g + w3*p3g
            outB = w0*p0b + w1*p1b + w2*p2b + w3*p3b
        }
    }

    return (outR, outG, outB)
}

// MARK: - Apply LUT to a pixel buffer in-place

/// Applies a `LUT3D` to an RGB Float32 pixel buffer in-place.
/// The buffer layout is interleaved: R₀ G₀ B₀ R₁ G₁ B₁ …
/// - Parameters:
///   - buffer: Pointer to the pixel data (modified in-place).
///   - pixelCount: Number of pixels (buffer length = pixelCount × 3).
///   - lut: The 3D LUT to apply.
public func applyLUT3D(buffer: UnsafeMutablePointer<Float>,
                        pixelCount: Int,
                        lut: LUT3D) {
    for i in 0 ..< pixelCount {
        let base = i * 3
        let (r, g, b) = tetrahedralInterpolate(lut: lut,
                                                inR: buffer[base],
                                                inG: buffer[base+1],
                                                inB: buffer[base+2])
        buffer[base]   = r
        buffer[base+1] = g
        buffer[base+2] = b
    }
}

// MARK: - .cube file parser

/// Parses a minimal .cube LUT file and returns a `LUT3D`.
/// Supports 3D LUTs only (CUBE spec Rev. 1.0).
public func parseCubeLUT(contentsOf url: URL) throws -> LUT3D {
    let text = try String(contentsOf: url, encoding: .utf8)
    let lines = text.components(separatedBy: .newlines)

    var size: Int = 0
    var domMin: (Float,Float,Float) = (0,0,0)
    var domMax: (Float,Float,Float) = (1,1,1)
    var table: [Float] = []

    for raw in lines {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") || line.isEmpty { continue }

        if line.hasPrefix("LUT_3D_SIZE") {
            let parts = line.split(separator: " ")
            size = Int(parts.last ?? "0") ?? 0
        } else if line.hasPrefix("DOMAIN_MIN") {
            let v = parseFloatTriple(line)
            domMin = (v[0], v[1], v[2])
        } else if line.hasPrefix("DOMAIN_MAX") {
            let v = parseFloatTriple(line)
            domMax = (v[0], v[1], v[2])
        } else if line.hasPrefix("LUT_1D_SIZE") {
            throw CubeParseError.unsupported1DLUT
        } else {
            // Data line
            let vals = line.split(separator: " ").compactMap { Float($0) }
            if vals.count == 3 { table.append(contentsOf: vals) }
        }
    }

    guard size > 0 else { throw CubeParseError.missingSizeDeclaration }
    guard table.count == size * size * size * 3 else {
        throw CubeParseError.tableSizeMismatch(expected: size*size*size*3,
                                                got: table.count)
    }

    // .cube files store data in B-fastest order (r=slowest), which matches
    // the R-major layout expected by LUT3D.lookup.
    return LUT3D(size: size, domainMin: domMin, domainMax: domMax, table: table)
}

private func parseFloatTriple(_ line: String) -> [Float] {
    let parts = line.split(separator: " ").dropFirst()
    return parts.compactMap { Float($0) }
}

public enum CubeParseError: Error {
    case unsupported1DLUT
    case missingSizeDeclaration
    case tableSizeMismatch(expected: Int, got: Int)
}

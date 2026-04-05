import Foundation
import CoreImage
import ImageIO
import CoreGraphics

// MARK: - JSON Output

struct ConvertResult: Encodable {
    let success: Bool
    var output: String?
    var size_bytes: Int64?
    var width: Int?
    var height: Int?
    var error: String?
    var hint: String?
    var elapsed_ms: Int64?
}

func outputJSON(_ result: ConvertResult) {
    let enc = JSONEncoder()
    if let data = try? enc.encode(result), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

func fail(_ msg: String, hint: String? = nil) -> Never {
    outputJSON(ConvertResult(success: false, error: msg, hint: hint))
    exit(1)
}

let startTime = DispatchTime.now()

// MARK: - Argument Parsing

let args = CommandLine.arguments
guard args.count >= 3 else {
    fail("Usage: heic-convert <input> <output> [--quality 0.85] [--headroom 4.0]")
}

let inputPath = args[1]
let outputPath = args[2]
var quality: Double = 0.85
var headroom: Double = 4.0

var argIdx = 3
while argIdx < args.count {
    if args[argIdx] == "--quality", argIdx + 1 < args.count {
        quality = Double(args[argIdx + 1]) ?? 0.85
        argIdx += 2
    } else if args[argIdx] == "--headroom", argIdx + 1 < args.count {
        headroom = Double(args[argIdx + 1]) ?? 4.0
        argIdx += 2
    } else {
        argIdx += 1
    }
}

quality = min(max(quality, 0.0), 1.0)
headroom = min(max(headroom, 1.0), 16.0)

// MARK: - Load Image

let inputURL = URL(fileURLWithPath: inputPath)
let outputURL = URL(fileURLWithPath: outputPath)

guard let imgSource = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(imgSource, 0, nil) else {
    fail("Failed to load image", hint: "File may be corrupted or in an unsupported format. Try JPEG, PNG, or TIFF.")
}

let srcProps = CGImageSourceCopyPropertiesAtIndex(imgSource, 0, nil) as? [String: Any]
let exifOrientation = srcProps?[kCGImagePropertyOrientation as String] as? UInt32 ?? 1

var ciImage = CIImage(cgImage: cgImage)
if let orient = CGImagePropertyOrientation(rawValue: exifOrientation) {
    ciImage = ciImage.oriented(orient)
}

let w = Int(ciImage.extent.width)
let h = Int(ciImage.extent.height)
let pixelCount = w * h
let extent = ciImage.extent

// MARK: - Setup CIContext in Extended Linear P3

guard let workingCS = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
    fail("Color space not available", hint: "Extended linear Display P3 requires macOS 14+.")
}
guard let outCS = CGColorSpace(name: CGColorSpace.displayP3) else {
    fail("Color space not available", hint: "Display P3 requires macOS 14+.")
}

let ctx = CIContext(options: [
    .workingColorSpace: workingCS,
    .highQualityDownsample: true
])

// MARK: - Render to Float Buffer for Gain Map Computation

let kR: Float = 0.2126, kG: Float = 0.7152, kB: Float = 0.0722
let logH = Float(log2(headroom))
let eps: Float = 1.0 / 65536.0

var pixels = [Float](repeating: 0, count: pixelCount * 4)
let bytesPerRow = w * 4 * MemoryLayout<Float>.size
ctx.render(ciImage, toBitmap: &pixels, rowBytes: bytesPerRow, bounds: extent,
           format: .RGBAf, colorSpace: workingCS)

// Single pass: find maxLum and speculatively compute HDR gain map
var maxLum: Float = 0
var gainMapVals = [UInt8](repeating: 0, count: pixelCount)

for i in 0..<pixelCount {
    let off = i * 4
    let r = max(pixels[off], 0)
    let g = max(pixels[off + 1], 0)
    let b = max(pixels[off + 2], 0)
    let lum = kR * r + kG * g + kB * b
    if lum > maxLum { maxLum = lum }

    let sdrLum = min(lum, 1.0)
    let gain = sdrLum > eps ? log2(max(lum, eps) / sdrLum) / logH : 0
    gainMapVals[i] = UInt8(min(max(gain, 0), 1) * 255)
}

// If content is SDR, recompute with synthetic boost formula
if maxLum <= 1.05 {
    let boostFactor = logH / 2.0  // normalize so headroom=4.0 gives original behavior
    for i in 0..<pixelCount {
        let off = i * 4
        let lum = kR * max(pixels[off], 0) + kG * max(pixels[off + 1], 0) + kB * max(pixels[off + 2], 0)
        let gain = lum * lum * boostFactor
        gainMapVals[i] = UInt8(min(max(gain, 0), 1) * 255)
    }
}

// MARK: - Create Gain Map CIImage

// CIImage(bitmapData:) uses bottom-left origin, same as CIContext render — no flip needed
let gmData = gainMapVals.withUnsafeBytes { Data($0) }
let gmCI = CIImage(bitmapData: gmData, bytesPerRow: w,
                   size: CGSize(width: w, height: h),
                   format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray))

// MARK: - Create SDR Base Image

let sdrCI = ciImage.applyingFilter("CIColorClamp", parameters: [
    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
])

// MARK: - Write HEIC with Gain Map
//
// Strategy: CIContext.heifRepresentation generates gain map auxiliary data in the
// correct internal format. We read that back, then re-encode the primary image
// with CGImageDestination for user-controlled quality.

guard let heifBuf = ctx.heifRepresentation(of: sdrCI, format: .RGBA8,
                                            colorSpace: outCS,
                                            options: [.hdrGainMapImage: gmCI]) else {
    fail("Failed to generate HEIF with gain map", hint: "The image may be too large or have an unsupported pixel format. Try a smaller image.")
}

guard let tempSrc = CGImageSourceCreateWithData(heifBuf as CFData, nil),
      let gmAux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(tempSrc, 0,
                    kCGImageAuxiliaryDataTypeHDRGainMap) else {
    fail("Failed to extract gain map data", hint: "Internal encoding error. Try a different image or lower quality setting.")
}

guard let sdrCGImage = ctx.createCGImage(sdrCI, from: extent, format: .RGBA8,
                                          colorSpace: outCS) else {
    fail("Failed to render SDR base image", hint: "The image may be too large for available memory. Try a smaller image.")
}

guard let dest = CGImageDestinationCreateWithURL(
    outputURL as CFURL, "public.heic" as CFString, 1, nil
) else {
    fail("Cannot create output file", hint: "Check that the output directory exists and is writable.")
}

CGImageDestinationAddImage(dest, sdrCGImage, [
    kCGImageDestinationLossyCompressionQuality: quality
] as CFDictionary)

CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeHDRGainMap, gmAux)

guard CGImageDestinationFinalize(dest) else {
    fail("Failed to write HEIC output", hint: "Encoding failed. Try lowering quality or using a smaller image.")
}

// MARK: - Report Result

let fm = FileManager.default
guard let attrs = try? fm.attributesOfItem(atPath: outputPath),
      let size = attrs[.size] as? Int64 else {
    fail("File written but cannot read back", hint: "The output file may have been deleted or moved.")
}

let elapsed = Int64(Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)
outputJSON(ConvertResult(success: true, output: outputPath, size_bytes: size, width: w, height: h, elapsed_ms: elapsed))

import Foundation
import Vision
import ImageIO

// Manual-entry simulator fallback: decode the native displayed QR screenshot,
// not a debug payload. The ephemeral invitation is written to an owned file.
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let source = CGImageSourceCreateWithURL(input as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let request = VNDetectBarcodesRequest()
request.symbologies = [.qr]
try VNImageRequestHandler(cgImage: image).perform([request])
guard let payload = request.results?.first?.payloadStringValue else {
    fatalError("No QR payload in native screen capture")
}
try payload.write(to: output, atomically: true, encoding: .utf8)
print("Decoded native displayed QR for manual-entry simulator fallback")

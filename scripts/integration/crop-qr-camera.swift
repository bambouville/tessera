import Foundation
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// Preserve captured QR pixels, including their rotation. Never substitute a
// logged payload or re-encode it: the Android camera must decode the UI image.
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let source = CGImageSourceCreateWithURL(input as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let request = VNDetectBarcodesRequest()
request.symbologies = [.qr]
try VNImageRequestHandler(cgImage: image).perform([request])
guard let qr = request.results?.first else { fatalError("No captured QR found") }
let bitmap = CIImage(cgImage: image)
let bounds = qr.boundingBox
let rect = CGRect(x: bounds.minX * CGFloat(image.width), y: bounds.minY * CGFloat(image.height),
                  width: bounds.width * CGFloat(image.width), height: bounds.height * CGFloat(image.height))
    .insetBy(dx: -24, dy: -24).integral.intersection(bitmap.extent)
let crop = bitmap.cropped(to: rect).transformed(by: .init(translationX: -rect.minX, y: -rect.minY))
    .samplingNearest().transformed(by: .init(scaleX: 2, y: 2))
// The imagefile scene applies a camera viewport transform, not a direct frame
// copy. Leave space around captured pixels and calibrate their vertical
// placement against an actual analyzer-frame capture from the owned emulator.
let canvas = CGRect(x: 0, y: 0, width: 2560, height: 1920)
let position = crop.transformed(by: .init(translationX: (canvas.width - crop.extent.width) / 2 - 560,
                                         y: (canvas.height - crop.extent.height) / 2))
let result = position.composited(over: CIImage(color: .white).cropped(to: canvas))
let cg = CIContext().createCGImage(result, from: canvas)!
// Atomic publication lets the disposable-device owner wait for a complete PNG.
let data = NSMutableData()
let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, cg, nil)
precondition(CGImageDestinationFinalize(destination))
try (data as Data).write(to: output, options: .atomic)
print("Published captured QR pixels on a calibrated 2560 x 1920 camera canvas")

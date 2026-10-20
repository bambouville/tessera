import Foundation
import Vision
import ImageIO

// Decode the rendered pixels, not a logged offer or coordinator shortcut.
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let request = VNDetectBarcodesRequest()
request.symbologies = [.qr]
try VNImageRequestHandler(url: url).perform([request])
guard let value = request.results?.first?.payloadStringValue else {
    fatalError("No QR code found in the captured device screen")
}
print(value)

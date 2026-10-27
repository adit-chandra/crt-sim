// Renders a single frame of a video (or a still image) through the CRT pipeline
// to a PNG. Handy for tuning shaders without running the app.

import AVFoundation
import CRTCore
import Foundation
import ImageIO
import MetalKit
import UniformTypeIdentifiers

let usage = """
    usage: crt-snapshot <video-or-image> <output.png> [options]
      --time <seconds>    frame to grab from a video (default 1)
      --preset <id>       \(CRTPreset.all.map(\.id).joined(separator: ", "))
      --width <px>        output width (default 1600)
      --height <px>       output height (default: match picture aspect)
      --scale <n>         backing scale to simulate for the phosphor mask (default 2)
      --off               bypass the CRT effect
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var positional: [String] = []
var options: [String: String] = [:]
var arguments = CommandLine.arguments.dropFirst()
while let arg = arguments.popFirst() {
    if arg == "--off" {
        options["off"] = "1"
    } else if arg.hasPrefix("--") {
        guard let value = arguments.popFirst() else { fail(usage) }
        options[String(arg.dropFirst(2))] = value
    } else {
        positional.append(arg)
    }
}
guard positional.count == 2 else { fail(usage) }
let inputURL = URL(fileURLWithPath: positional[0])
let outputURL = URL(fileURLWithPath: positional[1])

func loadFrame() async throws -> CGImage {
    if let type = UTType(filenameExtension: inputURL.pathExtension), type.conforms(to: .image) {
        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fail("could not read image \(inputURL.path)")
        }
        return image
    }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: inputURL))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let seconds = Double(options["time"] ?? "1") ?? 1
    return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
}

do {
    guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
    let frame = try await loadFrame()
    let texture = try MTKTextureLoader(device: device).newTexture(
        cgImage: frame, options: [.SRGB: false])

    let renderer = try CRTRenderer(device: device)
    if let id = options["preset"] {
        guard let preset = CRTPreset.named(id) else { fail("unknown preset \(id)\n\(usage)") }
        renderer.settings = preset.settings
    }
    renderer.isEnabled = options["off"] == nil
    renderer.displayAspect = Double(frame.width) / Double(frame.height)
    renderer.setSource(texture: texture)

    let width = Int(options["width"] ?? "1600") ?? 1600
    let height = Int(options["height"] ?? "") ?? Int((Double(width) / renderer.displayAspect).rounded())
    let scale = Double(options["scale"] ?? "2") ?? 2
    guard let image = renderer.renderImage(width: width, height: height, contentsScale: scale) else {
        fail("render failed")
    }
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("could not write \(outputURL.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(outputURL.path)") }
    print("wrote \(outputURL.path) (\(width)x\(height))")
} catch {
    fail("error: \(error)")
}

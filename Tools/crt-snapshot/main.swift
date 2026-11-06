// Renders a single frame of a video (or a still image) through the CRT pipeline
// to a PNG. Handy for tuning shaders without running the app.

import AVFoundation
import CoreImage
import CRTCore
import Foundation
import ImageIO
import MetalKit
import UniformTypeIdentifiers

let usage = """
    usage: crt-snapshot <video-or-image> <output.png> [options]
      --time <seconds>    frame to grab from a video (default 1)
      --preset <id>       \(CRTPreset.all.map(\.id).joined(separator: ", "))
      --signal <name>     override the preset's signal: rgb, svideo, composite, rf
      --width <px>        output width (default 1600)
      --height <px>       output height (default: match picture aspect)
      --scale <n>         backing scale to simulate for the phosphor mask (default 2)
      --off               bypass the CRT effect
      --transition <name> render mid-transition: on, off, static
      --at <seconds>      time into the transition (default 0.1)
      --glass <image>     preview glass-pane mode over a blurred, frosted backdrop
      --transparency <n>  glass-pane transparency, 0...1 (default 0.4)
      --glass-brightness <n>  glass lightness, 0 smoked ... 1 frosted (default 0.45)
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

/// Approximates the window server's smoked glass: the backdrop blurred and
/// darkened, with the premultiplied picture composited over it in linear light.
/// Matches the black tint the app puts on its glass pane.
let glassTint = 0.75 * (1 - (Double(options["glass-brightness"] ?? "0.45") ?? 0.45))

func composite(_ picture: CGImage, overGlass backdropPath: String) throws -> CGImage {
    let size = CGSize(width: picture.width, height: picture.height)
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: backdropPath) as CFURL, nil),
          let backdrop = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("could not read \(backdropPath)")
    }
    let input = CIImage(cgImage: backdrop)
    let fill = max(size.width / input.extent.width, size.height / input.extent.height)
    let blurred = input.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        .clampedToExtent()
        .applyingGaussianBlur(sigma: 30)
        .cropped(to: CGRect(origin: .zero, size: size))
    let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let floatInfo: CGBitmapInfo = [
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        .floatComponents, .byteOrder16Little,
    ]
    guard let glass = CIContext().createCGImage(blurred, from: blurred.extent),
          let context = CGContext(
              data: nil, width: picture.width, height: picture.height, bitsPerComponent: 16,
              bytesPerRow: 0, space: linear, bitmapInfo: floatInfo.rawValue),
          let output = CGContext(
              data: nil, width: picture.width, height: picture.height, bitsPerComponent: 8,
              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                  | CGBitmapInfo.byteOrder32Little.rawValue) else { fail("could not composite") }
    let bounds = CGRect(origin: .zero, size: size)
    context.draw(glass, in: bounds)
    context.setFillColor(CGColor(colorSpace: linear, components: [0, 0, 0, glassTint])!)
    context.fill(bounds)
    context.draw(picture, in: bounds)
    guard let composited = context.makeImage() else { fail("could not composite") }
    output.draw(composited, in: bounds)
    guard let result = output.makeImage() else { fail("could not composite") }
    return result
}

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

    // Glass previews composite in linear light like the window server, so render float.
    let renderer = try CRTRenderer(
        device: device, outputPixelFormat: options["glass"] != nil ? .rgba16Float : .bgra8Unorm)
    if let id = options["preset"] {
        guard let preset = CRTPreset.named(id) else { fail("unknown preset \(id)\n\(usage)") }
        renderer.settings = preset.settings
    }
    if let name = options["signal"] {
        let signals: [String: CRTSettings.Signal] = [
            "rgb": .rgb, "svideo": .sVideo, "composite": .composite, "rf": .rf,
        ]
        guard let signal = signals[name] else { fail("unknown signal \(name)\n\(usage)") }
        renderer.settings.signal = signal
    }
    renderer.isEnabled = options["off"] == nil
    renderer.glassMode = options["glass"] != nil
    renderer.glassTransparency = Double(options["transparency"] ?? "0.4") ?? 0.4
    renderer.displayAspect = Double(frame.width) / Double(frame.height)
    renderer.setSource(texture: texture)

    let width = Int(options["width"] ?? "1600") ?? 1600
    let height = Int(options["height"] ?? "") ?? Int((Double(width) / renderer.displayAspect).rounded())
    let scale = Double(options["scale"] ?? "2") ?? 2
    var time = CACurrentMediaTime()
    if let name = options["transition"] {
        let transitions: [String: CRTRenderer.Transition] = [
            "on": .powerOn, "off": .powerOff, "static": .channelChange,
        ]
        guard let transition = transitions[name] else { fail("unknown transition \(name)\n\(usage)") }
        renderer.play(transition, at: time)
        time += Double(options["at"] ?? "0.1") ?? 0.1
    }
    guard let image = renderer.renderImage(width: width, height: height, contentsScale: scale,
                                           time: time) else {
        fail("render failed")
    }
    let output = try options["glass"].map { try composite(image, overGlass: $0) } ?? image
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("could not write \(outputURL.path)")
    }
    CGImageDestinationAddImage(destination, output, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(outputURL.path)") }
    print("wrote \(outputURL.path) (\(width)x\(height))")
} catch {
    fail("error: \(error)")
}

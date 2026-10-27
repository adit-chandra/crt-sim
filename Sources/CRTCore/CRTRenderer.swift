import CoreGraphics
import CoreVideo
import Metal
import MetalKit
import QuartzCore

public enum CRTRendererError: Error {
    case noCommandQueue
    case missingFunction(String)
}

/// Mirrors `Uniforms` in CRTShaders.swift — field order and types must match.
private struct CRTUniforms {
    var outputW: Float = 0
    var outputH: Float = 0
    var tubeX: Float = 0
    var tubeY: Float = 0
    var tubeW: Float = 0
    var tubeH: Float = 0
    var signalW: Float = 0
    var signalH: Float = 0
    var time: Float = 0
    var hasSignal: Float = 0
    var rotation: Float = 0
    var curvature: Float = 0
    var scanlines: Float = 0
    var sharpness: Float = 0
    var colorBleed: Float = 0
    var saturation: Float = 1
    var maskType: Float = 0
    var maskStrength: Float = 0
    var maskScale: Float = 1
    var glow: Float = 0
    var convergence: Float = 0
    var noise: Float = 0
    var vignette: Float = 0
    var brightness: Float = 1
    var persistDecay: Float = 0
    var mono: Float = 0
    var monoR: Float = 1
    var monoG: Float = 1
    var monoB: Float = 1
}

/// Keeps a CoreVideo-backed texture alive until the GPU is done with it.
private final class GPURetainer: @unchecked Sendable {
    let object: AnyObject
    init(_ object: AnyObject) { self.object = object }
}

private struct Pipelines {
    let signal: MTLRenderPipelineState
    let persist: MTLRenderPipelineState
    let bloomDown: MTLRenderPipelineState
    let blur: MTLRenderPipelineState
    let crt: MTLRenderPipelineState
    let passthrough: MTLRenderPipelineState
}

/// Renders video frames through a CRT simulation. Drive it either as an
/// `MTKViewDelegate` or offscreen via `renderImage(width:height:)`.
@MainActor
public final class CRTRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let outputFormat: MTLPixelFormat
    private let pipelines: Pipelines
    private let blackTexture: MTLTexture
    private var textureCache: CVMetalTextureCache?

    public var settings = CRTSettings.default {
        didSet { if settings != oldValue { signalDirty = true } }
    }
    public var isEnabled = true
    /// Quarter turns clockwise needed to display the source upright.
    public var rotation = 0 {
        didSet { if rotation != oldValue { signalDirty = true } }
    }
    /// Width / height of the picture as displayed (after rotation).
    public var displayAspect: Double = 16.0 / 9.0
    /// Called at the start of every frame an `MTKView` asks for.
    public var willDraw: (@MainActor (CRTRenderer) -> Void)?

    private var source: MTLTexture?
    private var sourceOwner: CVMetalTexture?
    private var signalTexture: MTLTexture?
    private var persistTextures: [MTLTexture] = []
    private var bloomTextures: [MTLTexture] = []
    private var persistIndex = 0
    private var signalDirty = true
    private var needsClear = true
    private var lastFrameTime: CFTimeInterval?
    private let epoch = CACurrentMediaTime()

    private static var pipelineCache: [String: Pipelines] = [:]

    public init(device: MTLDevice, outputPixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        guard let queue = device.makeCommandQueue() else { throw CRTRendererError.noCommandQueue }
        self.device = device
        self.commandQueue = queue
        self.outputFormat = outputPixelFormat
        self.pipelines = try Self.pipelines(device: device, outputFormat: outputPixelFormat)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        let black = device.makeTexture(descriptor: desc)!
        black.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                      withBytes: [UInt8](arrayLiteral: 0, 0, 0, 255), bytesPerRow: 4)
        self.blackTexture = black
        super.init()
    }

    // MARK: - Source

    public var hasSource: Bool { source != nil }

    public func setSource(pixelBuffer: CVPixelBuffer) {
        if textureCache == nil {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
        guard let textureCache else { return }
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return }
        source = texture
        sourceOwner = cvTexture
        signalDirty = true
    }

    public func setSource(texture: MTLTexture) {
        source = texture
        sourceOwner = nil
        signalDirty = true
    }

    public func clearSource() {
        source = nil
        sourceOwner = nil
        signalDirty = true
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        willDraw?(self)
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let scale = view.bounds.width > 0 ? view.drawableSize.width / view.bounds.width : 2
        encode(into: commandBuffer, target: drawable.texture, contentsScale: scale,
               time: CACurrentMediaTime())
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Offscreen

    /// Renders one frame synchronously. `contentsScale` sizes the phosphor mask
    /// as it would appear on a display with that backing scale.
    public func renderImage(width: Int, height: Int, contentsScale: Double = 2,
                            time: CFTimeInterval = 1) -> CGImage? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: outputFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let target = device.makeTexture(descriptor: desc),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        encode(into: commandBuffer, target: target, contentsScale: contentsScale, time: epoch + time)
        if target.storageMode == .managed, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        target.getBytes(&bytes, bytesPerRow: bytesPerRow,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Encoding

    public func encode(into commandBuffer: MTLCommandBuffer, target: MTLTexture,
                       contentsScale: Double, time: CFTimeInterval) {
        let dt = lastFrameTime.map { min(max(time - $0, 0), 0.1) } ?? 0
        lastFrameTime = time

        let outW = Double(target.width)
        let outH = Double(target.height)
        let aspect = max(displayAspect, 0.1)
        var tubeW = outW
        var tubeH = outW / aspect
        if tubeH > outH {
            tubeH = outH
            tubeW = outH * aspect
        }
        tubeW = tubeW.rounded()
        tubeH = tubeH.rounded()

        let s = settings
        var u = CRTUniforms()
        u.outputW = Float(outW)
        u.outputH = Float(outH)
        u.tubeX = Float(((outW - tubeW) / 2).rounded())
        u.tubeY = Float(((outH - tubeH) / 2).rounded())
        u.tubeW = Float(tubeW)
        u.tubeH = Float(tubeH)
        u.time = Float((time - epoch).truncatingRemainder(dividingBy: 3600))
        u.hasSignal = source == nil ? 0 : 1
        u.rotation = Float(rotation & 3)

        let sourceTexture = source ?? blackTexture
        if let sourceOwner {
            let retainer = GPURetainer(sourceOwner)
            commandBuffer.addCompletedHandler { _ in withExtendedLifetime(retainer) {} }
        }

        guard isEnabled else {
            pass(commandBuffer, target: target, pipeline: pipelines.passthrough,
                 textures: [sourceTexture], uniforms: &u)
            signalDirty = true
            return
        }

        ensureTextures(lines: Int(s.lines.rounded()), aspect: aspect)
        guard let signalTexture else { return }
        if needsClear {
            for texture in persistTextures + bloomTextures { clear(commandBuffer, texture) }
            needsClear = false
        }

        u.signalW = Float(signalTexture.width)
        u.signalH = Float(signalTexture.height)
        u.curvature = Float(s.curvature)
        u.scanlines = Float(s.scanlines)
        u.sharpness = Float(s.sharpness)
        u.colorBleed = Float(s.colorBleed)
        u.saturation = Float(s.saturation)
        u.maskType = Float(s.maskType.rawValue)
        u.maskStrength = Float(s.maskStrength)
        u.maskScale = Float(max(1, (s.maskSize * contentsScale).rounded()))
        u.glow = Float(s.glow)
        u.convergence = Float(s.convergence)
        u.noise = Float(s.noise)
        u.vignette = Float(s.vignette)
        u.brightness = Float(s.brightness)
        let tau = s.persistence * 0.15
        u.persistDecay = tau > 0 ? Float(exp(-dt / tau)) : 0
        if let tint = s.phosphor.tint {
            u.mono = 1
            u.monoR = tint.x
            u.monoG = tint.y
            u.monoB = tint.z
        }

        if signalDirty || source == nil {
            pass(commandBuffer, target: signalTexture, pipeline: pipelines.signal,
                 textures: [sourceTexture], uniforms: &u)
            signalDirty = false
        }

        let previous = persistTextures[persistIndex]
        persistIndex ^= 1
        let persist = persistTextures[persistIndex]
        pass(commandBuffer, target: persist, pipeline: pipelines.persist,
             textures: [signalTexture, previous], uniforms: &u)

        // Bloom radius as a fraction of tube height, made isotropic on screen.
        let radius = Float(0.012 + 0.014 * s.glow)
        pass(commandBuffer, target: bloomTextures[0], pipeline: pipelines.bloomDown,
             textures: [persist], uniforms: &u)
        pass(commandBuffer, target: bloomTextures[1], pipeline: pipelines.blur,
             textures: [bloomTextures[0]], uniforms: &u,
             sigma: SIMD2(radius / Float(aspect), 0))
        pass(commandBuffer, target: bloomTextures[0], pipeline: pipelines.blur,
             textures: [bloomTextures[1]], uniforms: &u, sigma: SIMD2(0, radius))

        pass(commandBuffer, target: target, pipeline: pipelines.crt,
             textures: [persist, bloomTextures[0]], uniforms: &u)
    }

    private func ensureTextures(lines requested: Int, aspect: Double) {
        let lines = min(max(requested, 60), 1200)
        let width = max(16, Int((2 * Double(lines) * aspect).rounded()))
        if signalTexture?.width != width || signalTexture?.height != lines {
            signalTexture = makeTarget(width, lines)
            persistTextures = [makeTarget(width, lines), makeTarget(width, lines)]
            signalDirty = true
            needsClear = true
        }
        let bloomH = 180
        let bloomW = max(8, Int((Double(bloomH) * aspect).rounded()))
        if bloomTextures.first?.width != bloomW {
            bloomTextures = [makeTarget(bloomW, bloomH), makeTarget(bloomW, bloomH)]
            needsClear = true
        }
    }

    private func makeTarget(_ width: Int, _ height: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)!
    }

    private func clear(_ commandBuffer: MTLCommandBuffer, _ texture: MTLTexture) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        commandBuffer.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
    }

    private func pass(_ commandBuffer: MTLCommandBuffer, target: MTLTexture,
                      pipeline: MTLRenderPipelineState, textures: [MTLTexture],
                      uniforms: inout CRTUniforms, sigma: SIMD2<Float> = .zero) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encoder.setRenderPipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CRTUniforms>.stride, index: 0)
        var sigma = sigma
        encoder.setFragmentBytes(&sigma, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: - Pipelines

    private static func pipelines(device: MTLDevice, outputFormat: MTLPixelFormat) throws -> Pipelines {
        let key = "\(device.registryID)-\(outputFormat.rawValue)"
        if let cached = pipelineCache[key] { return cached }

        let library = try device.makeLibrary(source: CRTShaders.source, options: nil)
        guard let vertex = library.makeFunction(name: "fullscreen_vertex") else {
            throw CRTRendererError.missingFunction("fullscreen_vertex")
        }
        func make(_ name: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            guard let fragment = library.makeFunction(name: name) else {
                throw CRTRendererError.missingFunction(name)
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.label = name
            desc.vertexFunction = vertex
            desc.fragmentFunction = fragment
            desc.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        let pipelines = Pipelines(
            signal: try make("signal_fragment", .rgba16Float),
            persist: try make("persist_fragment", .rgba16Float),
            bloomDown: try make("bloom_down_fragment", .rgba16Float),
            blur: try make("blur_fragment", .rgba16Float),
            crt: try make("crt_fragment", outputFormat),
            passthrough: try make("passthrough_fragment", outputFormat))
        pipelineCache[key] = pipelines
        return pipelines
    }
}

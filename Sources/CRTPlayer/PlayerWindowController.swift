import AppKit
import CRTCore
import MetalKit
import Observation
import SwiftUI

/// One borderless-looking player window, in the spirit of QuickTime Player: video
/// edge to edge, title bar and floating controls that fade out while playing.
final class PlayerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// The video on screen; nil while the window is an empty screen.
    private var model: PlayerModel?
    private let store = CRTSettingsStore.shared
    private let chrome = ChromeState()
    private let renderer: CRTRenderer
    private let contentView = PlayerContentView()
    /// In glass-pane mode the window's root view: smoked glass behind `contentView`.
    /// The glass is a sibling rather than a container so the picture itself never
    /// gets the glass treatment.
    private let glassRoot = NSView()
    private let glassView = NSGlassEffectView()
    private let metalView: CRTMetalView
    private let titleShade = TitleShadeView()
    private let controlsHost = NSHostingView<ControlBar?>(rootView: nil)
    private let osdHost: PassiveHostingView<OSDView>

    private var chromeVisible = true
    private var pointerInside = false
    private var pendingShow = false
    private var isPoweringOff = false
    private var closeAfterPowerOff = false
    private var hideTask: Task<Void, Never>?
    private var osdTask: Task<Void, Never>?
    private var observationTasks: [Task<Void, Never>] = []
    private var modelTasks: [Task<Void, Never>] = []
    private var keyMonitor: Any?

    private static let skipInterval: Double = 10

    /// The window showing nothing yet, if one is open. The next video opened plays in it.
    private static var emptyScreen: PlayerWindowController?

    /// Shows a window with the tube on and nothing playing.
    static func showEmptyScreen() {
        let controller = emptyScreen ?? PlayerWindowController(model: nil)
        emptyScreen = controller
        controller.showWindow(nil)
    }

    /// A window for `model`: the empty screen if one is open, otherwise a new window.
    static func playing(_ model: PlayerModel) -> PlayerWindowController {
        guard let screen = emptyScreen, !screen.isPoweringOff else { return PlayerWindowController(model: model) }
        emptyScreen = nil
        screen.play(model)
        return screen
    }

    private init(model: PlayerModel?) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("CRT Player requires a Metal-capable GPU.")
        }
        do {
            renderer = try CRTRenderer(device: device, outputPixelFormat: .rgba16Float)
        } catch {
            fatalError("Could not build the CRT pipeline: \(error)")
        }
        metalView = CRTMetalView(frame: .zero, device: device)
        osdHost = PassiveHostingView(rootView: OSDView(chrome: chrome))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)

        configure(window)
        layoutViews()
        configureRenderer()
        setGlassPane(store.glassPane)
        updateWindowLevel()
        observeState()
        if let model {
            play(model)
        } else {
            window.title = "CRT Player"
            renderer.setBlankSource()
            renderer.isEnabled = store.isEnabled
            renderer.play(.powerOn)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func configure(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 360, height: 200)
        window.contentView = contentView
        window.delegate = self
        window.center()

        contentView.onPointerActivity = { [weak self] in self?.pointerMoved() }
        contentView.onPointerExit = { [weak self] in self?.pointerExited() }
        contentView.onDropURLs = { urls in
            for url in urls {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func layoutViews() {
        // Linear extended-range output lets lit phosphors go brighter than SDR
        // white on EDR displays, so the mask and scanlines don't dim the picture.
        metalView.colorPixelFormat = .rgba16Float
        metalView.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        (metalView.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = 60

        controlsHost.sizingOptions = [.intrinsicContentSize]
        osdHost.sizingOptions = [.intrinsicContentSize]

        for view in [metalView, titleShade, osdHost, controlsHost] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        let preferredWidth = controlsHost.widthAnchor.constraint(equalToConstant: 500)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            metalView.topAnchor.constraint(equalTo: contentView.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            titleShade.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleShade.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titleShade.topAnchor.constraint(equalTo: contentView.topAnchor),
            titleShade.heightAnchor.constraint(equalToConstant: 64),

            osdHost.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 44),
            osdHost.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),

            controlsHost.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            controlsHost.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            controlsHost.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -32),
            preferredWidth,
        ])
    }

    private func configureRenderer() {
        renderer.willDraw = { [weak self] renderer in
            guard let self else { return }
            renderer.settings = store.settings
            renderer.isEnabled = store.isEnabled
            renderer.headroom = (metalView.window?.screen?.maximumExtendedDynamicRangeColorComponentValue).map(Double.init) ?? 1
            renderer.glassTransparency = store.glassTransparency
            guard let model else { return }
            renderer.rotation = model.rotation
            if let size = model.videoSize, size.width > 0, size.height > 0 {
                renderer.displayAspect = size.width / size.height
            }
            if let pixelBuffer = model.copyNewPixelBuffer() {
                renderer.setSource(pixelBuffer: pixelBuffer)
            }
        }
        metalView.delegate = renderer
    }

    /// Starts showing `model`; an empty screen changes channel to it.
    private func play(_ model: PlayerModel) {
        self.model = model
        controlsHost.rootView = ControlBar(model: model, chrome: chrome, store: store)
        modelTasks = [
            Task { [weak self] in
                for await loaded in Observations({ model.isLoaded }) where loaded {
                    self?.didLoad(model)
                }
            },
            Task { [weak self] in
                for await error in Observations({ model.loadError.map { $0 as NSError } }) {
                    if let error { self?.presentLoadError(error) }
                }
            },
            Task { [weak self] in
                for await _ in Observations({ model.isPlaying }) {
                    self?.playbackStateChanged()
                }
            },
        ]
    }

    private func observeState() {
        let chrome = chrome
        observationTasks = [
            Task { [weak self] in
                for await showing in Observations({ chrome.showsSettings }) where !showing {
                    self?.scheduleHide()
                }
            },
            Task { [weak self, store] in
                for await glassPane in Observations({ store.glassPane }) {
                    self?.setGlassPane(glassPane)
                }
            },
            Task { [weak self, store] in
                for await _ in Observations({ store.glassBrightness }) {
                    self?.updateGlassTint()
                }
            },
            Task { [weak self, store] in
                for await _ in Observations({ store.floatsOnTop }) {
                    self?.updateWindowLevel()
                }
            },
            Task { [weak self, store] in
                var lastSeen = store.announcement?.id ?? 0
                for await announcement in Observations({ store.announcement }) {
                    guard let self else { return }
                    guard let announcement, announcement.id > lastSeen else { continue }
                    lastSeen = announcement.id
                    if store.isEnabled { renderer.play(.channelChange) }
                    showOSD(announcement.text)
                }
            },
        ]
    }

    // MARK: - Glass pane

    /// Swaps between an opaque black window and a translucent one whose content
    /// sits on a Liquid Glass pane, with the renderer drawing the picture as light.
    private func setGlassPane(_ enabled: Bool) {
        guard let window else { return }
        renderer.glassMode = enabled
        metalView.layer?.isOpaque = !enabled
        contentView.layer?.backgroundColor = enabled ? NSColor.clear.cgColor : NSColor.black.cgColor
        window.isOpaque = !enabled
        window.backgroundColor = enabled ? .clear : .black

        let frame = window.frame
        if enabled, window.contentView !== glassRoot {
            glassView.style = .regular
            glassView.cornerRadius = 16
            updateGlassTint()
            window.contentView = glassRoot
            for view in [glassView, contentView] as [NSView] {
                view.frame = glassRoot.bounds
                view.autoresizingMask = [.width, .height]
                glassRoot.addSubview(view)
            }
        } else if !enabled, window.contentView !== contentView {
            glassView.removeFromSuperview()
            contentView.removeFromSuperview()
            window.contentView = contentView
        }
        window.setFrame(frame, display: true)
        window.invalidateShadow()
    }

    /// Darkens the glass toward smoked as brightness goes down.
    private func updateGlassTint() {
        glassView.tintColor = NSColor.black.withAlphaComponent(0.75 * (1 - store.glassBrightness))
    }

    // MARK: - Float on top

    /// Floats the window above other apps' windows. A full-screen window has its
    /// own space, so it stays at the normal level there.
    private func updateWindowLevel() {
        guard let window, !isFullScreen else { return }
        window.level = store.floatsOnTop ? .floating : .normal
    }

    // MARK: - Showing the window

    /// Holds a new video's window back until its size is known so it opens at the right shape.
    override func showWindow(_ sender: Any?) {
        guard let model, !model.isLoaded, window?.isVisible != true else {
            super.showWindow(sender)
            return
        }
        pendingShow = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.revealIfPending()
        }
    }

    private func revealIfPending() {
        guard pendingShow else { return }
        pendingShow = false
        super.showWindow(nil)
    }

    private func didLoad(_ model: PlayerModel) {
        guard model.loadError == nil else { return }
        if let size = model.videoSize {
            fitWindow(to: size, animate: !pendingShow)
        }
        renderer.isEnabled = store.isEnabled
        // A window that's about to appear powers on; one already on screen changes channel.
        if pendingShow {
            renderer.play(.powerOn)
        } else if store.isEnabled {
            renderer.play(.channelChange)
        }
        revealIfPending()
        model.player.play()
        scheduleHide()
    }

    private func fitWindow(to size: CGSize, animate: Bool) {
        guard let window, size.width > 0, size.height > 0 else { return }
        window.contentAspectRatio = size
        guard !isFullScreen, let screen = window.screen ?? NSScreen.main else { return }

        let visible = screen.visibleFrame
        let maxWidth = visible.width * 0.8
        let maxHeight = visible.height * 0.8
        var scale = min(1, maxWidth / size.width, maxHeight / size.height)
        if size.width * scale < 640 {
            // Small sources look better (and the effect reads better) a bit larger.
            scale = min(640 / size.width, maxWidth / size.width, maxHeight / size.height)
        }
        let contentSize = NSSize(width: (size.width * scale).rounded(),
                                 height: (size.height * scale).rounded())
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2,
                               y: window.frame.midY - frame.height / 2)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animate)
    }

    private func presentLoadError(_ error: Error) {
        revealIfPending()
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "“\((document as? NSDocument)?.displayName ?? "This file")” couldn’t be opened."
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window) { _ in
            window.performClose(nil)
        }
    }

    // MARK: - Auto-hiding chrome

    private var isFullScreen: Bool {
        window?.styleMask.contains(.fullScreen) ?? false
    }

    /// The title bar container, faded together with the controls.
    private var titlebarView: NSView? {
        let closeButton = window?.standardWindowButton(.closeButton)
        var candidate = closeButton?.superview
        while let view = candidate {
            if String(describing: type(of: view)) == "NSTitlebarContainerView" { return view }
            candidate = view.superview
        }
        return closeButton?.superview
    }

    private var pointerOverControls: Bool {
        guard let window, !controlsHost.isHidden else { return false }
        let point = controlsHost.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return controlsHost.bounds.contains(point)
    }

    private func pointerMoved() {
        guard !isPoweringOff else { return }
        pointerInside = true
        setChromeVisible(true)
        scheduleHide()
    }

    private func pointerExited() {
        pointerInside = false
        scheduleHide(after: .milliseconds(300))
    }

    private func playbackStateChanged() {
        guard !isPoweringOff else { return }
        if model?.isPlaying != true, pointerInside {
            setChromeVisible(true)
        }
        scheduleHide()
    }

    private func scheduleHide(after delay: Duration = .seconds(2.5)) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hideChromeIfIdle()
        }
    }

    private func hideChromeIfIdle() {
        guard !chrome.showsSettings else { return }
        if pointerInside {
            guard model?.isPlaying == true, !pointerOverControls else { return }
            if isFullScreen { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        setChromeVisible(false)
    }

    private func setChromeVisible(_ visible: Bool) {
        guard visible != chromeVisible else { return }
        chromeVisible = visible
        if visible { controlsHost.isHidden = false }
        let titlebar = isFullScreen ? nil : titlebarView
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.15 : 0.45
            controlsHost.animator().alphaValue = visible ? 1 : 0
            titleShade.animator().alphaValue = visible ? 1 : 0
            titlebar?.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.chromeVisible else { return }
                self.controlsHost.isHidden = true
            }
        }
    }

    private func flashChrome() {
        setChromeVisible(true)
        scheduleHide()
    }

    func showOSD(_ text: String) {
        chrome.osdMessage = text
        osdTask?.cancel()
        osdTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.chrome.osdMessage = nil
        }
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 49: model?.togglePlayPause()                       // space
        case 123: model?.skip(by: -Self.skipInterval)           // ←
        case 124: model?.skip(by: Self.skipInterval)            // →
        case 126: adjustVolume(by: 0.1)                         // ↑
        case 125: adjustVolume(by: -0.1)                        // ↓
        case 53 where isFullScreen: window?.toggleFullScreen(nil) // esc
        default: return false
        }
        flashChrome()
        return true
    }

    private func adjustVolume(by delta: Float) {
        guard let model else { return }
        model.volume = min(max(model.volume + delta, 0), 1)
        model.isMuted = model.volume == 0
    }

    // MARK: - Menu actions

    @objc func togglePlayPause(_ sender: Any?) {
        model?.togglePlayPause()
        flashChrome()
    }

    @objc func skipBackward(_ sender: Any?) {
        model?.skip(by: -Self.skipInterval)
        flashChrome()
    }

    @objc func skipForward(_ sender: Any?) {
        model?.skip(by: Self.skipInterval)
        flashChrome()
    }

    @objc func toggleLoop(_ sender: Any?) {
        model?.loops.toggle()
    }

    @objc func toggleCRTEffect(_ sender: Any?) {
        store.isEnabled.toggle()
    }

    @objc func applyPreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let preset = CRTPreset.named(id) else { return }
        store.apply(preset)
    }

    @objc func nextPreset(_ sender: Any?) {
        store.cyclePreset(by: 1)
    }

    @objc func previousPreset(_ sender: Any?) {
        store.cyclePreset(by: -1)
    }

    @objc func toggleGlassPane(_ sender: Any?) {
        store.glassPane.toggle()
    }

    @objc func toggleFloatOnTop(_ sender: Any?) {
        store.floatsOnTop.toggle()
    }

    @objc func showCRTSettings(_ sender: Any?) {
        setChromeVisible(true)
        chrome.showsSettings = true
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePlayPause(_:)):
            item.title = model?.isPlaying == true ? "Pause" : "Play"
            return model != nil
        case #selector(skipBackward(_:)), #selector(skipForward(_:)):
            return model != nil
        case #selector(toggleLoop(_:)):
            item.state = model?.loops == true ? .on : .off
            return model != nil
        case #selector(showCRTSettings(_:)):
            // The settings popover hangs off the control bar, which an empty screen doesn't have.
            return model != nil
        case #selector(toggleCRTEffect(_:)):
            item.state = store.isEnabled ? .on : .off
        case #selector(toggleGlassPane(_:)):
            item.state = store.glassPane ? .on : .off
        case #selector(toggleFloatOnTop(_:)):
            item.state = store.floatsOnTop ? .on : .off
        case #selector(applyPreset(_:)):
            let id = item.representedObject as? String
            item.state = store.isEnabled && store.preset?.id == id ? .on : .off
        default:
            break
        }
        return true
    }

    // MARK: - NSWindowDelegate

    /// Plays the tube's power-off before letting the window close.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeAfterPowerOff { return true }
        guard store.isEnabled, model?.loadError == nil, sender.isVisible, !sender.isMiniaturized else {
            return true
        }
        guard !isPoweringOff else { return false }
        isPoweringOff = true
        model?.player.pause()
        hideTask?.cancel()
        chrome.showsSettings = false
        setChromeVisible(false)
        renderer.play(.powerOff) { [weak self] in self?.finishClosing() }
        // The animation only advances while the view draws; don't let a hidden
        // window wait on it forever.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.finishClosing()
        }
        return false
    }

    private func finishClosing() {
        guard !closeAfterPowerOff else { return }
        closeAfterPowerOff = true
        window?.performClose(nil)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        titlebarView?.alphaValue = 1
        window?.level = .normal
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        updateWindowLevel()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        titlebarView?.alphaValue = chromeVisible ? 1 : 0
        updateWindowLevel()
    }

    func windowWillClose(_ notification: Notification) {
        metalView.isPaused = true
        metalView.delegate = nil
        renderer.willDraw = nil
        model?.invalidate()
        if Self.emptyScreen === self { Self.emptyScreen = nil }
        hideTask?.cancel()
        osdTask?.cancel()
        observationTasks.forEach { $0.cancel() }
        modelTasks.forEach { $0.cancel() }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

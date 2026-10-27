import AVKit
import UIKit

/// 一鍵 120Hz 的核心：VideoCall 畫中畫 + 1.1.1 預設內容更新鏈。
/// 按下開啟後先以 300×44pt 的長條懸浮窗啟動，didStart 後自動縮到 0.1pt。
final class PiPEngine: NSObject {
    enum State {
        case idle, starting, running, stopping
    }

    static let pipWidth: CGFloat = 300
    static let visibleHeight: CGFloat = 44
    static let hiddenHeight: CGFloat = 0.1
    private static let pipText = Array(repeating: "懸浮窗運行中", count: 10).joined(separator: "\n")

    private(set) var state: State = .idle {
        didSet { if oldValue != state { onChange?() } }
    }
    private(set) var runningSince: Date?
    private(set) var pipHeight: CGFloat = PiPEngine.visibleHeight
    var isHidden: Bool { pipHeight <= 0.15 }

    var onChange: (() -> Void)?
    var onMessage: ((String) -> Void)?

    private weak var hostView: UIView?
    private var sourceView: UIView?
    private var sourceConstraints: [NSLayoutConstraint] = []
    private var sourceWidthConstraint: NSLayoutConstraint?
    private var sourceHeightConstraint: NSLayoutConstraint?
    private var contentController: AVPictureInPictureVideoCallViewController?
    private var renderView: PiPHiddenReferenceRenderView?
    private var pipController: AVPictureInPictureController?
    private let coexistence = PiPCoexistenceExperiment()
    private let refreshDriver = RefreshDriver()
    private var sessionID: UUID?
    private var wantsActive = false
    private var hideAfterStart = false
    private var didRetryLegacyStart = false
    private var pendingStart: DispatchWorkItem?
    private var transitionWatchdog: DispatchWorkItem?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private var currentSize: CGSize { CGSize(width: Self.pipWidth, height: pipHeight) }

    /// iOS 26 以前沿用上游的舊系統相容：較多啟動重試、失敗重試一次、關閉時不移動 source view。
    private var needsLegacyCompatibility: Bool {
        if #available(iOS 19.0, *) { return false }
        return true
    }

    private var maximumStartAttempts: Int { needsLegacyCompatibility ? 36 : 8 }

    private func startRetryDelay(for attempt: Int) -> TimeInterval {
        if needsLegacyCompatibility { return attempt == 0 ? 0.05 : 0.15 }
        return attempt == 0 ? 0.02 : 0.12
    }

    init(hostView: UIView) {
        self.hostView = hostView
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(handleDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func toggle() {
        switch state {
        case .idle:
            start()
        case .running:
            stop()
        case .starting, .stopping:
            break
        }
    }

    // MARK: - 開啟 / 關閉

    private func start() {
        guard let hostView else { return }
        hideAfterStart = true
        pipHeight = Self.visibleHeight
        guard prepareIfNeeded(in: hostView) else {
            hideAfterStart = false
            return
        }
        wantsActive = true
        updateAutomaticStartPolicy()
        didRetryLegacyStart = false
        state = .starting
        beginStart()
    }

    private func beginStart() {
        scheduleTransitionWatchdog(after: 4)
        restoreVisualSurfaces()
        CATransaction.flush()
        requestStartWhenReady(attempt: 0)
    }

    private func requestStartWhenReady(attempt: Int) {
        pendingStart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .starting else { return }
            self.restoreVisualSurfaces()
            CATransaction.flush()
            guard let sourceView = self.sourceView, let controller = self.pipController else {
                self.failStart(message: nil)
                return
            }
            let sourceReady = !sourceView.bounds.isEmpty && sourceView.window != nil
            if sourceReady {
                if let token = self.sessionID {
                    PiPHiddenReferenceMode.begin(owner: token)
                }
                guard self.coexistence.prepareForStartIfRequested(controller: controller, isVideoCall: true) else {
                    self.failStart(message: "目前系統無法準備 120Hz 預設方案，已取消啟動。")
                    return
                }
            }
            if sourceReady && controller.isPictureInPicturePossible {
                self.pendingStart = nil
                controller.startPictureInPicture()
                return
            }
            if attempt < self.maximumStartAttempts {
                self.requestStartWhenReady(attempt: attempt + 1)
            } else if !self.retryLegacyStartIfNeeded() {
                self.failStart(message: "畫中畫暫時無法啟動，請稍後再試。")
            }
        }
        pendingStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + startRetryDelay(for: attempt), execute: work)
    }

    private func retryLegacyStartIfNeeded() -> Bool {
        guard needsLegacyCompatibility, !didRetryLegacyStart else { return false }
        didRetryLegacyStart = true
        pendingStart?.cancel()
        pipHeight = Self.visibleHeight
        restoreVisualSurfaces()
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.state == .starting, self.pipController?.isPictureInPictureActive != true else { return }
            self.beginStart()
        }
        pendingStart = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: retry)
        return true
    }

    private func stop() {
        guard let controller = pipController, controller.isPictureInPictureActive else { return }
        wantsActive = false
        hideAfterStart = false
        updateAutomaticStartPolicy()
        pendingStart?.cancel()
        pendingStart = nil
        state = .stopping
        scheduleTransitionWatchdog(after: 6)
        moveSourceOffscreenForClosing()
        controller.stopPictureInPicture()
    }

    private func failStart(message: String?) {
        hideAfterStart = false
        endContentSession()
        coexistence.restore()
        cancelPendingWork()
        wantsActive = false
        updateAutomaticStartPolicy()
        if pipController?.isPictureInPictureActive == true {
            state = .running
        } else {
            runningSince = nil
            endBackgroundTask()
            state = .idle
        }
        if let message { onMessage?(message) }
    }

    /// 本 App 的懸浮窗已不存在（被其他畫中畫擠掉、被系統回收等）。
    private func handleInvalidated() {
        hideAfterStart = false
        endContentSession()
        coexistence.restore()
        cancelPendingWork()
        wantsActive = false
        updateAutomaticStartPolicy()
        restoreVisualSurfaces()
        runningSince = nil
        endBackgroundTask()
        state = .idle
    }

    private func finishStarted() {
        cancelPendingWork()
        didRetryLegacyStart = false
        wantsActive = true
        updateAutomaticStartPolicy()
        applyContentAppearance()
        configureRenderView()
        if runningSince == nil { runningSince = Date() }
        if UIApplication.shared.applicationState == .background { beginBackgroundTask() }
        state = .running
        if hideAfterStart {
            hideAfterStart = false
            commitHeight(Self.hiddenHeight)
        }
    }

    private func endContentSession() {
        renderView?.stop()
        if let sessionID { PiPHiddenReferenceMode.end(owner: sessionID) }
    }

    private func cancelPendingWork() {
        pendingStart?.cancel()
        pendingStart = nil
        transitionWatchdog?.cancel()
        transitionWatchdog = nil
    }

    private func scheduleTransitionWatchdog(after delay: TimeInterval) {
        transitionWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recoverStaleTransition() }
        transitionWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 系統沒有送出 didStart / didStop 時，依懸浮窗實際狀態收尾，避免按鈕卡在「啟動中」。
    private func recoverStaleTransition() {
        guard state == .starting || state == .stopping else { return }
        transitionWatchdog = nil
        if pipController?.isPictureInPictureActive == true {
            finishStarted()
        } else {
            handleInvalidated()
        }
    }

    // MARK: - 建立畫中畫

    private func prepareIfNeeded(in hostView: UIView) -> Bool {
        if pipController != nil { return true }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            onMessage?("此裝置不支援畫中畫。")
            return false
        }
        guard PiPHiddenReferenceMode.supportsSystemMajorVersion(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) else {
            onMessage?("目前只支援 iOS 15–27。")
            return false
        }

        sessionID = UUID()
        setupSourceView(in: hostView)
        releaseMediaAudioSession()

        let content = AVPictureInPictureVideoCallViewController()
        content.preferredContentSize = currentSize
        content.view.backgroundColor = .clear
        content.view.isOpaque = false
        content.view.layer.backgroundColor = UIColor.clear.cgColor
        content.view.layer.isOpaque = false
        content.view.clipsToBounds = true
        content.view.frame = CGRect(origin: .zero, size: currentSize)
        contentController = content
        applyContentAppearance()
        configureRenderView()

        guard let sourceView else {
            teardown()
            return false
        }
        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: content
        )
        guard let controller = PiPHiddenReferenceControls.makeController(source: contentSource),
              coexistence.prepareHiddenReference(controller: controller) else {
            teardown()
            onMessage?("目前系統無法準備 120Hz 預設方案（系統內部介面不相符），已取消啟動。")
            return false
        }
        controller.delegate = self
        // 上游自 1.0.9 起沿用：iOS 16+ 用 2，避免 0.1pt 時螢幕上出現兩個白點；iOS 15 用 1。
        if #available(iOS 16.0, *) {
            controller.setValue(2, forKey: "controlsStyle")
        } else {
            controller.setValue(1, forKey: "controlsStyle")
        }
        controller.requiresLinearPlayback = true
        pipController = controller
        updateAutomaticStartPolicy()
        return true
    }

    private func teardown() {
        endContentSession()
        coexistence.restore()
        pipController?.delegate = nil
        pipController = nil
        contentController = nil
        renderView?.removeFromSuperview()
        renderView = nil
        NSLayoutConstraint.deactivate(sourceConstraints)
        sourceConstraints = []
        sourceWidthConstraint = nil
        sourceHeightConstraint = nil
        sourceView?.removeFromSuperview()
        sourceView = nil
        sessionID = nil
    }

    private func setupSourceView(in hostView: UIView) {
        let source = UIView()
        source.backgroundColor = .clear
        source.isOpaque = false
        source.isUserInteractionEnabled = false
        source.layer.cornerRadius = 18
        source.layer.cornerCurve = .continuous
        source.clipsToBounds = true
        source.translatesAutoresizingMaskIntoConstraints = false
        hostView.insertSubview(source, at: 0)
        sourceView = source
        updateSourceGeometry()
    }

    private func configureRenderView() {
        guard let host = contentController?.view else { return }
        if renderView == nil {
            let probe = PiPHiddenReferenceRenderView(frame: host.bounds)
            probe.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(probe)
            renderView = probe
        }
        renderView?.setText(Self.pipText)
        host.clipsToBounds = true
        renderView?.configure(isActive: pipController?.isPictureInPictureActive == true)
    }

    private func applyContentAppearance() {
        guard let view = contentController?.view else { return }
        view.backgroundColor = .black
        view.layer.backgroundColor = UIColor.black.cgColor
        view.isOpaque = true
        view.layer.isOpaque = true
        view.alpha = 1
    }

    /// 僅 PiP 保活：不播放任何音訊，釋放媒體音訊會話避免干擾其他 App。
    private func releaseMediaAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.soloAmbient, mode: .default)
    }

    private func updateAutomaticStartPolicy() {
        pipController?.canStartPictureInPictureAutomaticallyFromInline = wantsActive
    }

    // MARK: - 尺寸

    private func commitHeight(_ height: CGFloat) {
        pipHeight = min(max(height, Self.hiddenHeight), 220)
        UIView.performWithoutAnimation {
            contentController?.preferredContentSize = currentSize
            updateSourceGeometry()
            renderView?.setNeedsLayout()
        }
        applyContentAppearance()
        configureRenderView()
        onChange?()
    }

    /// preferredContentSize 與 source view 約束必須同步更新，否則 PiP 外框、內容與動畫尺寸會不一致。
    private func updateSourceGeometry() {
        guard let source = sourceView, let hostView else { return }
        if let sourceWidthConstraint, let sourceHeightConstraint {
            sourceWidthConstraint.constant = currentSize.width
            sourceHeightConstraint.constant = currentSize.height
        } else {
            NSLayoutConstraint.deactivate(sourceConstraints)
            let width = source.widthAnchor.constraint(equalToConstant: currentSize.width)
            let height = source.heightAnchor.constraint(equalToConstant: currentSize.height)
            sourceConstraints = [
                source.centerXAnchor.constraint(equalTo: hostView.centerXAnchor),
                source.centerYAnchor.constraint(equalTo: hostView.centerYAnchor),
                width,
                height,
            ]
            NSLayoutConstraint.activate(sourceConstraints)
            sourceWidthConstraint = width
            sourceHeightConstraint = height
        }
        source.alpha = 1
        source.layer.opacity = 1
        contentController?.view.alpha = 1
        hostView.layoutIfNeeded()
    }

    private func restoreVisualSurfaces() {
        guard let source = sourceView else { return }
        UIView.performWithoutAnimation {
            updateSourceGeometry()
            source.backgroundColor = .clear
            source.layer.backgroundColor = UIColor.clear.cgColor
            source.isOpaque = false
            source.layer.isOpaque = false
            contentController?.preferredContentSize = currentSize
            applyContentAppearance()
            hostView?.layoutIfNeeded()
        }
    }

    private func moveSourceOffscreenForClosing() {
        guard let source = sourceView, let hostView else { return }
        guard !needsLegacyCompatibility else {
            hostView.layoutIfNeeded()
            CATransaction.flush()
            return
        }
        UIView.performWithoutAnimation {
            NSLayoutConstraint.deactivate(sourceConstraints)
            sourceWidthConstraint = nil
            sourceHeightConstraint = nil
            sourceConstraints = [
                source.topAnchor.constraint(equalTo: hostView.topAnchor, constant: -8),
                source.leadingAnchor.constraint(equalTo: hostView.leadingAnchor, constant: -8),
                source.widthAnchor.constraint(equalToConstant: 1),
                source.heightAnchor.constraint(equalToConstant: 1),
            ]
            NSLayoutConstraint.activate(sourceConstraints)
            hostView.layoutIfNeeded()
            CATransaction.flush()
        }
    }

    // MARK: - 前後台

    @objc private func handleWillEnterForeground() {
        endBackgroundTask()
        if state == .running, pipController?.isPictureInPictureActive != true {
            handleInvalidated()
            onMessage?("懸浮窗已被系統關閉（可能被其他畫中畫擠掉或被系統回收），請重新開啟。")
        }
    }

    @objc private func handleDidEnterBackground() {
        if state == .running { beginBackgroundTask() }
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PiPKeepAlive") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

extension PiPEngine: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        configureRenderView()
        finishStarted()
        coexistence.schedulePostStartUpdateIfRequested(controller: pictureInPictureController)
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        wantsActive = false
        hideAfterStart = false
        updateAutomaticStartPolicy()
        pendingStart?.cancel()
        pendingStart = nil
        state = .stopping
        scheduleTransitionWatchdog(after: 6)
        moveSourceOffscreenForClosing()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        endContentSession()
        coexistence.restore()
        cancelPendingWork()
        restoreVisualSurfaces()
        didRetryLegacyStart = false
        wantsActive = false
        updateAutomaticStartPolicy()
        runningSince = nil
        endBackgroundTask()
        state = .idle
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        if retryLegacyStartIfNeeded() { return }
        failStart(message: "畫中畫啟動失敗：\(error.localizedDescription)")
    }
}

/// App 自己的 DisplayLink 刷新請求（對應上游 MainTabBarController 的 refresh driver）：
/// 前台嚴格請求 120Hz；後台有懸浮窗會話時只保留 DisplayLink、不指定幀率範圍（1.1.1 的 requests120 = false）。
private final class RefreshDriver: NSObject {
    private final class Target: NSObject {
        @objc func step(_ link: CADisplayLink) {}
    }

    private let target = Target()
    private var displayLink: CADisplayLink?

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification, PiPHiddenReferenceMode.didChangeNotification] {
            center.addObserver(self, selector: #selector(restart), name: name, object: nil)
        }
        restart()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        displayLink?.invalidate()
    }

    // 每次狀態切換都重建 DisplayLink，後台會話不會沿用前台的嚴格範圍。
    @objc private func restart() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: target, selector: #selector(Target.step(_:)))
        if UIApplication.shared.applicationState == .active || !PiPHiddenReferenceMode.suppressesStrictRefreshRequest {
            let rate = Float(min(120, UIScreen.main.maximumFramesPerSecond))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
}

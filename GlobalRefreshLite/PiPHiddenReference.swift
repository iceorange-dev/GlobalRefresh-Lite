import AVKit
import Foundation
import ObjectiveC
import UIKit

// 移植自 Yoroin/GlobalRefresh-PiP 1.1.1 的 PiPCoexistenceExperiment.swift（VideoCall + 僅 PiP 保活的預設組合）。
// 只移除了日誌、write-trace 診斷與時鐘模式；建構期 controls 策略、內容類型 provider（4→6）與退場邏輯維持原樣。
// 這裡用的是系統內部介面，不是 Apple 公開 API；呼叫前都會校驗方法簽名，不符合就放棄啟動。

/// 只作用於正在建構的 controller；其他 adapter 仍走原本的 getter。
enum PiPHiddenReferenceControls {
    private static var associationKey: UInt8 = 0
    private static var installed: Set<ObjectIdentifier> = []
    private typealias Getter = @convention(c) (AnyObject, Selector) -> Int
    private final class Construction {
        var adapter: NSObject?
    }
    private static var construction: Construction?

    static func makeController(source: AVPictureInPictureController.ContentSource) -> AVPictureInPictureController? {
        guard let adapterClass = NSClassFromString("AVPictureInPicturePlatformAdapter") else { return nil }
        return withPolicy(adapterClass: adapterClass, make: {
            AVPictureInPictureController(contentSource: source)
        }, adapter: { controller in
            guard let cls = object_getClass(controller),
                  let ivar = class_getInstanceVariable(cls, "_platformAdapter"),
                  let encoding = ivar_getTypeEncoding(ivar), encoding.pointee == 64 else { return nil }
            return object_getIvar(controller, ivar) as? NSObject
        })
    }

    private static func withPolicy<T>(adapterClass: AnyClass, make: () -> T, adapter: (T) -> NSObject?) -> T? {
        precondition(Thread.isMainThread)
        guard construction == nil, install(adapterClass: adapterClass) else { return nil }
        let context = Construction()
        construction = context
        defer { construction = nil }
        let value = make()
        guard let captured = context.adapter, captured === adapter(value) else {
            if let captured = context.adapter { clear(adapter: captured) }
            return nil
        }
        clear(adapter: captured)
        return value
    }

    private static func clear(adapter: NSObject) {
        objc_setAssociatedObject(adapter, &associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static func install(adapterClass: AnyClass) -> Bool {
        let key = ObjectIdentifier(adapterClass)
        if installed.contains(key) { return true }
        let selector = NSSelectorFromString("_proxyControlsStyle")
        guard let method = class_getInstanceMethod(adapterClass, selector),
              method_getNumberOfArguments(method) == 2 else { return false }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType) == "q" else { return false }
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let block: @convention(block) (AnyObject) -> Int = { object in
            guard let target = object as? NSObject else { return original(object, selector) }
            if objc_getAssociatedObject(target, &associationKey) != nil { return 5 }
            if Thread.isMainThread, let context = construction {
                if context.adapter == nil {
                    context.adapter = target
                    objc_setAssociatedObject(target, &associationKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                }
                if context.adapter === target {
                    return 5
                }
            }
            return original(object, selector)
        }
        let replacement = imp_implementationWithBlock(block)
        if !class_addMethod(adapterClass, selector, replacement, method_getTypeEncoding(method)) {
            method_setImplementation(method, replacement)
        }
        installed.insert(key)
        return true
    }
}

enum PiPHiddenReferenceOptions {
    // 上游實機驗證過的 content-only 策略：懸浮窗不再嚴格請求 120Hz，只保留內容更新。
    static let requests120 = false
    static let contentFramesPerSecond = 60
}

/// 會話標記：有 owner 時代表 1.1.1 預設組合正在運行，前台以外的刷新驅動不再指定嚴格範圍。
enum PiPHiddenReferenceMode {
    static func supportsSystemMajorVersion(_ major: Int) -> Bool {
        (15...27).contains(major)
    }
    static let didChangeNotification = Notification.Name("PiPHiddenReferenceSessionChanged")
    private(set) static var owner: UUID?
    static var suppressesRefreshDriver: Bool { owner != nil }
    static var suppressesStrictRefreshRequest: Bool { owner != nil && !PiPHiddenReferenceOptions.requests120 }

    static func begin(owner token: UUID) {
        precondition(Thread.isMainThread)
        guard owner != token else { return }
        owner = token
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func end(owner token: UUID) {
        precondition(Thread.isMainThread)
        guard owner == token else { return }
        owner = nil
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

/// 懸浮窗內容宿主：讓 PiP 內容持續更新（文字捲動），縮到 0.1pt 後也不停止。
/// 這不是播放器，也不代表系統實際刷新率。
final class PiPHiddenReferenceRenderView: UIView {
    private let surface = CALayer()
    private let textView = UITextView()
    private var displayLink: CADisplayLink?
    private var phase: CGFloat = 0
    private var previousTimestamp: CFTimeInterval?

    private final class Target: NSObject {
        weak var owner: PiPHiddenReferenceRenderView?
        init(owner: PiPHiddenReferenceRenderView) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }
    private lazy var target = Target(owner: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear
        surface.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(surface)
        textView.backgroundColor = .black
        textView.textColor = .white
        textView.isUserInteractionEnabled = false
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setText(_ text: String) {
        guard textView.text != text else { return }
        textView.text = text
    }

    func configure(isActive: Bool) {
        clipsToBounds = true
        setNeedsLayout()
        layoutIfNeeded()
        if !isActive {
            stop()
        } else if displayLink == nil {
            previousTimestamp = nil
            let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
            link.preferredFramesPerSecond = min(PiPHiddenReferenceOptions.contentFramesPerSecond, UIScreen.main.maximumFramesPerSecond)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        previousTimestamp = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        textView.frame = surface.frame
        CATransaction.commit()
    }

    private func tick(_ link: CADisplayLink) {
        if let previousTimestamp {
            phase = (phase + CGFloat(min(0.1, link.timestamp - previousTimestamp) / 2.4))
                .truncatingRemainder(dividingBy: 1)
        }
        previousTimestamp = link.timestamp
        setNeedsLayout()
        layoutIfNeeded()
        let maxOffset = max(0, textView.contentSize.height - textView.bounds.height)
        textView.setContentOffset(CGPoint(x: 0, y: maxOffset * phase), animated: false)
    }

    deinit { displayLink?.invalidate() }
}

/// 畫中畫共存保護：建構階段先以內容類型 4 啟動，didStart 1 秒後提交一次 6。
/// 類別層級的 hook 在停止後保持休眠，要徹底移除需重啟行程。
final class PiPCoexistenceExperiment {
    private static var associationKey: UInt8 = 0
    private static var providers: [String: IMP] = [:]
    private typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias IntegerGetter = @convention(c) (AnyObject, Selector) -> Int
    private typealias IntegerSetter = @convention(c) (AnyObject, Selector, Int) -> Void
    private typealias RespondsGetter = @convention(c) (AnyObject, Selector, Selector) -> Bool
    private typealias StateMutation = @convention(block) (AnyObject) -> Void
    private typealias StateUpdater = @convention(c) (AnyObject, Selector, StateMutation) -> Void

    private final class Configuration: NSObject {
        weak var proxy: NSObject?
        private let lock = NSLock()
        private var requestedType = 6
        let followsPlaybackPhase: Bool
        var isObtainingProxy = false
        init(proxy: NSObject?, followsPlaybackPhase: Bool = false) {
            self.proxy = proxy
            self.followsPlaybackPhase = followsPlaybackPhase
            requestedType = followsPlaybackPhase ? 4 : 6
        }
        var providedType: Int {
            lock.lock()
            defer { lock.unlock() }
            return followsPlaybackPhase ? requestedType : 6
        }
        func setRequestedType(_ value: Int) {
            lock.lock()
            requestedType = value
            lock.unlock()
        }
    }

    static let postStartTransitionDelay: TimeInterval = 1

    private weak var adapter: NSObject?
    private weak var proxy: NSObject?
    private var configuration: Configuration?
    private var originalContentType: Int?
    private var installationID: UUID?
    private var postStartScheduled = false
    private var postStartSubmitted = false
    private var referenceStartupSubmitted = false
    private static var isRequested: Bool {
        PiPHiddenReferenceMode.suppressesRefreshDriver
    }

    @discardableResult
    func prepareForStartIfRequested(controller: AVPictureInPictureController, isVideoCall: Bool) -> Bool {
        guard Self.isRequested else { return false }
        guard PiPHiddenReferenceMode.supportsSystemMajorVersion(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
              isVideoCall, !controller.isPictureInPictureActive else { return false }
        guard let adapter = Self.object(controller, selector: "platformAdapter"),
              let proxy = Self.object(adapter, selector: "pegasusProxy"),
              let expected = NSClassFromString("PGPictureInPictureProxy"),
              proxy.isKind(of: expected) else {
            return false
        }
        return install(adapter: adapter, proxy: proxy, prepared: nil)
    }

    func prepareHiddenReference(controller: AVPictureInPictureController) -> Bool {
        guard Thread.isMainThread,
              let adapter = Self.object(controller, selector: "platformAdapter") else { return false }
        return prepareHiddenReference(adapter: adapter) {
            guard let proxy = Self.object(adapter, selector: "pegasusProxy"),
                  let expected = NSClassFromString("PGPictureInPictureProxy"),
                  proxy.isKind(of: expected) else { return nil }
            return proxy
        }
    }

    // provider 與它的初始值必須在 lazy proxy getter 執行前就位。
    private func prepareHiddenReference(adapter candidate: NSObject, obtainProxy: () -> NSObject?) -> Bool {
        guard Thread.isMainThread, adapter == nil,
              objc_getAssociatedObject(candidate, &Self.associationKey) == nil,
              let base = object_getClass(candidate), Self.addScopedProvider(to: base) else { return false }
        let prepared = Configuration(proxy: nil, followsPlaybackPhase: true)
        objc_setAssociatedObject(candidate, &Self.associationKey, prepared, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        prepared.isObtainingProxy = true
        let candidateProxy = obtainProxy()
        prepared.isObtainingProxy = false
        guard let candidateProxy,
              prepared.proxy == nil || prepared.proxy === candidateProxy else {
            objc_setAssociatedObject(candidate, &Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return false
        }
        prepared.proxy = candidateProxy
        let succeeded = install(adapter: candidate, proxy: candidateProxy, prepared: prepared)
        if !succeeded {
            objc_setAssociatedObject(candidate, &Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        return succeeded
    }

    private func install(adapter candidate: NSObject, proxy candidateProxy: NSObject, prepared: Configuration?) -> Bool {
        guard Thread.isMainThread else { return false }
        if let adapter { return adapter === candidate && proxy === candidateProxy }
        let updateSelector = NSSelectorFromString("updatePlaybackStateUsingBlock:")
        let setterSelector = NSSelectorFromString("setContentType:")
        guard let base = object_getClass(candidate),
              let proxyClass = object_getClass(candidateProxy),
              let update = Self.method(proxyClass, selector: updateSelector, result: "v", arguments: ["@?"]),
              let state = Self.object(candidateProxy, selector: "playbackState"),
              let stateClass = object_getClass(state),
              let setter = Self.method(stateClass, selector: setterSelector, result: "v", arguments: ["q"]),
              let previousType = Self.contentType(of: candidateProxy),
              previousType == 4 || (prepared != nil && previousType == 6),
              Self.addScopedProvider(to: base) else {
            return false
        }

        let token = UUID()
        let configuration = prepared ?? Configuration(proxy: candidateProxy)
        self.configuration = configuration
        installationID = token
        originalContentType = prepared == nil ? previousType : 4
        adapter = candidate
        proxy = candidateProxy
        objc_setAssociatedObject(candidate, &Self.associationKey, configuration, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let setterIMP = unsafeBitCast(method_getImplementation(setter), to: IntegerSetter.self)
        let mutation: StateMutation = { [weak self, weak candidate] currentState in
            guard self?.installationID == token, let candidate,
                  (objc_getAssociatedObject(candidate, &Self.associationKey) as? Configuration) === configuration,
                  object_getClass(currentState) === stateClass else { return }
            setterIMP(currentState, setterSelector, configuration.providedType)
        }
        unsafeBitCast(method_getImplementation(update), to: StateUpdater.self)(candidateProxy, updateSelector, mutation)
        return true
    }

    func schedulePostStartUpdateIfRequested(controller: AVPictureInPictureController) {
        guard controller.isPictureInPictureActive else { return }
        let isStillActive = { [weak controller, weak self] in
            guard let controller, let self, controller.isPictureInPictureActive,
                  !controller.isPictureInPictureSuspended,
                  let adapter = Self.object(controller, selector: "platformAdapter"),
                  let proxy = Self.object(adapter, selector: "pegasusProxy") else { return false }
            return adapter === self.adapter && proxy === self.proxy
        }
        if PiPHiddenReferenceMode.suppressesRefreshDriver {
            beginReferenceStartupProtection(isStillActive: isStillActive)
        }
        schedulePostStartTransition(isStillActive: isStillActive)
    }

    // 啟動保護：在延遲提交 6 之前，先維持一個內容類型 4 的啟動窗口。
    private func beginReferenceStartupProtection(isStillActive: @escaping () -> Bool) {
        guard Thread.isMainThread, PiPHiddenReferenceMode.suppressesRefreshDriver,
              let referenceOwner = PiPHiddenReferenceMode.owner,
              Self.isRequested, !referenceStartupSubmitted, !postStartScheduled,
              isStillActive(), let token = installationID, let adapter, let proxy, let configuration,
              let proxyClass = object_getClass(proxy),
              let update = Self.method(proxyClass, selector: NSSelectorFromString("updatePlaybackStateUsingBlock:"), result: "v", arguments: ["@?"]),
              let state = Self.object(proxy, selector: "playbackState"), let stateClass = object_getClass(state),
              Self.method(stateClass, selector: NSSelectorFromString("setContentType:"), result: "v", arguments: ["q"]) != nil else { return }
        referenceStartupSubmitted = true
        let mutation: StateMutation = { [weak self, weak adapter] currentState in
            guard let self, self.installationID == token, !self.postStartSubmitted,
                  PiPHiddenReferenceMode.owner == referenceOwner, Self.isRequested, isStillActive(),
                  let adapter, (objc_getAssociatedObject(adapter, &Self.associationKey) as? Configuration) === configuration,
                  object_getClass(currentState) === stateClass,
                  let setter = Self.method(stateClass, selector: NSSelectorFromString("setContentType:"), result: "v", arguments: ["q"]) else { return }
            configuration.setRequestedType(4)
            unsafeBitCast(method_getImplementation(setter), to: IntegerSetter.self)(currentState, NSSelectorFromString("setContentType:"), 4)
        }
        unsafeBitCast(method_getImplementation(update), to: StateUpdater.self)(proxy, NSSelectorFromString("updatePlaybackStateUsingBlock:"), mutation)
    }

    // 啟動後只提交一次，不是修復迴圈；predicate 同時核對 controller 身分。
    private func schedulePostStartTransition(delay: TimeInterval = PiPCoexistenceExperiment.postStartTransitionDelay, isStillActive: @escaping () -> Bool) {
        guard Thread.isMainThread, Self.isRequested,
              let token = installationID, configuration != nil, !postStartScheduled else { return }
        postStartScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.installationID == token else { return }
            guard Self.isRequested, isStillActive() else { return }
            self.submitPostStartContentType(token: token, isStillActive: isStillActive)
        }
    }

    private func submitPostStartContentType(token: UUID, isStillActive: @escaping () -> Bool) {
        let updateSelector = NSSelectorFromString("updatePlaybackStateUsingBlock:")
        let setterSelector = NSSelectorFromString("setContentType:")
        guard let adapter, let proxy, let configuration, installationID == token,
              !postStartSubmitted,
              let proxyClass = object_getClass(proxy),
              let update = Self.method(proxyClass, selector: updateSelector, result: "v", arguments: ["@?"]),
              let state = Self.object(proxy, selector: "playbackState"),
              let stateClass = object_getClass(state),
              Self.method(stateClass, selector: setterSelector, result: "v", arguments: ["q"]) != nil else {
            return
        }
        postStartSubmitted = true
        let mutation: StateMutation = { [weak self, weak adapter] currentState in
            guard let self, self.installationID == token,
                  Self.isRequested, isStillActive(), let adapter,
                  (objc_getAssociatedObject(adapter, &Self.associationKey) as? Configuration) === configuration,
                  object_getClass(currentState) === stateClass,
                  let setter = Self.method(stateClass, selector: setterSelector, result: "v", arguments: ["q"]) else { return }
            configuration.setRequestedType(6)
            unsafeBitCast(method_getImplementation(setter), to: IntegerSetter.self)(currentState, setterSelector, 6)
        }
        unsafeBitCast(method_getImplementation(update), to: StateUpdater.self)(proxy, updateSelector, mutation)
    }

    // PG 會動態查詢 respondsToSelector:，對沒有參與的實例隱藏新增的方法。
    private static func addScopedProvider(to base: AnyClass) -> Bool {
        let providerSelector = NSSelectorFromString("pictureInPictureProxyContentType:")
        if let existing = class_getInstanceMethod(base, providerSelector) {
            return providers.values.contains { $0 == method_getImplementation(existing) }
        }
        let respondsSelector = NSSelectorFromString("respondsToSelector:")
        guard let responds = method(base, selector: respondsSelector, result: "B", arguments: [":"]),
              let encoding = method_getTypeEncoding(responds) else { return false }
        let originalResponds = unsafeBitCast(method_getImplementation(responds), to: RespondsGetter.self)
        let responseBlock: @convention(block) (AnyObject, Selector) -> Bool = { object, selector in
            if selector == providerSelector {
                return objc_getAssociatedObject(object, &associationKey) is Configuration
            }
            return originalResponds(object, respondsSelector, selector)
        }
        let providerBlock: @convention(block) (AnyObject, AnyObject?) -> Int = { object, queriedProxy in
            guard let configuration = objc_getAssociatedObject(object, &associationKey) as? Configuration else {
                return (queriedProxy as? NSObject).flatMap { contentType(of: $0) } ?? 4
            }
            if configuration.proxy == nil, configuration.followsPlaybackPhase,
               configuration.isObtainingProxy, Thread.isMainThread,
               let queriedProxy = queriedProxy as? NSObject {
                configuration.proxy = queriedProxy
            }
            guard let proxy = configuration.proxy, queriedProxy === proxy else {
                return (queriedProxy as? NSObject).flatMap { contentType(of: $0) } ?? 4
            }
            return configuration.providedType
        }
        let providerIMP = imp_implementationWithBlock(providerBlock)
        let responseIMP = imp_implementationWithBlock(responseBlock)
        guard class_addMethod(base, providerSelector, providerIMP, "q@:@") else {
            imp_removeBlock(providerIMP)
            imp_removeBlock(responseIMP)
            return false
        }
        class_replaceMethod(base, respondsSelector, responseIMP, encoding)
        providers[NSStringFromClass(base)] = providerIMP
        return true
    }

    func restore() {
        installationID = nil
        referenceStartupSubmitted = false
        postStartScheduled = false
        postStartSubmitted = false
        defer {
            adapter = nil
            proxy = nil
            configuration = nil
            originalContentType = nil
        }
        guard let adapter else { return }
        objc_setAssociatedObject(adapter, &Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if let proxy, let previous = originalContentType, Self.contentType(of: proxy) == 6,
           let state = Self.object(proxy, selector: "playbackState"), let type = object_getClass(state),
           let setter = Self.method(type, selector: NSSelectorFromString("setContentType:"), result: "v", arguments: ["q"]) {
            unsafeBitCast(method_getImplementation(setter), to: IntegerSetter.self)(state, NSSelectorFromString("setContentType:"), previous)
        }
    }

    deinit { restore() }

    private static func object(_ owner: NSObject, selector name: String) -> NSObject? {
        let selector = NSSelectorFromString(name)
        guard let type = object_getClass(owner), let method = method(type, selector: selector, result: "@") else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: ObjectGetter.self)(owner, selector)?.takeUnretainedValue() as? NSObject
    }

    private static func contentType(of proxy: NSObject) -> Int? {
        guard let state = object(proxy, selector: "playbackState"), let type = object_getClass(state),
              let getter = method(type, selector: NSSelectorFromString("contentType"), result: "q") else { return nil }
        return unsafeBitCast(method_getImplementation(getter), to: IntegerGetter.self)(state, NSSelectorFromString("contentType"))
    }

    private static func method(_ type: AnyClass, selector: Selector, result: String, arguments: [String] = []) -> Method? {
        guard let method = class_getInstanceMethod(type, selector),
              method_getNumberOfArguments(method) == arguments.count + 2 else { return nil }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType) == result else { return nil }
        for (index, expected) in arguments.enumerated() {
            guard let type = method_copyArgumentType(method, UInt32(index + 2)) else { return nil }
            let actual = String(cString: type)
            free(type)
            guard actual == expected else { return nil }
        }
        return method
    }
}

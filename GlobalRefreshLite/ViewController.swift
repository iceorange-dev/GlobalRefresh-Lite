import UIKit

final class ViewController: UIViewController {
    private lazy var engine = PiPEngine(hostView: view)

    private let statusDot = UIView()
    private let statusValue = UILabel()
    private let heightValue = UILabel()
    private let runtimeValue = UILabel()
    private let refreshValue = UILabel()
    private let toggleButton = UIButton(type: .system)
    private var runtimeTimer: Timer?

    private static let runtimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        setupLayout()

        engine.onChange = { [weak self] in self?.render() }
        engine.onMessage = { [weak self] in self?.showMessage($0) }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(updateRuntimeTimer), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(updateRuntimeTimer), name: UIApplication.didEnterBackgroundNotification, object: nil)
        render()
    }

    // MARK: - 版面

    private func setupLayout() {
        let titleLabel = UILabel()
        titleLabel.text = "一鍵 120Hz"
        titleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        titleLabel.adjustsFontForContentSizeCategory = true

        let card = UIStackView(arrangedSubviews: [
            makeStatusRow(),
            makeRow(title: "懸浮窗高度", value: heightValue),
            makeRow(title: "本次運行", value: runtimeValue),
            makeRow(title: "螢幕最高刷新率", value: refreshValue),
        ])
        card.axis = .vertical
        card.spacing = 14
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous

        toggleButton.addTarget(self, action: #selector(handleToggle), for: .touchUpInside)
        toggleButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, card, toggleButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false

        let creditLabel = makeLabel(
            "基於 CaiWanFeng/PiP 與 Yoroin/GlobalRefresh-PiP 精簡",
            style: .caption2,
            color: .tertiaryLabel
        )
        creditLabel.textAlignment = .center
        creditLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        view.addSubview(creditLabel)
        let guide = view.readableContentGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            creditLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            creditLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            creditLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            creditLabel.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 16),
        ])
    }

    private func makeLabel(_ text: String, style: UIFont.TextStyle, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func makeStatusRow() -> UIView {
        statusDot.layer.cornerRadius = 5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),
        ])
        statusValue.font = .preferredFont(forTextStyle: .headline)
        statusValue.adjustsFontForContentSizeCategory = true

        let value = UIStackView(arrangedSubviews: [statusDot, statusValue])
        value.spacing = 8
        value.alignment = .center
        return makeRow(title: "狀態", value: value)
    }

    private func makeRow(title: String, value: UIView) -> UIView {
        let titleLabel = makeLabel(title, style: .body, color: .secondaryLabel)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        if let label = value as? UILabel {
            label.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .medium)
            label.textAlignment = .right
        }
        let row = UIStackView(arrangedSubviews: [titleLabel, UIView(), value])
        row.alignment = .center
        row.spacing = 12
        return row
    }

    // MARK: - 狀態

    private func render() {
        let state = engine.state
        let isRunning = state == .running

        switch state {
        case .idle:
            statusValue.text = "未開啟"
            statusDot.backgroundColor = .systemGray
        case .starting:
            statusValue.text = "啟動中…"
            statusDot.backgroundColor = .systemOrange
        case .running:
            statusValue.text = engine.isHidden ? "運行中 · 已隱藏" : "運行中"
            statusDot.backgroundColor = .systemGreen
        case .stopping:
            statusValue.text = "關閉中…"
            statusDot.backgroundColor = .systemOrange
        }

        heightValue.text = isRunning ? formattedHeight(engine.pipHeight) : "—"

        let maximumFPS = UIScreen.main.maximumFramesPerSecond
        refreshValue.text = maximumFPS > 60 ? "\(maximumFPS) Hz" : "\(maximumFPS) Hz（不支援高刷）"

        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .large
        configuration.buttonSize = .large
        configuration.title = isRunning ? "關閉" : "開啟 120Hz"
        configuration.baseBackgroundColor = isRunning ? .systemRed : .systemBlue
        configuration.showsActivityIndicator = state == .starting || state == .stopping
        toggleButton.configuration = configuration
        toggleButton.isEnabled = state == .idle || state == .running

        updateRuntimeTimer()
    }

    @objc private func updateRuntimeTimer() {
        let shouldTick = engine.state == .running && UIApplication.shared.applicationState != .background
        if shouldTick, runtimeTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.renderRuntime() }
            RunLoop.main.add(timer, forMode: .common)
            runtimeTimer = timer
        } else if !shouldTick {
            runtimeTimer?.invalidate()
            runtimeTimer = nil
        }
        renderRuntime()
    }

    private func renderRuntime() {
        guard let since = engine.runningSince else {
            runtimeValue.text = "—"
            return
        }
        runtimeValue.text = Self.runtimeFormatter.string(from: max(0, Date().timeIntervalSince(since))) ?? "—"
    }

    private func formattedHeight(_ height: CGFloat) -> String {
        let rounded = (height * 10).rounded() / 10
        return rounded.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(rounded)) pt"
            : String(format: "%.1f pt", rounded)
    }

    @objc private func handleToggle() {
        engine.toggle()
    }

    private func showMessage(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

import UIKit
import ReplayKit

private enum ScreenFollowDisclosureConsent {
    private static let key = "screenFollowDisclosureConsentVersion"
    private static let currentVersion = 2

    static var isAccepted: Bool { UserDefaults.standard.integer(forKey: key) == currentVersion }
    static func accept() { UserDefaults.standard.set(currentVersion, forKey: key) }
}

enum ScreenFollowAppearance {
    static let accent = UIColor.systemBlue
    static let ink = UIColor(red: 0.10, green: 0.15, blue: 0.23, alpha: 1)
    static let secondary = UIColor(red: 0.38, green: 0.43, blue: 0.50, alpha: 1)
    static let entryBackground = UIColor(red: 0.94, green: 0.97, blue: 1, alpha: 1)
    static let icon = makeIcon(color: accent)

    static func makeIcon(color: UIColor) -> UIImage {
        // Blue identifies the Live feature; the separate red badge reports an active broadcast.
        UIGraphicsImageRenderer(size: CGSize(width: 44, height: 44)).image { _ in
            color.setStroke()
            let signal = UIBezierPath()
            signal.move(to: CGPoint(x: 14, y: 9))
            signal.addQuadCurve(to: CGPoint(x: 30, y: 9), controlPoint: CGPoint(x: 22, y: 1))
            signal.move(to: CGPoint(x: 18, y: 12))
            signal.addQuadCurve(to: CGPoint(x: 26, y: 12), controlPoint: CGPoint(x: 22, y: 8))
            signal.lineWidth = 1.8; signal.lineCapStyle = .round
            signal.stroke()

            let badge = CGRect(x: 4, y: 17, width: 36, height: 23)
            color.setFill()
            UIBezierPath(roundedRect: badge, cornerRadius: 6).fill()
            let title = NSAttributedString(string: "LIVE", attributes: [
                .font: UIFont.systemFont(ofSize: 11.5, weight: .heavy),
                .foregroundColor: UIColor.white,
                .kern: 0.5
            ])
            let size = title.size()
            title.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
        }
    }

    static func font(_ size: CGFloat, weight: UIFont.Weight = .regular,
                     style: UIFont.TextStyle = .body, compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight), compatibleWith: traits)
    }

    static func homeEntry() -> UIButton { ScreenFollowEntryButton() }
}

private final class ScreenFollowEntryButton: HomeFeatureEntryButton {
    private let actionLabel = HomeFeatureEntryButton.label(KKLocalized("Start Screen Sharing"), size: 16, weight: .bold)
    private let subtitle = HomeFeatureEntryButton.label(KKLocalized("Follow faces in other apps"), size: 14, weight: .regular)
    private var observer: NSObjectProtocol?

    init() {
        super.init(imageName: "home_live_tracking", title: KKLocalized("Live View"))
        accessibilityIdentifier = "home.liveFollow"
        accessibilityHint = KKLocalized("Choose a camera and start screen sharing")
        subtitle.textColor = .secondaryLabel
        copyStack.addArrangedSubview(actionLabel)
        copyStack.addArrangedSubview(subtitle)
        copyStack.addArrangedSubview(ScreenFollowLiveBadge())
        observer = NotificationCenter.default.addObserver(forName: ScreenFollowMainAccess.broadcastStateDidChange,
                                                          object: nil, queue: .main) { [weak self] _ in self?.refreshStatus() }
        refreshStatus()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func refreshStatus() {
        let active = ScreenFollowMainAccess.shared.broadcastConnected
        actionLabel.text = active ? KKLocalized("View Screen Sharing") : KKLocalized("Start Screen Sharing")
        subtitle.isHidden = active
        accessibilityValue = active ? KKLocalized("Broadcasting") : KKLocalized("Not Started")
    }
}

private final class ScreenFollowLensButton: UIButton {
    private let symbol: UIImageView
    private let selection = UIImageView()

    init(title: String, detail: String, symbolName: String) {
        symbol = UIImageView(image: UIImage(systemName: symbolName,
                                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 25, weight: .regular)))
        super.init(frame: .zero)
        layer.cornerRadius = 18; layer.cornerCurve = .continuous
        accessibilityLabel = "\(title)，\(detail)"
        accessibilityHint = KKLocalized("Use the same camera as your streaming app")
        isAccessibilityElement = true
        symbol.contentMode = .left
        selection.contentMode = .scaleAspectFit
        let spacer = UIView()
        let top = UIStackView(arrangedSubviews: [symbol, spacer, selection])
        top.alignment = .center
        let name = UILabel(); name.text = title; name.textColor = ScreenFollowAppearance.ink
        name.font = ScreenFollowAppearance.font(17, weight: .semibold, style: .headline)
        let note = UILabel(); note.text = detail; note.textColor = ScreenFollowAppearance.secondary
        note.font = ScreenFollowAppearance.font(12, style: .caption1)
        for label in [name, note] { label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = true }
        let copy = UIStackView(arrangedSubviews: [name, note]); copy.axis = .vertical; copy.spacing = 4
        let stack = UIStackView(arrangedSubviews: [top, copy]); stack.axis = .vertical; stack.spacing = 14
        stack.isUserInteractionEnabled = false; stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            symbol.widthAnchor.constraint(equalToConstant: 32), symbol.heightAnchor.constraint(equalToConstant: 28),
            selection.widthAnchor.constraint(equalToConstant: 20), selection.heightAnchor.constraint(equalToConstant: 20)
        ])
        refreshSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isSelected: Bool { didSet { refreshSelection() } }
    override var isHighlighted: Bool { didSet { alpha = isHighlighted || !isEnabled ? 0.55 : 1 } }
    override var isEnabled: Bool { didSet { alpha = isEnabled ? 1 : 0.55 } }
    private func refreshSelection() {
        backgroundColor = isSelected ? ScreenFollowAppearance.entryBackground : UIColor(white: 0.97, alpha: 1)
        layer.borderWidth = isSelected ? 1.5 : 1
        layer.borderColor = (isSelected ? ScreenFollowAppearance.accent : UIColor(white: 0.91, alpha: 1)).cgColor
        symbol.tintColor = isSelected ? ScreenFollowAppearance.accent : ScreenFollowAppearance.secondary
        selection.image = UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        selection.tintColor = isSelected ? ScreenFollowAppearance.accent : UIColor(white: 0.76, alpha: 1)
        accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }
}

/// Observes broadcast connection independently of the configuration page's diagnostic callback.
final class ScreenFollowLiveBadge: UIView {
    private var observer: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemRed.withAlphaComponent(0.08)
        layer.cornerRadius = 8
        accessibilityIdentifier = "home.liveFollow.liveBadge"
        isAccessibilityElement = true
        accessibilityLabel = KKLocalized("Broadcasting")
        let dot = UIView()
        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 3
        let label = UILabel()
        label.text = KKLocalized("Broadcasting")
        label.textColor = UIColor(red: 0.70, green: 0.15, blue: 0.18, alpha: 1)
        label.font = ScreenFollowAppearance.font(12, weight: .medium, style: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        let row = UIStackView(arrangedSubviews: [dot, label])
        row.axis = .horizontal; row.spacing = 5; row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let bottom = row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        // UIStackView collapses this badge to zero height when the broadcast ends.
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            bottom
        ])
        observer = NotificationCenter.default.addObserver(forName: ScreenFollowMainAccess.broadcastStateDidChange,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.update(isBroadcasting: ScreenFollowMainAccess.shared.broadcastConnected)
        }
        update(isBroadcasting: ScreenFollowMainAccess.shared.broadcastConnected)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func update(isBroadcasting: Bool) { isHidden = !isBroadcasting }
}

/// Lens selection opens the system broadcast directly; no intermediate capture page.
/// Advanced controls and transport diagnostics stay outside the main flow.
final class ScreenFollowViewController: UIViewController {
    var onReturnToCamera: (() -> Void)?
    var returnButtonTitle = KKLocalized("Back to Camera")
    private let engine = ScreenFollowMainAccess.shared
    private let accent = ScreenFollowAppearance.accent
    private let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    // ReplayKit presents its own system UI through the picker button. Keep the
    // user action injectable so UI checks never start a real screen broadcast.
    var broadcastPickerPresenter: (RPSystemBroadcastPickerView) -> Bool = { picker in
        guard let button = picker.subviews.compactMap({ $0 as? UIButton }).first else { return false }
        button.sendActions(for: .touchUpInside)
        return true
    }
    /// UI previews may bypass persistence without changing production consent state.
    var disclosureConsentOverride: Bool?
    private var wantsBroadcastPicker = false
    private var isClosing = false
    private var foregroundObserver: NSObjectProtocol?
    private var frontCamera = true
    private var centerRegion = false
    private var reverseYaw = false
    private var reversePitch = false

    override func viewDidLoad() {
        super.viewDidLoad()
        engine.configurationVisible = true
        if engine.sessionID != nil { frontCamera = engine.diagnostics.camera != "rear" }
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.engine.broadcastConnected, self.presentedViewController == nil { self.close() }
            else { self.refresh() }
        }
        overrideUserInterfaceStyle = .light
        picker.preferredExtension = ScreenFollowConstants.extensionBundleID
        picker.showsMicrophoneButton = false
        picker.accessibilityElementsHidden = true
        picker.clipsToBounds = true
        view.addSubview(picker)
        buildSetupSheet()
        engine.onUpdate = { [weak self] in self?.refresh() }
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refresh()
    }

    deinit {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    private weak var lensOptions: UIStackView?
    private weak var utilityOptions: UIStackView?

    private func buildSetupSheet() {
        navigationController?.setNavigationBarHidden(true, animated: false)
        navigationController?.view.backgroundColor = .clear
        view.backgroundColor = .clear

        let shade = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        shade.contentView.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        shade.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shade)
        let panel = UIView()
        panel.backgroundColor = .white
        panel.layer.cornerRadius = 28; panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        panel.accessibilityIdentifier = "screenfollow.setupSheet"
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        let preferredHeight = panel.heightAnchor.constraint(equalToConstant: 550)
        preferredHeight.priority = .defaultHigh
        let preferredWidth = panel.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -24)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            shade.leadingAnchor.constraint(equalTo: view.leadingAnchor), shade.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shade.topAnchor.constraint(equalTo: view.topAnchor), shade.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            panel.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            preferredHeight, preferredWidth
        ])

        let brand = UILabel(); configure(brand, size: 11, weight: .bold, color: accent)
        brand.text = "GIMBAL VIEW"; brand.accessibilityElementsHidden = true
        brand.font = .systemFont(ofSize: 11, weight: .bold)
        brand.adjustsFontForContentSizeCategory = false
        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
        closeButton.tintColor = ScreenFollowAppearance.secondary
        closeButton.backgroundColor = UIColor(white: 0.96, alpha: 1)
        closeButton.layer.cornerRadius = 22
        closeButton.accessibilityLabel = returnButtonTitle
        closeButton.accessibilityIdentifier = "screenfollow.close"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [brand, UIView(), closeButton])
        header.alignment = .center; header.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 44), closeButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        let start = UIButton(type: .system)
        var startStyle = UIButton.Configuration.filled()
        startStyle.baseBackgroundColor = accent
        startStyle.baseForegroundColor = .white
        startStyle.cornerStyle = .large
        startStyle.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        startStyle.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [weak start] incoming in
            var attributes = incoming
            attributes.font = ScreenFollowAppearance.font(17, weight: .semibold, style: .headline,
                                                         compatibleWith: start?.traitCollection)
            return attributes
        }
        start.configuration = startStyle
        start.setTitle(KKLocalized("Start Live Tracking"), for: .normal)
        start.titleLabel?.adjustsFontForContentSizeCategory = true
        start.titleLabel?.numberOfLines = 0
        start.accessibilityIdentifier = "screenfollow.start"
        start.addTarget(self, action: #selector(startFromSetup), for: .touchUpInside)
        setupStart = start
        let footerNote = UILabel(); configure(footerNote, size: 11, color: ScreenFollowAppearance.secondary)
        footerNote.text = KKLocalized("Keep portrait orientation · Stop broadcasting from the top of the screen"); footerNote.textAlignment = .center
        let footer = UIStackView(arrangedSubviews: [start])
        footer.axis = .vertical; footer.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -20),
            start.heightAnchor.constraint(greaterThanOrEqualToConstant: 54)
        ])

        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        panel.addSubview(scroll)
        let content = UIStackView(); content.axis = .vertical; content.spacing = 20
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        let title = UILabel(); configure(title, size: 28, weight: .bold, color: ScreenFollowAppearance.ink)
        title.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .systemFont(ofSize: 28, weight: .bold), maximumPointSize: 44)
        title.text = KKLocalized("Live Tracking"); title.accessibilityTraits = .header
        let description = UILabel(); configure(description, size: 14, color: ScreenFollowAppearance.secondary)
        description.text = KKLocalized("Let the gimbal follow you in your favorite camera or streaming app.")
        let intro = UIStackView(arrangedSubviews: [title, description]); intro.axis = .vertical; intro.spacing = 8
        content.addArrangedSubview(intro)

        let lensTitle = UILabel(); configure(lensTitle, size: 14, weight: .semibold, color: ScreenFollowAppearance.ink)
        lensTitle.text = KKLocalized("Choose a Camera"); lensTitle.accessibilityTraits = .header
        let front = ScreenFollowLensButton(title: KKLocalized("Front Camera"), detail: KKLocalized("Film Yourself"), symbolName: "person.crop.rectangle")
        let rear = ScreenFollowLensButton(title: KKLocalized("Rear Camera"), detail: KKLocalized("Film Others"), symbolName: "camera")
        front.accessibilityIdentifier = "screenfollow.selectFront"
        rear.accessibilityIdentifier = "screenfollow.selectRear"
        front.addTarget(self, action: #selector(chooseFront), for: .touchUpInside)
        rear.addTarget(self, action: #selector(chooseRear), for: .touchUpInside)
        setupFront = front; setupRear = rear
        let options = UIStackView(arrangedSubviews: [front, rear]); options.spacing = 12; options.distribution = .fillEqually
        lensOptions = options
        updateLensLayout()
        let reminder = UILabel(); configure(reminder, size: 12, color: ScreenFollowAppearance.secondary)
        reminder.text = KKLocalized("Match the camera in your streaming app. Select again after switching cameras.")
        let choices = UIStackView(arrangedSubviews: [lensTitle, options, reminder]); choices.axis = .vertical; choices.spacing = 10
        content.addArrangedSubview(choices)

        let guide = UILabel(); configure(guide, size: 12, color: ScreenFollowAppearance.secondary)
        guide.text = KKLocalized("Choose Camera → Start Screen Broadcast → Open Streaming App")
        content.addArrangedSubview(guide)
        content.setCustomSpacing(6, after: guide)
        func utility(_ title: String, symbol: String, action: Selector) -> UIButton {
            let button = UIButton(type: .system)
            var style = UIButton.Configuration.plain()
            style.title = title; style.image = UIImage(systemName: symbol)
            style.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13)
            style.imagePadding = 5
            style.baseForegroundColor = ScreenFollowAppearance.secondary
            style.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)
            style.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [weak button] incoming in
                var attributes = incoming
                attributes.font = ScreenFollowAppearance.font(12, style: .caption1, compatibleWith: button?.traitCollection)
                return attributes
            }
            button.configuration = style
            button.titleLabel?.numberOfLines = 0
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addTarget(self, action: action, for: .touchUpInside)
            return button
        }
        let help = utility(KKLocalized("Instructions"), symbol: "questionmark.circle", action: #selector(showSetupHelp))
        let settings = utility(KKLocalized("Tracking Settings"), symbol: "slider.horizontal.3", action: #selector(showSettings))
        help.accessibilityIdentifier = "screenfollow.help"
        settings.accessibilityIdentifier = "screenfollow.settings"
        let tools = UIStackView(arrangedSubviews: [help, UIView(), settings]); tools.spacing = 12
        utilityOptions = tools
        content.addArrangedSubview(tools)
        content.addArrangedSubview(footerNote)
        updateLensLayout()
        updateSetupSelection()
    }

    private func updateLensLayout() {
        let accessible = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        lensOptions?.axis = accessible ? .vertical : .horizontal
        utilityOptions?.axis = accessible ? .vertical : .horizontal
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateLensLayout()
        }
    }

    private weak var setupFront: UIButton?
    private weak var setupRear: UIButton?
    private weak var setupStart: UIButton?
    private func updateSetupSelection() {
        setupFront?.isSelected = frontCamera
        setupRear?.isSelected = !frontCamera
    }
    @objc private func chooseFront() { chooseCamera(front: true) }
    @objc private func chooseRear() { chooseCamera(front: false) }
    private func chooseCamera(front: Bool) {
        guard !wantsBroadcastPicker, !engine.broadcastConnected else { return }
        if front != frontCamera, engine.sessionID != nil { engine.stop() }
        frontCamera = front
        updateSetupSelection()
    }
    @objc private func startFromSetup() {
        guard !wantsBroadcastPicker, !isClosing else { return }
        guard disclosureConsentOverride ?? ScreenFollowDisclosureConsent.isAccepted else {
            presentDisclosure()
            return
        }
        beginStartFromSetup()
    }
    private func presentDisclosure() {
        let message = KKLocalized("live_tracking_disclosure")
        let alert = UIAlertController(title: KKLocalized("Start Live Tracking"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: KKLocalized("Decline"), style: .cancel))
        alert.addAction(UIAlertAction(title: KKLocalized("Agree and Continue"), style: .default) { [weak self] _ in
            ScreenFollowDisclosureConsent.accept()
            self?.beginStartFromSetup()
        })
        present(alert, animated: true)
    }
    private func beginStartFromSetup() {
        guard !wantsBroadcastPicker, !isClosing else { return }
        // A new tap after cancelling the native picker must get a full new
        // preparation window and a newly written invitation. Retiring the old
        // session also prevents missing/corrupt files from surviving a retry.
        // Do this before arming wantsBroadcastPicker: stop() calls refresh().
        if !engine.broadcastConnected, engine.sessionID != nil { engine.stop() }
        wantsBroadcastPicker = true
        if engine.sessionID == nil {
            let crop = centerRegion ? CGRect(x: 0, y: 0.15, width: 1, height: 0.7) : CGRect(x: 0, y: 0, width: 1, height: 1)
            do {
                try engine.prepare(frontCamera: frontCamera, reverseYaw: reverseYaw, reversePitch: reversePitch, crop: crop)
            } catch {
                // A listener failure can first notify refresh through stop().
                // Do not present the same failure again after prepare throws.
                if wantsBroadcastPicker {
                    wantsBroadcastPicker = false
                    showMessage(title: KKLocalized("Unable to Start Tracking"), message: error.localizedDescription)
                }
            }
        }
        refresh()
    }
    private func openBroadcastPickerIfReady() {
        guard wantsBroadcastPicker, engine.readyForBroadcast, view.window != nil,
              UIApplication.shared.applicationState == .active,
              presentedViewController == nil, !isClosing else { return }
        // Consume this tap before presenting; repeated engine updates must not
        // reopen the system sheet. A cancelled sheet can be retried with a new tap.
        wantsBroadcastPicker = false
        kkLog("[ScreenFollowSession] picker session=\(engine.sessionID?.uuidString ?? "none") connected=\(engine.broadcastConnected)")
        setupStart?.isEnabled = true
        setupStart?.setTitle(engine.broadcastConnected ? KKLocalized("View Broadcast Status") : KKLocalized("Start Live Tracking"), for: .normal)
        setupFront?.isEnabled = !engine.broadcastConnected
        setupRear?.isEnabled = !engine.broadcastConnected
        if !broadcastPickerPresenter(picker) {
            showMessage(title: KKLocalized("Unable to Open Screen Broadcast"), message: KKLocalized("Tap Start Live Tracking again in Gimbal Tracking."))
        }
    }
    @objc private func showSetupHelp() {
        let alert = UIAlertController(title: KKLocalized("Live Tracking"),
                                      message: KKLocalized("live_tracking_help"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: KKLocalized("Tracking Settings"), style: .default) { [weak self] _ in self?.showSettings() })
        alert.addAction(UIAlertAction(title: KKLocalized("Got it"), style: .cancel))
        present(alert, animated: true)
    }

    private func configure(_ label: UILabel, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = .black) {
        label.numberOfLines = 0; label.textAlignment = .natural; label.textColor = color
        label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: size, weight: weight))
        label.adjustsFontForContentSizeCategory = true
    }
    @objc private func close() {
        guard !isClosing else { return }
        isClosing = true; wantsBroadcastPicker = false
        // Returning to the home page must not terminate an ongoing screen broadcast.
        if !engine.broadcastConnected { engine.stop() }
        engine.onUpdate = nil; engine.configurationVisible = false
        dismiss(animated: true, completion: onReturnToCamera)
    }
    private func refresh() {
        guard !isClosing else { return }
        if wantsBroadcastPicker, engine.sessionID == nil {
            wantsBroadcastPicker = false
            showMessage(title: KKLocalized("Unable to Start Tracking"), message: engine.diagnostics.message)
        }
        setupFront?.isEnabled = !wantsBroadcastPicker && !engine.broadcastConnected
        setupRear?.isEnabled = !wantsBroadcastPicker && !engine.broadcastConnected
        setupStart?.isEnabled = !wantsBroadcastPicker
        setupStart?.setTitle(wantsBroadcastPicker ? KKLocalized("Preparing…") : engine.broadcastConnected ? KKLocalized("View Broadcast Status") : KKLocalized("Start Live Tracking"), for: .normal)
        updateSetupSelection()
        openBroadcastPickerIfReady()
    }
    @objc private func showSettings() {
        let active = engine.sessionID != nil
        let sheet = UIAlertController(title: KKLocalized("Live Tracking Settings"), message: active ? KKLocalized("Stop tracking before changing the detection area or direction.") : nil, preferredStyle: .actionSheet)
        func option(_ title: String, action: @escaping () -> Void) {
            let item = UIAlertAction(title: title, style: .default) { _ in action() }
            item.isEnabled = !active; sheet.addAction(item)
        }
        option(KKLocalizedFormat("Detection Area: %@", centerRegion ? KKLocalized("Center Area") : KKLocalized("Entire Frame"))) { self.centerRegion.toggle() }
        option(KKLocalizedFormat("Reverse Left/Right: %@", KKLocalized(reverseYaw ? "open" : "close"))) { self.reverseYaw.toggle() }
        option(KKLocalizedFormat("Reverse Up/Down: %@", KKLocalized(reversePitch ? "open" : "close"))) { self.reversePitch.toggle() }
        sheet.addAction(UIAlertAction(title: KKLocalized("View Diagnostics"), style: .default) { [weak self] _ in self?.showDiagnostics() })
        sheet.addAction(UIAlertAction(title: KKLocalized("Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 44, width: 1, height: 1)
        present(sheet, animated: true)
    }
    private func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: KKLocalized("Got it"), style: .default)); present(alert, animated: true)
    }
    private func showDiagnostics() {
        let d = engine.diagnostics
        let message = d.message + "\n\n" + KKLocalizedFormat("live_tracking_diagnostics_format", d.frames, d.detectedFrames, d.noFaceFrames, d.submittedMotion, d.acknowledgements, Int(d.averageLatencyMS), Int(d.maximumLatencyMS))
        let alert = UIAlertController(title: KKLocalized("Tracking Diagnostics"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: KKLocalized("Share Diagnostics"), style: .default) { [weak self] _ in
            guard let self, let data = try? JSONEncoder().encode(d), let text = String(data: data, encoding: .utf8) else { return }
            let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = view
            controller.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 44, width: 1, height: 1)
            present(controller, animated: true)
        })
        alert.addAction(UIAlertAction(title: KKLocalized("Close"), style: .cancel)); present(alert, animated: true)
    }
}

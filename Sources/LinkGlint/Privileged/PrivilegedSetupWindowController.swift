import AppKit

enum PrivilegedSetupPhase: Equatable {
    case guidance(PrivilegedAccessGuidance)
    case busy(PrivilegedAccessGuidance)
    case completed
}

enum PrivilegedAccessCompletionCopy {
    static let title = "已启用免密码切换"
    static let message = "之后切换网络、修改 DNS 和调整优先级都不会再询问密码。"
    static let actionTitle = "开始使用 LinkGlint"
}

/// Blocking first-run / repair sheet. Cannot be dismissed except by completing
/// configuration or quitting the app.
final class PrivilegedSetupWindowController: NSWindowController {
    var onConfigure: (() -> Void)?
    var onQuit: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton(title: "开始配置", target: nil, action: nil)
    private let quitButton = NSButton(title: "退出 LinkGlint", target: nil, action: nil)
    private let iconView = NSImageView()
    private let iconBackdrop = NSView()
    private let cardBox = NSBox()
    private var phase: PrivilegedSetupPhase = .guidance(.firstRun)
    private var completionHandler: (() -> Void)?

    var currentPhase: PrivilegedSetupPhase { phase }
    var primaryButtonTitle: String { primaryButton.title }
    var isQuitButtonHidden: Bool { quitButton.isHidden }

    convenience init(guidance: PrivilegedAccessGuidance) {
        self.init(panelContentRect: NSRect(x: 0, y: 0, width: 400, height: 320))
        apply(phase: .guidance(guidance))
    }

    /// Standalone completion panel when setup was already dismissed.
    convenience init(completionOnly: Bool) {
        precondition(completionOnly)
        self.init(panelContentRect: NSRect(x: 0, y: 0, width: 400, height: 320))
        showCompletion(onDismiss: nil)
    }

    private init(panelContentRect: NSRect) {
        let panel = NSPanel(
            contentRect: panelContentRect,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "LinkGlint"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: panel)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isWindowVisible: Bool {
        window?.isVisible == true
    }

    func apply(guidance: PrivilegedAccessGuidance) {
        guard phase != .completed else { return }
        apply(phase: .guidance(guidance))
    }

    func apply(phase newPhase: PrivilegedSetupPhase) {
        phase = newPhase
        switch newPhase {
        case .guidance(let guidance):
            titleLabel.stringValue = guidance.setupTitle
            messageLabel.stringValue = guidance.setupMessage
            primaryButton.title = guidance.primaryActionTitle
            primaryButton.action = #selector(configureTapped)
            primaryButton.isEnabled = true
            quitButton.isHidden = false
            statusLabel.isHidden = statusLabel.stringValue.isEmpty
            applyVisualStyle(for: guidance, completed: false)
        case .busy(let guidance):
            titleLabel.stringValue = guidance.setupTitle
            messageLabel.stringValue = guidance.setupMessage
            primaryButton.title = guidance.primaryActionTitle
            primaryButton.action = #selector(configureTapped)
            primaryButton.isEnabled = false
            quitButton.isHidden = false
            statusLabel.stringValue = "正在等待 macOS 完成管理员授权…"
            statusLabel.isHidden = false
            applyVisualStyle(for: guidance, completed: false)
        case .completed:
            titleLabel.stringValue = PrivilegedAccessCompletionCopy.title
            messageLabel.stringValue = PrivilegedAccessCompletionCopy.message
            primaryButton.title = PrivilegedAccessCompletionCopy.actionTitle
            primaryButton.action = #selector(completionTapped)
            primaryButton.isEnabled = true
            quitButton.isHidden = true
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
            applyVisualStyle(for: nil, completed: true)
        }
    }

    func setBusy(_ busy: Bool) {
        guard phase != .completed else { return }
        let guidance: PrivilegedAccessGuidance
        switch phase {
        case .guidance(let value), .busy(let value):
            guidance = value
        case .completed:
            return
        }
        apply(phase: busy ? .busy(guidance) : .guidance(guidance))
    }

    func setStatus(_ text: String) {
        guard phase != .completed else { return }
        if case .busy = phase {
            apply(phase: .guidance(currentGuidance))
        }
        primaryButton.isEnabled = true
        quitButton.isEnabled = true
        statusLabel.stringValue = text
        statusLabel.isHidden = text.isEmpty
    }

    func showCompletion(onDismiss: (() -> Void)?) {
        completionHandler = onDismiss
        apply(phase: .completed)
    }

    /// Show and activate only when the window is newly presented.
    func presentStealingFocus() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Keep an already-visible setup window in place without re-centering or stealing focus.
    func refreshInPlace() {
        guard let window else { return }
        if !window.isVisible {
            presentStealingFocus()
            return
        }
        window.orderFrontRegardless()
    }

    private var currentGuidance: PrivilegedAccessGuidance {
        switch phase {
        case .guidance(let guidance), .busy(let guidance):
            return guidance
        case .completed:
            return .none
        }
    }

    private func applyVisualStyle(for guidance: PrivilegedAccessGuidance?, completed: Bool) {
        let accent: NSColor
        let symbol: String
        if completed {
            accent = .systemGreen
            symbol = "checkmark.shield.fill"
        } else if guidance == .repair {
            accent = .systemOrange
            symbol = "exclamationmark.shield.fill"
        } else {
            accent = .controlAccentColor
            symbol = "lock.shield.fill"
        }
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.contentTintColor = accent
        iconBackdrop.layer?.backgroundColor = accent.withAlphaComponent(0.12).cgColor
        cardBox.borderColor = accent.withAlphaComponent(completed ? 0.50 : 0.45)
        cardBox.fillColor = accent.withAlphaComponent(completed ? 0.08 : 0.06)
        primaryButton.contentTintColor = accent
    }

    private func buildContent() {
        guard let panel = window as? NSPanel else { return }

        let effect = NSVisualEffectView()
        effect.material = .contentBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = effect

        cardBox.boxType = .custom
        cardBox.cornerRadius = LinkGlintLayout.sectionRadius
        cardBox.borderWidth = 1
        cardBox.translatesAutoresizingMaskIntoConstraints = false

        iconBackdrop.wantsLayer = true
        iconBackdrop.layer?.cornerRadius = 28
        iconBackdrop.translatesAutoresizingMaskIntoConstraints = false

        iconView.symbolConfiguration = .init(pointSize: 28, weight: .semibold)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setAccessibilityElement(false)

        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        titleLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 12.5)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.isHidden = true

        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self
        primaryButton.action = #selector(configureTapped)
        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quitTapped)

        let iconStack = NSView()
        iconStack.translatesAutoresizingMaskIntoConstraints = false
        iconStack.addSubview(iconBackdrop)
        iconStack.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconBackdrop.widthAnchor.constraint(equalToConstant: 56),
            iconBackdrop.heightAnchor.constraint(equalToConstant: 56),
            iconBackdrop.centerXAnchor.constraint(equalTo: iconStack.centerXAnchor),
            iconBackdrop.centerYAnchor.constraint(equalTo: iconStack.centerYAnchor),
            iconView.centerXAnchor.constraint(equalTo: iconBackdrop.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBackdrop.centerYAnchor),
            iconStack.widthAnchor.constraint(equalToConstant: 56),
            iconStack.heightAnchor.constraint(equalToConstant: 56)
        ])

        let buttons = NSStackView(views: [quitButton, primaryButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY

        let stack = NSStackView(views: [iconStack, titleLabel, messageLabel, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        cardBox.contentView?.addSubview(stack)
        effect.addSubview(cardBox)

        NSLayoutConstraint.activate([
            cardBox.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            cardBox.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),
            cardBox.topAnchor.constraint(equalTo: effect.topAnchor, constant: 28),
            cardBox.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: cardBox.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: cardBox.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: cardBox.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: cardBox.contentView!.bottomAnchor, constant: -20),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        ])
        primaryButton.setContentHuggingPriority(.required, for: .horizontal)
        quitButton.setContentHuggingPriority(.required, for: .horizontal)
    }

    @objc private func configureTapped() {
        onConfigure?()
    }

    @objc private func quitTapped() {
        onQuit?()
    }

    @objc private func completionTapped() {
        let handler = completionHandler
        completionHandler = nil
        handler?()
    }
}

enum PrivilegedSetupPresentationPolicy {
    /// Whether presenting setup should center/activate the window.
    static func shouldStealFocus(
        windowAlreadyVisible: Bool,
        previousGuidance: PrivilegedAccessGuidance?,
        newGuidance: PrivilegedAccessGuidance
    ) -> Bool {
        guard newGuidance.requiresBlockingSetup else { return false }
        if windowAlreadyVisible, previousGuidance == newGuidance {
            return false
        }
        return true
    }

    /// The completion panel must stay up until the user taps through it.
    static func shouldDismissSetupWhenAccessReady(currentPhase: PrivilegedSetupPhase?) -> Bool {
        currentPhase != .completed
    }
}

enum PrivilegedBlockedInteractionPolicy {
    enum Action: Equatable {
        case presentSetup
        case presentRestrictedMenu
        case continueNormally
    }

    static func action(blocked: Bool, rightClick: Bool) -> Action {
        guard blocked else { return .continueNormally }
        return rightClick ? .presentRestrictedMenu : .presentSetup
    }
}

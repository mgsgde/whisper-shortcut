//
//  PopupNotificationWindow.swift
//  WhisperShortcut
//
//  A custom notification window that appears in the bottom-left corner of the screen
//  with smooth animations and auto-hide functionality.
//
//  IMPORTANT BEHAVIOR NOTES:
//  - macOS automatically repositions windows after show() - position correction required
//  - macOS does NOT override styling properties (borders, shadows, etc.) - no correction needed
//  - Tested and documented 2025-09-15 via systematic debugging
//

import AppKit
import Foundation

// Custom view that handles clicks for error feedback
class ClickableContentView: NSView {
  var onClickHandler: (() -> Void)?

  override func mouseDown(with event: NSEvent) {
    onClickHandler?()
    super.mouseDown(with: event)
  }
}

/// NSButton that shows the pointing-hand cursor on hover.
private class PointerCursorButton: NSButton {
  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: NSCursor.pointingHand)
  }
}

/// Which popup this window is. Replaces the old independent `isError` / `isInfo` /
/// `isCancelled` / `isProcessing` flags, whose priority (first match wins) was
/// cancelled → info → processing → error → success.
enum PopupKind: Equatable {
  case success
  case info
  case error
  case cancelled
  case processing

  /// Glyph shown in the leading icon label. Error has none (Contact Support is the affordance).
  var iconText: String {
    switch self {
    case .cancelled: return "⏸️"
    case .info: return "ℹ️"
    case .processing: return "⏳"
    case .error: return ""
    case .success: return "✅"
    }
  }

  /// Error popups always include Contact Support, so the layout reserves a button row.
  var hasActionButtons: Bool { self == .error }

  /// Auto-hide interval, or nil when no timer should be scheduled.
  ///
  /// Processing never auto-hides. An error with Sign in, Retry, or Top up does not either
  /// (Contact Support alone does not suppress the timer). A positive `customDisplayDuration`
  /// wins over the saved notification / error durations. Saved values are honoured only when
  /// they are a `NotificationDuration` raw value; otherwise the settings default applies.
  func autoHideInterval(
    customDisplayDuration: TimeInterval?,
    savedNotificationDuration: TimeInterval,
    savedErrorDuration: TimeInterval,
    suppressesAutoHide: Bool
  ) -> TimeInterval? {
    if self == .processing { return nil }
    if self == .error && suppressesAutoHide { return nil }
    if let custom = customDisplayDuration, custom > 0 { return custom }
    switch self {
    case .error:
      return Self.resolvedDuration(saved: savedErrorDuration, fallback: SettingsDefaults.errorNotificationDuration)
    case .success, .info, .cancelled:
      return Self.resolvedDuration(saved: savedNotificationDuration, fallback: SettingsDefaults.notificationDuration)
    case .processing:
      return nil
    }
  }

  private static func resolvedDuration(saved: TimeInterval, fallback: NotificationDuration) -> TimeInterval {
    if saved > 0, let duration = NotificationDuration(rawValue: saved) {
      return duration.rawValue
    }
    return fallback.rawValue
  }
}

class PopupNotificationWindow: NSWindow {

  // MARK: - Constants
  private enum Constants {
    // Window sizing: wider and flatter for less intrusive appearance
    static let minWindowWidth: CGFloat = 320  // Minimum width for notifications
    static let maxWindowWidth: CGFloat = 550  // Maximum width for very long content
    static let defaultWindowWidth: CGFloat = 420  // Default width for medium content
    static let maxHeight: CGFloat = 250  // Reduced height for flatter appearance
    static let minHeight: CGFloat = 80  // Reduced minimum height
    static let cornerRadius: CGFloat = 12  // Modern macOS corner radius
    static let shadowRadius: CGFloat = 8  // Subtle shadow like native macOS notifications
    static let shadowOpacity: Float = 0.15  // Very subtle, barely visible shadow
    static let animationDuration: TimeInterval = 0.25  // Smoother animation
    static let outerPadding: CGFloat = 20  // Generous outer padding
    static let innerPadding: CGFloat = 16  // Inner content padding
    static let titleBottomSpacing: CGFloat = 16  // More space between title and text
    static let iconSpacing: CGFloat = 12  // Better spacing between icon and text
    static let titleFontSize: CGFloat = 15  // Slightly larger for better readability
    static let textFontSize: CGFloat = 13  // Better readable text size
    static let maxPreviewLength = 180  // Even longer preview for better readability
    static let horizontalMargin: CGFloat = 18  // Distance from left/right screen edges
    static let verticalMarginTop: CGFloat = 6   // Distance from top screen edge
    static let verticalMarginBottom: CGFloat = 30  // Distance from bottom screen edge
    // Extra bottom offset for center-bottom so popups sit above the recording
    // indicator pill (40pt tall at 28pt margin) instead of covering it.
    static let centerBottomPillClearance: CGFloat = 50
    static let iconAndSpacingWidth: CGFloat = 28  // Icon width + spacing for layout calculations
  }

  // MARK: - Properties
  private var customContentView: NSView!
  private var iconLabel: NSTextField!
  private var titleLabel: NSTextField!
  private var modelInfoLabel: NSTextField!
  private var textLabel: NSTextField!
  private var scrollView: NSScrollView!
  private var whatsappIcon: NSImageView?
  private var closeButton: NSButton!
  /// Sign in, Retry, Top up, Contact Support — visual order, left to right. Empty unless `.error`.
  private var actionButtons: [NSButton] = []
  private var autoHideTimer: Timer?
  private let kind: PopupKind
  private var errorText: String = ""
  private var retryAction: (() -> Void)?
  /// Label for the action button driven by `retryAction`. Defaults to "Retry";
  /// callers whose action isn't a retry (e.g. opening System Settings) override it.
  private var retryActionTitle: String = "Retry"
  private var dismissAction: (() -> Void)?
  private var signInAction: (() -> Void)?
  private var wasRetried: Bool = false
  private var customDisplayDuration: TimeInterval?
  private var topUpURL: URL?

  // MARK: - Initialization
  init(title: String, text: String, kind: PopupKind = .success, modelInfo: String? = nil, retryAction: (() -> Void)? = nil, retryActionTitle: String = "Retry", dismissAction: (() -> Void)? = nil, signInAction: (() -> Void)? = nil, customDisplayDuration: TimeInterval? = nil, topUpURL: URL? = nil) {
    self.kind = kind
    // Create window with specific style for notifications
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: Constants.defaultWindowWidth, height: 100),
      styleMask: [],  // Completely borderless for custom styling
      backing: .buffered,
      defer: false
    )

    self.errorText = text
    self.retryAction = retryAction
    self.retryActionTitle = retryActionTitle
    self.dismissAction = dismissAction
    self.signInAction = signInAction
    self.customDisplayDuration = customDisplayDuration
    self.topUpURL = topUpURL

    setupWindow()
    setupContentView()
    setupCloseButton()
    setupIcon()
    setupLabels(title: title, text: text, modelInfo: modelInfo)
    setupScrollView()
    if kind == .error {
      var buttons: [NSButton] = []
      if signInAction != nil {
        buttons.append(makeActionButton(title: "Sign in with Google", action: #selector(signInButtonClicked)))
      }
      if retryAction != nil {
        buttons.append(makeActionButton(title: retryActionTitle, action: #selector(retryButtonClicked)))
      }
      if topUpURL != nil {
        buttons.append(makeActionButton(title: "Top up", action: #selector(topUpButtonClicked)))
      }
      buttons.append(makeActionButton(title: "Contact Support", action: #selector(whatsappButtonClicked)))
      actionButtons = buttons
    }
    layoutContent()

    // Success, info, cancelled, and processing: click to close. Error: only close on button or click outside text.
    if kind != .error {
      setupSuccessClickHandler()
    }

    startAutoHideTimer()
  }

  // MARK: - Setup Methods
  private func setupWindow() {
    // Window properties
    isOpaque = false
    backgroundColor = NSColor.clear
    level = .statusBar  // Use highest level to ensure visibility above all windows
    ignoresMouseEvents = false
    hasShadow = true
    isMovable = false
    isMovableByWindowBackground = false
    // CRITICAL: Prevent window from causing app termination
    collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    hidesOnDeactivate = false  // Don't hide when app loses focus

    // CRITICAL: Prevent this window from becoming main window or causing termination
    // These are implemented as override methods below

    // Initial positioning will be handled in show() method
  }

  private func setupContentView() {
    // Create container view for proper shadow/corner radius separation
    let containerView = NSView()
    containerView.wantsLayer = true

    // Apply shadow to container (not masked)
    containerView.layer?.shadowColor = NSColor.black.cgColor
    containerView.layer?.shadowOffset = NSSize(width: 0, height: -2)  // Shadow above for bottom positioning
    containerView.layer?.shadowRadius = Constants.shadowRadius
    containerView.layer?.shadowOpacity = Constants.shadowOpacity
    containerView.layer?.masksToBounds = false  // Allow shadow to show

    // Create custom background view with clean styling
    let backgroundView = NSView()
    backgroundView.wantsLayer = true

    // Create a clean, solid background with transparency
    backgroundView.layer?.backgroundColor =
      NSColor.controlBackgroundColor.withAlphaComponent(0.95).cgColor
    backgroundView.layer?.cornerRadius = Constants.cornerRadius
    backgroundView.layer?.masksToBounds = true

    // Ensure absolutely no borders
    backgroundView.layer?.borderWidth = 0
    backgroundView.layer?.borderColor = NSColor.clear.cgColor

    // Add background view to container
    containerView.addSubview(backgroundView)
    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      backgroundView.topAnchor.constraint(equalTo: containerView.topAnchor),
      backgroundView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
    ])

    // Create clickable content view for error feedback
    let clickableView = ClickableContentView()
    clickableView.translatesAutoresizingMaskIntoConstraints = false
    backgroundView.addSubview(clickableView)

    // Make clickable view fill the entire background view
    NSLayoutConstraint.activate([
      clickableView.topAnchor.constraint(equalTo: backgroundView.topAnchor),
      clickableView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
      clickableView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
      clickableView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),
    ])

    customContentView = clickableView
    contentView = containerView
  }

  private func setupCloseButton() {
    closeButton = PointerCursorButton()
    closeButton.title = ""
    closeButton.bezelStyle = .circular
    closeButton.isBordered = false
    closeButton.wantsLayer = true
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    
    // Create a close symbol (X)
    let closeSymbol = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
    closeButton.image = closeSymbol
    closeButton.imagePosition = .imageOnly
    closeButton.contentTintColor = NSColor.secondaryLabelColor
    
    // Make button slightly transparent
    closeButton.alphaValue = 0.6
    
    // Add hover effect
    closeButton.layer?.cornerRadius = 10
    
    // Set action
    closeButton.target = self
    closeButton.action = #selector(closeButtonClicked)
    
    // Size constraints
    closeButton.setContentHuggingPriority(.required, for: .horizontal)
    closeButton.setContentHuggingPriority(.required, for: .vertical)
  }

  @objc private func closeButtonClicked() {
    hide()
  }

  private func makeActionButton(title: String, action: Selector) -> PointerCursorButton {
    let button = PointerCursorButton()
    button.title = title
    button.bezelStyle = .rounded
    button.isBordered = true
    button.wantsLayer = true
    button.translatesAutoresizingMaskIntoConstraints = false
    button.target = self
    button.action = action
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    return button
  }

  @objc private func retryButtonClicked() {
    // Mark that retry was clicked
    wasRetried = true
    // Execute retry action
    retryAction?()
    // Close the window (don't call dismissAction since we're retrying)
    hide()
  }

  @objc private func topUpButtonClicked() {
    if let url = topUpURL {
      NSWorkspace.shared.open(url)
    }
    hide()
  }

  @objc private func signInButtonClicked() {
    signInAction?()
    hide()
  }

  private func setupIcon() {
    iconLabel = makeLabel(
      kind.iconText,
      fontSize: 16,
      weight: .medium,
      textColor: .labelColor,
      alignment: .center,
      truncates: false,
      hugHorizontally: true
    )
  }

  private func setupLabels(title: String, text: String, modelInfo: String?) {
    titleLabel = makeLabel(
      title,
      fontSize: Constants.titleFontSize,
      weight: .medium,
      textColor: .labelColor,
      alignment: .left,
      truncates: true,
      hugHorizontally: false
    )

    // Model info is omitted for error and info popups (same as the old `!isError, !isInfo` check).
    if let modelInfo = modelInfo, kind != .error, kind != .info {
      modelInfoLabel = makeLabel(
        "🤖 \(modelInfo)",
        fontSize: 11,
        weight: .regular,
        textColor: .secondaryLabelColor,
        alignment: .left,
        truncates: true,
        hugHorizontally: false
      )
    } else {
      modelInfoLabel = nil
    }

    // Text field with improved readability and text selection support
    let displayText = createPreviewText(from: text)

    // Use NSTextField (not label) to allow text selection
    textLabel = NSTextField()
    textLabel.attributedStringValue = bodyAttributedString(displayText)
    textLabel.isEditable = false
    textLabel.isSelectable = true  // Allow text selection for copy/paste
    textLabel.isBordered = false
    textLabel.backgroundColor = NSColor.clear
    textLabel.drawsBackground = false
    textLabel.lineBreakMode = .byWordWrapping
    textLabel.maximumNumberOfLines = 0  // Unlimited lines
    textLabel.translatesAutoresizingMaskIntoConstraints = false
    
    textLabel.preferredMaxLayoutWidth =
      Constants.defaultWindowWidth - (Constants.outerPadding * 2) - Constants.iconAndSpacingWidth
  }

  private func makeLabel(
    _ text: String,
    fontSize: CGFloat,
    weight: NSFont.Weight,
    textColor: NSColor,
    alignment: NSTextAlignment,
    truncates: Bool,
    hugHorizontally: Bool
  ) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
    label.textColor = textColor
    label.alignment = alignment
    label.isEditable = false
    label.isBordered = false
    label.backgroundColor = NSColor.clear
    label.translatesAutoresizingMaskIntoConstraints = false
    if truncates {
      label.lineBreakMode = .byTruncatingTail
      label.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    if hugHorizontally {
      label.setContentHuggingPriority(.required, for: .horizontal)
      label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    return label
  }

  private func bodyAttributedString(_ string: String) -> NSAttributedString {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = 3
    paragraphStyle.paragraphSpacing = 6
    return NSAttributedString(
      string: string,
      attributes: [
        .font: NSFont.systemFont(ofSize: Constants.textFontSize, weight: .regular),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraphStyle,
      ]
    )
  }

  @objc private func whatsappButtonClicked() {
    openWhatsAppFeedback()
  }

  private func setupSuccessClickHandler() {
    if let clickableView = customContentView as? ClickableContentView {
      clickableView.onClickHandler = { [weak self] in
        self?.successWindowClicked()
      }
    }

    customContentView.wantsLayer = true
  }

  @objc private func successWindowClicked() {
    // Success notifications no longer open history
    self.hide()
  }

  /// The highest-signal report the app can collect: something just failed, the user is annoyed,
  /// and the error text is right there to attach. `FeedbackLinks` adds the version and OS so the
  /// report doesn't need a round-trip before it can be acted on.
  private func openWhatsAppFeedback() {
    FeedbackLinks.open(
      .whatsApp,
      context: "I encountered this error:\n\n\(FeedbackLinks.truncated(errorText, limit: 500))")
  }


  private func setupScrollView() {
    scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.verticalScrollElasticity = .allowed
    scrollView.horizontalScrollElasticity = .none

    // Add text label to scroll view
    scrollView.documentView = textLabel

    // Ensure the text label can expand properly
    textLabel.setContentHuggingPriority(.defaultLow, for: .vertical)
    textLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    
    // Set minimum height for scroll view to ensure it's always visible
    scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
    scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
  }

  private func layoutContent() {
    // Add subviews
    customContentView.addSubview(closeButton)
    customContentView.addSubview(iconLabel)
    customContentView.addSubview(titleLabel)
    
    // Add model info label if it exists
    if let modelInfoLabel = modelInfoLabel {
      customContentView.addSubview(modelInfoLabel)
    }
    
    customContentView.addSubview(scrollView)

    for button in actionButtons {
      customContentView.addSubview(button)
    }

    // Set up constraints with improved spacing
    NSLayoutConstraint.activate([
      // Close button constraints (top-right corner)
      closeButton.topAnchor.constraint(
        equalTo: customContentView.topAnchor, constant: 8),
      closeButton.trailingAnchor.constraint(
        equalTo: customContentView.trailingAnchor, constant: -8),
      closeButton.widthAnchor.constraint(equalToConstant: 20),
      closeButton.heightAnchor.constraint(equalToConstant: 20),
      
      // Icon constraints
      iconLabel.topAnchor.constraint(
        equalTo: customContentView.topAnchor, constant: Constants.outerPadding),
      iconLabel.leadingAnchor.constraint(
        equalTo: customContentView.leadingAnchor, constant: Constants.outerPadding),
      iconLabel.widthAnchor.constraint(equalToConstant: 20),  // Fixed width for icon

      // Title label constraints - different spacing based on whether icon exists
      titleLabel.topAnchor.constraint(
        equalTo: customContentView.topAnchor, constant: Constants.outerPadding),

      // Scroll view constraints with better spacing
      scrollView.topAnchor.constraint(
        equalTo: (modelInfoLabel?.bottomAnchor ?? titleLabel.bottomAnchor), 
        constant: Constants.titleBottomSpacing),
      scrollView.leadingAnchor.constraint(
        equalTo: customContentView.leadingAnchor, constant: Constants.outerPadding),

      // Text label width constraint (for proper wrapping)
      textLabel.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
    ])

    // Add model info label constraints if it exists
    if let modelInfoLabel = modelInfoLabel {
      NSLayoutConstraint.activate([
        modelInfoLabel.topAnchor.constraint(
          equalTo: titleLabel.bottomAnchor, constant: 4),
        modelInfoLabel.leadingAnchor.constraint(
          equalTo: titleLabel.leadingAnchor),
        modelInfoLabel.trailingAnchor.constraint(
          equalTo: titleLabel.trailingAnchor),
      ])
    }

    // Set up constraints based on notification type
    if kind == .error {
      // Error notifications: no left icon
      NSLayoutConstraint.activate([
        // Title starts from left edge (no left icon)
        titleLabel.leadingAnchor.constraint(
          equalTo: customContentView.leadingAnchor, constant: Constants.outerPadding),

        // Scroll view spans full width
        scrollView.trailingAnchor.constraint(
          equalTo: customContentView.trailingAnchor, constant: -Constants.outerPadding),
      ])

      // Sign in → Retry → Top up → Contact Support, each chained to the previous leading edge.
      if !actionButtons.isEmpty {
        let buttonSpacing: CGFloat = 8
        let topAnchor = scrollView.bottomAnchor
        var previous: NSButton?
        for button in actionButtons {
          NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            button.bottomAnchor.constraint(
              equalTo: customContentView.bottomAnchor, constant: -Constants.outerPadding),
            button.heightAnchor.constraint(equalToConstant: 28),
          ])
          if let previous {
            button.leadingAnchor.constraint(
              equalTo: previous.trailingAnchor, constant: buttonSpacing).isActive = true
          } else {
            button.leadingAnchor.constraint(
              equalTo: customContentView.leadingAnchor, constant: Constants.outerPadding).isActive = true
          }
          previous = button
        }
      } else {
        // No buttons, scroll view goes to bottom
        NSLayoutConstraint.activate([
          scrollView.bottomAnchor.constraint(
            equalTo: customContentView.bottomAnchor, constant: -Constants.outerPadding),
        ])
      }
    } else {
      // Success notifications: green checkmark on left, close button on right
      NSLayoutConstraint.activate([
        // Title positioned after left icon (leave space for close button)
        titleLabel.leadingAnchor.constraint(
          equalTo: iconLabel.trailingAnchor, constant: Constants.iconSpacing),
        titleLabel.trailingAnchor.constraint(
          lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),

        // Scroll view spans full width
        scrollView.trailingAnchor.constraint(
          equalTo: customContentView.trailingAnchor, constant: -Constants.outerPadding),
        scrollView.bottomAnchor.constraint(
          equalTo: customContentView.bottomAnchor, constant: -Constants.outerPadding),
      ])
    }

    // Calculate and set window size
    updateWindowSize()
  }

  private func updateWindowSize() {
    // Get screen dimensions to ensure popup fits
    guard let screen = NSScreen.main else { return }
    let fullScreenFrame = screen.frame  // Full screen frame for position calculation
    let visibleFrame = screen.visibleFrame  // Visible frame for height calculations
    let maxWindowHeight = min(Constants.maxHeight, visibleFrame.height * 0.8)  // Max 80% of screen height
    
    // Calculate menu bar height (difference between full frame and visible frame at top)
    let menuBarHeight = fullScreenFrame.maxY - visibleFrame.maxY

    // CRITICAL: Calculate optimal width based on text content for dynamic sizing
    // This was the main issue - the width calculation wasn't working properly before
    let optimalWidth = calculateOptimalWidth()
    let windowWidth = min(max(optimalWidth, Constants.minWindowWidth), Constants.maxWindowWidth)
    
    // Calculate available width for text (subtract padding and icon space)
    let availableWidth = windowWidth - (Constants.outerPadding * 2) - Constants.iconAndSpacingWidth

    // Set the preferred max layout width for proper text wrapping
    textLabel.preferredMaxLayoutWidth = availableWidth

    // Force layout to get accurate measurements for all components
    customContentView.layoutSubtreeIfNeeded()
    titleLabel.layoutSubtreeIfNeeded()
    modelInfoLabel?.layoutSubtreeIfNeeded()
    textLabel.layoutSubtreeIfNeeded()

    // Calculate component heights
    let titleHeight = max(titleLabel.intrinsicContentSize.height, iconLabel.intrinsicContentSize.height)
    let modelInfoHeight = modelInfoLabel?.intrinsicContentSize.height ?? 0
    let textContentHeight = textLabel.intrinsicContentSize.height

    // Calculate spacing between components
    let titleToModelSpacing = modelInfoLabel != nil ? 4.0 : 0.0  // Small gap between title and model info
    let modelToTextSpacing = Constants.titleBottomSpacing  // Gap before text content

    // Calculate button height if present (Sign in, Retry, Top up, WhatsApp buttons)
    let hasButtons = !actionButtons.isEmpty
    let buttonHeight = hasButtons ? 28.0 + 12.0 : 0.0  // Button height + spacing
    
    // Calculate total required height
    let requiredHeight = Constants.outerPadding +  // Top padding
                         titleHeight +  // Title height
                         titleToModelSpacing +  // Gap to model info
                         modelInfoHeight +  // Model info height
                         modelToTextSpacing +  // Gap to text
                         textContentHeight +  // Text content height
                         buttonHeight +  // Button height + spacing (for retry and/or WhatsApp buttons)
                         Constants.outerPadding  // Bottom padding

    // Use the larger of required height or minimum height, but cap at max height
    let totalHeight = max(min(requiredHeight, maxWindowHeight), Constants.minHeight)

    // Get position from settings
    let position = getNotificationPosition()
    let (x, y) = calculatePosition(screenFrame: fullScreenFrame, windowWidth: windowWidth, windowHeight: totalHeight, position: position, menuBarHeight: menuBarHeight)

    // Update window frame and position it properly
    let newFrame = NSRect(
      x: x,
      y: y,
      width: windowWidth,
      height: totalHeight
    )

    // CRITICAL FIX: Force immediate frame update without animation for dynamic sizing
    // The original issue was that setFrame with animation didn't work properly for dynamic sizing
    // Using animate: false ensures the window resizes immediately and correctly
    setFrame(newFrame, display: true, animate: false)
    
    // ADDITIONAL FIX: Ensure the window content size is also updated
    // This provides extra assurance that the window is properly sized
    setContentSize(NSSize(width: windowWidth, height: totalHeight))
  }
  
  // MARK: - Position Calculation
  private func getNotificationPosition() -> NotificationPosition {
    if let savedPositionString = UserDefaults.standard.string(forKey: UserDefaultsKeys.notificationPosition),
      let savedPosition = NotificationPosition(rawValue: savedPositionString)
    {
      return savedPosition
    }
    return SettingsDefaults.notificationPosition
  }
  
  private func calculatePosition(screenFrame: NSRect, windowWidth: CGFloat, windowHeight: CGFloat, position: NotificationPosition, menuBarHeight: CGFloat) -> (x: CGFloat, y: CGFloat) {
    let horizontalMargin = Constants.horizontalMargin
    let verticalMarginTop = Constants.verticalMarginTop
    let verticalMarginBottom = Constants.verticalMarginBottom
    
    switch position {
    case .leftBottom:
      return (
        x: screenFrame.minX + horizontalMargin,
        y: screenFrame.minY + verticalMarginBottom
      )
    case .rightBottom:
      return (
        x: screenFrame.maxX - windowWidth - horizontalMargin,
        y: screenFrame.minY + verticalMarginBottom
      )
    case .leftTop:
      return (
        x: screenFrame.minX + horizontalMargin,
        y: screenFrame.maxY - windowHeight - verticalMarginTop - menuBarHeight
      )
    case .rightTop:
      return (
        x: screenFrame.maxX - windowWidth - horizontalMargin,
        y: screenFrame.maxY - windowHeight - verticalMarginTop - menuBarHeight
      )
    case .centerTop:
      return (
        x: screenFrame.midX - windowWidth / 2,
        y: screenFrame.maxY - windowHeight - verticalMarginTop - menuBarHeight
      )
    case .centerBottom:
      return (
        x: screenFrame.midX - windowWidth / 2,
        y: screenFrame.minY + verticalMarginBottom + Constants.centerBottomPillClearance
      )
    }
  }

  // MARK: - Helper Methods
  private func calculateOptimalWidth() -> CGFloat {
    // Get the text content to analyze
    let textContent = textLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let textLength = textContent.count
    
    // Calculate character width based on system font
    let font = NSFont.systemFont(ofSize: Constants.textFontSize)
    let attributes = [NSAttributedString.Key.font: font]
    let averageCharWidth = "M".size(withAttributes: attributes).width
    
    // Base width calculation (padding + icon space) - this must be included in all calculations
    let baseWidth = (Constants.outerPadding * 2) + Constants.iconAndSpacingWidth
    
    // IMPROVED: More gradual, predictable width calculation with better scaling
    // Use a smooth progression instead of hard category jumps
    
    // Calculate optimal characters per line based on text length (prefer even wider display)
    let optimalCharsPerLine: CGFloat
    if textLength <= 30 {
      // Very short text: wider display
      optimalCharsPerLine = min(CGFloat(textLength) * 1.5, 50)
    } else if textLength <= 80 {
      // Short to medium text: gradual increase
      optimalCharsPerLine = 50 + (CGFloat(textLength - 30) * 0.3) // 50 to 65 chars
    } else if textLength <= 200 {
      // Medium text: wider width
      optimalCharsPerLine = 65 + (CGFloat(textLength - 80) * 0.2) // 65 to 89 chars
    } else {
      // Long text: maximum width for wider display
      optimalCharsPerLine = min(89 + (CGFloat(textLength - 200) * 0.07), 100)
    }
    
    // Calculate final width
    let textWidth = averageCharWidth * optimalCharsPerLine
    let totalWidth = textWidth + baseWidth
    
    // Ensure width stays within bounds
    return max(min(totalWidth, Constants.maxWindowWidth), Constants.minWindowWidth)
  }

  private func createPreviewText(from text: String) -> String {
    // Preserve line breaks in preview text
    // Only normalize excessive whitespace within lines, but keep newlines
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Normalize multiple consecutive newlines to max 2
    let normalizedNewlines = trimmed.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    
    // Normalize spaces/tabs within each line (but preserve newlines)
    let lines = normalizedNewlines.components(separatedBy: "\n")
    let normalizedLines = lines.map { line in
      // Replace multiple consecutive spaces/tabs with single space
      line.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    }
    let cleanText = normalizedLines.joined(separator: "\n")

    // For popup notifications, show more text since we have better sizing now
    let maxLength = Constants.maxPreviewLength * 2  // Double the preview length
    
    if cleanText.count <= maxLength {
      return cleanText
    } else {
      // Find a good break point (end of sentence or word)
      let preview = String(cleanText.prefix(maxLength))
      if let lastSentence = preview.lastIndex(of: "."),
        lastSentence > preview.index(preview.startIndex, offsetBy: 50)
      {
        return String(preview[...lastSentence]) + "..."
      } else if let lastSpace = preview.lastIndex(of: " "),
        lastSpace > preview.index(preview.startIndex, offsetBy: 30)
      {
        return String(preview[...lastSpace]) + "..."
      } else {
        return preview + "..."
      }
    }
  }

  // MARK: - Animation Methods
  func show() {
    // Get screen dimensions for positioning
    guard let screen = NSScreen.main else { return }
    let fullScreenFrame = screen.frame  // Full screen frame for position calculation
    let visibleFrame = screen.visibleFrame
    
    // Calculate menu bar height (difference between full frame and visible frame at top)
    let menuBarHeight = fullScreenFrame.maxY - visibleFrame.maxY
    
    // Get position from settings
    let position = getNotificationPosition()
    let (x, y) = calculatePosition(screenFrame: fullScreenFrame, windowWidth: frame.width, windowHeight: frame.height, position: position, menuBarHeight: menuBarHeight)
    
    // Calculate final target frame
    let targetFrame = NSRect(
      x: x,
      y: y,
      width: frame.width,  // Use current width (already calculated by updateWindowSize)
      height: frame.height
    )
    
    // Set initial state for animation (transparent, but already at final position)
    alphaValue = 0.0
    setFrame(targetFrame, display: false)

    // Show window without stealing focus or becoming main window
    orderFront(nil)

    // CRITICAL: macOS repositions windows after show() - force our position again
    setFrame(targetFrame, display: true)

    // Animate in with fade only (no slide animation)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Constants.animationDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)

      // Animate only alpha (fade in)
      self.animator().alphaValue = 1.0
    }
  }

  func hide() {
    // Cancel auto-hide timer
    autoHideTimer?.invalidate()
    autoHideTimer = nil

    // Animate out
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = Constants.animationDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)

      self.animator().alphaValue = 0.0
      // Slide animation based on position
      let position = self.getNotificationPosition()
      let slideOffset: CGFloat
      switch position {
      case .leftBottom, .rightBottom, .centerBottom:
        slideOffset = -20  // Slide down for bottom positions
      case .leftTop, .rightTop, .centerTop:
        slideOffset = 20   // Slide up for top positions
      }
      self.animator().setFrame(self.frame.offsetBy(dx: 0, dy: slideOffset), display: true)
    }) {
      // Hide window instead of closing to prevent app termination
      self.orderOut(nil)  // Make window invisible

      // Call dismiss action only if:
      // 1. Retry was NOT clicked (wasRetried == false)
      // 2. dismissAction exists (for cleanup when no retry option)
      // 3. retryAction is nil (no retry button was shown, so cleanup is safe)
      // If retryAction exists but retry wasn't clicked, we keep the file for menu retry
      if !self.wasRetried, let dismissAction = self.dismissAction, self.retryAction == nil {
        dismissAction()
      }
      
      // Remove from active popups to allow deallocation
      PopupNotificationWindow.activePopups.remove(self)
    }
  }

  // MARK: - Timer Methods
  private func startAutoHideTimer() {
    let suppressesAutoHide = retryAction != nil || topUpURL != nil || signInAction != nil
    guard let duration = kind.autoHideInterval(
      customDisplayDuration: customDisplayDuration,
      savedNotificationDuration: UserDefaults.standard.double(forKey: UserDefaultsKeys.notificationDuration),
      savedErrorDuration: UserDefaults.standard.double(forKey: UserDefaultsKeys.errorNotificationDuration),
      suppressesAutoHide: suppressesAutoHide
    ) else { return }

    autoHideTimer = Timer.scheduledTimer(
      withTimeInterval: duration, repeats: false
    ) { [weak self] _ in
      DispatchQueue.main.async {
        self?.hide()
      }
    }
  }

  override func close() {
    // Always use hide() for proper cleanup and to prevent app termination
    hide()
  }

  // MARK: - Mouse Events
  override func mouseDown(with event: NSEvent) {
    // Only hide on click if it's not the button areas
    // The buttons will handle their own clicks
    let location = event.locationInWindow
    if actionButtons.contains(where: { $0.frame.contains(location) }) {
      return  // Let the action button handle the click
    }
    // For error popups, don't hide when clicking the text area so the user can select and copy
    if kind == .error {
      let ptInScroll = scrollView.convert(location, from: nil)
      if scrollView.bounds.contains(ptInScroll) {
        makeKey()  // So the text field can become first responder and accept selection
        super.mouseDown(with: event)  // Forward to text field for selection
        return
      }
    }
    // Hide popup when clicked elsewhere
    hide()
  }

  // MARK: - Window Behavior Overrides
  // CRITICAL: Prevent this window from becoming main window or causing app termination
  override var canBecomeMain: Bool {
    return false
  }

  /// Allow error popups to become key so the user can select and copy the error text.
  override var canBecomeKey: Bool {
    return kind == .error
  }

  // MARK: - Cleanup
  deinit {
    autoHideTimer?.invalidate()
  }
}

// MARK: - Convenience Methods
extension PopupNotificationWindow {
  // Static storage for active popups to prevent premature deallocation
  private static var activePopups: Set<PopupNotificationWindow> = []

  // Static storage for the current processing popup (persistent until dismissed)
  private static var processingPopup: PopupNotificationWindow?

  // Helper to check if popup notifications are enabled
  private static var arePopupNotificationsEnabled: Bool {
    let keyExists = UserDefaults.standard.object(forKey: UserDefaultsKeys.showPopupNotifications) != nil
    let value = UserDefaults.standard.bool(forKey: UserDefaultsKeys.showPopupNotifications)

    // Check if the key exists, if not, default to true (enabled)
    if !keyExists {
      return true  // Default to enabled
    }

    return value
  }

  /// Shared tail of every `show*` entry point: bail when popups are disabled, then retain and show.
  private static func present(_ make: () -> PopupNotificationWindow) {
    guard arePopupNotificationsEnabled else { return }
    let popup = make()
    activePopups.insert(popup)
    popup.show()
  }

  private static func showSuccessNotification(
    title: String = "Text Copied to Clipboard", text: String, modelInfo: String? = nil
  ) {
    present {
      PopupNotificationWindow(
        title: title,
        text: text,
        modelInfo: modelInfo
      )
    }
  }

  static func showPromptResponse(
    _ response: String, modelInfo: String? = nil, title: String = "Text Copied to Clipboard"
  ) {
    showSuccessNotification(title: title, text: response, modelInfo: modelInfo)
  }

  static func showTranscriptionResponse(
    _ transcription: String, modelInfo: String? = nil, title: String = "Text Copied to Clipboard"
  ) {
    showSuccessNotification(title: title, text: transcription, modelInfo: modelInfo)
  }

  /// Show an informational popup (ℹ️ icon, auto-dismiss). Use for system messages that are neither success nor error.
  static func showInfo(_ text: String, title: String = "Info", customDisplayDuration: TimeInterval? = nil) {
    present {
      PopupNotificationWindow(
        title: title,
        text: text,
        kind: .info,
        customDisplayDuration: customDisplayDuration
      )
    }
  }

  static func showError(_ error: String, title: String = "Error", retryAction: (() -> Void)? = nil, retryActionTitle: String = "Retry", dismissAction: (() -> Void)? = nil, signInAction: (() -> Void)? = nil, customDisplayDuration: TimeInterval? = nil, topUpURL: URL? = nil) {
    present {
      PopupNotificationWindow(
        title: title,
        text: error,
        kind: .error,
        retryAction: retryAction,
        retryActionTitle: retryActionTitle,
        dismissAction: dismissAction,
        signInAction: signInAction,
        customDisplayDuration: customDisplayDuration,
        topUpURL: topUpURL
      )
    }
  }

  static func showCancelled(_ message: String) {
    present {
      PopupNotificationWindow(
        title: "Cancelled",
        text: message,
        kind: .cancelled
      )
    }
  }

  // MARK: - Processing Popup (Persistent during long operations)

  /// Show a processing popup that stays visible until explicitly dismissed.
  /// Use this for long-running operations like chunked transcription.
  /// - Parameters:
  ///   - message: The processing message to display
  ///   - title: Optional title (defaults to "Processing")
  static func showProcessing(_ message: String, title: String = "Processing") {
    present {
      // Dismiss any existing processing popup. Runs only after the enabled-guard inside `present`.
      dismissProcessing()

      let popup = PopupNotificationWindow(
        title: title,
        text: message,
        kind: .processing
      )
      processingPopup = popup
      return popup
    }
  }

  /// Replaces the body text of a processing popup, keeping the paragraph
  /// styling applied at creation time, and resizes the window to fit.
  private func setProcessingMessage(_ message: String) {
    textLabel?.attributedStringValue = bodyAttributedString(message)
    updateWindowSize()
  }

  /// Show a processing popup, or update the one already on screen.
  ///
  /// `showProcessing` tears the window down and builds a new one, which flickers when called for
  /// every progress tick of a download. Progress reporting wants this instead.
  static func showOrUpdateProcessing(_ message: String, title: String = "Processing") {
    if processingPopup != nil {
      updateProcessingMessage(message)
    } else {
      showProcessing(message, title: title)
    }
  }

  /// Update the message of the current processing popup.
  /// - Parameter message: The new message to display
  static func updateProcessingMessage(_ message: String) {
    guard let popup = processingPopup else {
      // If no processing popup exists, create one
      showProcessing(message)
      return
    }

    // Update the text label, preserving styling and resizing to fit
    popup.setProcessingMessage(message)
  }

  /// Update both title and message of the current processing popup.
  /// - Parameters:
  ///   - title: The new title
  ///   - message: The new message
  static func updateProcessing(title: String, message: String) {
    guard let popup = processingPopup else {
      showProcessing(message, title: title)
      return
    }

    popup.titleLabel?.stringValue = title
    popup.setProcessingMessage(message)
  }

  /// Dismiss the current processing popup.
  static func dismissProcessing() {
    guard let popup = processingPopup else { return }

    popup.close()
    activePopups.remove(popup)
    processingPopup = nil
  }
}

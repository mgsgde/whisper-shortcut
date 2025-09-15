import AppKit
import Foundation

class PopupNotificationWindow: NSWindow {

  // MARK: - Constants
  private enum Constants {
    static let windowWidth: CGFloat = 360  // Slightly wider for better readability
    static let maxHeight: CGFloat = 240  // More space for content
    static let minHeight: CGFloat = 100  // More breathing room
    static let cornerRadius: CGFloat = 12  // Modern macOS corner radius
    static let shadowRadius: CGFloat = 16  // More prominent shadow like macOS
    static let shadowOpacity: Float = 0.25  // Slightly more visible shadow
    static let animationDuration: TimeInterval = 0.25  // Smoother animation
    static let displayDuration: TimeInterval = 7.0  // Comfortable reading time
    static let outerPadding: CGFloat = 20  // Generous outer padding
    static let innerPadding: CGFloat = 16  // Inner content padding
    static let titleBottomSpacing: CGFloat = 12  // More space between title and text
    static let titleFontSize: CGFloat = 15  // Slightly larger for better readability
    static let textFontSize: CGFloat = 13  // Better readable text size
    static let maxPreviewLength = 120  // Slightly longer preview
    static let screenMargin: CGFloat = 40  // More comfortable distance from screen edges
  }

  // MARK: - Properties
  private var customContentView: NSView!
  private var iconLabel: NSTextField!
  private var titleLabel: NSTextField!
  private var textLabel: NSTextField!
  private var scrollView: NSScrollView!
  private var autoHideTimer: Timer?

  // MARK: - Initialization
  init(title: String, text: String) {
    // Create window with specific style
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: Constants.windowWidth, height: 100),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    setupWindow()
    setupContentView()
    setupIcon()
    setupLabels(title: title, text: text)
    setupScrollView()
    layoutContent()

    // Start auto-hide timer
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

    // Position window in top-right corner
    positionWindow()
  }

  private func setupContentView() {
    // Create visual effect view with modern macOS notification style
    let visualEffectView = NSVisualEffectView()

    // Use notification-style material for authentic macOS look
    if #available(macOS 10.14, *) {
      visualEffectView.material = .popover  // More appropriate for notifications
    } else {
      visualEffectView.material = .light
    }

    visualEffectView.blendingMode = .behindWindow
    visualEffectView.state = .active
    visualEffectView.wantsLayer = true

    // Modern macOS styling
    visualEffectView.layer?.cornerRadius = Constants.cornerRadius
    visualEffectView.layer?.masksToBounds = false

    // Enhanced shadow for depth (macOS notification style)
    visualEffectView.layer?.shadowColor = NSColor.black.cgColor
    visualEffectView.layer?.shadowOffset = NSSize(width: 0, height: -2)  // Shadow above for bottom positioning
    visualEffectView.layer?.shadowRadius = Constants.shadowRadius
    visualEffectView.layer?.shadowOpacity = Constants.shadowOpacity

    // Add subtle border for definition
    visualEffectView.layer?.borderWidth = 0.5
    visualEffectView.layer?.borderColor = NSColor.separatorColor.cgColor

    customContentView = visualEffectView
    contentView = customContentView
  }

  private func setupIcon() {
    // Success icon (green checkmark like in status bar)
    iconLabel = NSTextField(labelWithString: "✅")
    iconLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)  // Slightly larger for visibility
    iconLabel.textColor = NSColor.labelColor
    iconLabel.alignment = .center
    iconLabel.isEditable = false
    iconLabel.isBordered = false
    iconLabel.backgroundColor = NSColor.clear
    iconLabel.translatesAutoresizingMaskIntoConstraints = false
    iconLabel.setContentHuggingPriority(.required, for: .horizontal)
    iconLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  private func setupLabels(title: String, text: String) {
    // Title label with improved typography
    titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = NSFont.systemFont(ofSize: Constants.titleFontSize, weight: .semibold)  // Better weight for readability
    titleLabel.textColor = NSColor.labelColor
    titleLabel.alignment = .left
    titleLabel.isEditable = false
    titleLabel.isBordered = false
    titleLabel.backgroundColor = NSColor.clear
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

    // Text label with improved readability
    let displayText = createPreviewText(from: text)

    textLabel = NSTextField(labelWithString: displayText)
    textLabel.font = NSFont.systemFont(ofSize: Constants.textFontSize, weight: .regular)
    textLabel.textColor = NSColor.labelColor  // Use primary label color for better readability
    textLabel.alignment = .left
    textLabel.isEditable = false
    textLabel.isBordered = false
    textLabel.backgroundColor = NSColor.clear
    textLabel.lineBreakMode = .byWordWrapping
    textLabel.maximumNumberOfLines = 0  // Unlimited lines
    textLabel.translatesAutoresizingMaskIntoConstraints = false

    // Better text spacing and readability
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = 2  // Add line spacing for better readability
    paragraphStyle.paragraphSpacing = 4

    let attributedText = NSAttributedString(
      string: displayText,
      attributes: [
        .font: NSFont.systemFont(ofSize: Constants.textFontSize, weight: .regular),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraphStyle,
      ]
    )
    textLabel.attributedStringValue = attributedText

    textLabel.preferredMaxLayoutWidth = Constants.windowWidth - (Constants.outerPadding * 2) - 28  // Account for icon width + spacing
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
  }

  private func layoutContent() {
    // Add subviews
    customContentView.addSubview(iconLabel)
    customContentView.addSubview(titleLabel)
    customContentView.addSubview(scrollView)

    // Set up constraints with improved spacing
    NSLayoutConstraint.activate([
      // Icon constraints
      iconLabel.topAnchor.constraint(
        equalTo: customContentView.topAnchor, constant: Constants.outerPadding),
      iconLabel.leadingAnchor.constraint(
        equalTo: customContentView.leadingAnchor, constant: Constants.outerPadding),
      iconLabel.widthAnchor.constraint(equalToConstant: 20),  // Fixed width for icon

      // Title label constraints with icon spacing
      titleLabel.topAnchor.constraint(
        equalTo: customContentView.topAnchor, constant: Constants.outerPadding),
      titleLabel.leadingAnchor.constraint(
        equalTo: iconLabel.trailingAnchor, constant: 8),  // 8px spacing after icon
      titleLabel.trailingAnchor.constraint(
        equalTo: customContentView.trailingAnchor, constant: -Constants.outerPadding),

      // Scroll view constraints with better spacing
      scrollView.topAnchor.constraint(
        equalTo: titleLabel.bottomAnchor, constant: Constants.titleBottomSpacing),
      scrollView.leadingAnchor.constraint(
        equalTo: customContentView.leadingAnchor, constant: Constants.outerPadding),
      scrollView.trailingAnchor.constraint(
        equalTo: customContentView.trailingAnchor, constant: -Constants.outerPadding),
      scrollView.bottomAnchor.constraint(
        equalTo: customContentView.bottomAnchor, constant: -Constants.outerPadding),

      // Text label width constraint (for proper wrapping)
      textLabel.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
    ])

    // Calculate and set window size
    updateWindowSize()
  }

  private func updateWindowSize() {
    // Get screen dimensions to ensure popup fits
    guard let screen = NSScreen.main else { return }
    let screenFrame = screen.visibleFrame
    let maxWindowHeight = min(Constants.maxHeight, screenFrame.height * 0.7)  // Max 70% of screen height

    // Calculate title height (icon and title are on same line)
    let titleHeight = max(
      titleLabel.intrinsicContentSize.height, iconLabel.intrinsicContentSize.height)
    let availableWidth = Constants.windowWidth - (Constants.outerPadding * 2) - 28  // Account for icon

    // Set the preferred max layout width for proper text wrapping
    textLabel.preferredMaxLayoutWidth = availableWidth

    // Force layout to get accurate text measurements
    textLabel.layoutSubtreeIfNeeded()

    // Calculate text content height with improved spacing
    let textContentHeight = textLabel.intrinsicContentSize.height
    let maxTextHeight =
      maxWindowHeight - Constants.outerPadding - titleHeight - Constants.titleBottomSpacing
      - Constants.outerPadding
    let actualTextHeight = min(textContentHeight, maxTextHeight)

    // Calculate total window height with better spacing
    let totalHeight = max(
      Constants.outerPadding + titleHeight + Constants.titleBottomSpacing + actualTextHeight
        + Constants.outerPadding,
      Constants.minHeight
    )

    // Update window frame and position it properly
    let newFrame = NSRect(
      x: screenFrame.maxX - Constants.windowWidth - 20,
      y: screenFrame.maxY - totalHeight - 50,  // Position from top with margin
      width: Constants.windowWidth,
      height: totalHeight
    )

    setFrame(newFrame, display: true)
  }

  private func positionWindow() {
    guard let screen = NSScreen.main else { return }

    let screenFrame = screen.visibleFrame
    let windowFrame = NSRect(
      x: screenFrame.minX + Constants.screenMargin,  // Standard margin from left edge
      y: screenFrame.minY + Constants.screenMargin,  // Standard margin from bottom
      width: Constants.windowWidth,
      height: Constants.minHeight
    )

    setFrame(windowFrame, display: false)
  }

  // MARK: - Helper Methods
  private func createPreviewText(from text: String) -> String {
    // Clean up text - remove extra whitespace and newlines
    let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n+", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

    // Create short preview
    if cleanText.count <= Constants.maxPreviewLength {
      return cleanText
    } else {
      // Find a good break point (end of sentence or word)
      let preview = String(cleanText.prefix(Constants.maxPreviewLength))
      if let lastSentence = preview.lastIndex(of: "."),
        lastSentence > preview.index(preview.startIndex, offsetBy: 30)
      {
        return String(preview[...lastSentence])
      } else if let lastSpace = preview.lastIndex(of: " "),
        lastSpace > preview.index(preview.startIndex, offsetBy: 20)
      {
        return String(preview[...lastSpace]) + "..."
      } else {
        return preview + "..."
      }
    }
  }

  // MARK: - Animation Methods
  func show() {
    // Set initial alpha and position for bottom-left slide-in
    alphaValue = 0.0
    setFrame(frame.offsetBy(dx: 0, dy: -20), display: false)  // Start below final position

    // Show window without stealing focus or becoming main window
    orderFront(nil)

    // CRITICAL: macOS repositions windows after show() - force our position again
    guard let screen = NSScreen.main else { return }
    let screenFrame = screen.visibleFrame
    let targetFrame = NSRect(
      x: screenFrame.minX + Constants.screenMargin,  // Standard margin from left edge
      y: screenFrame.minY + Constants.screenMargin,  // Standard margin from bottom edge
      width: Constants.windowWidth,
      height: frame.height
    )
    setFrame(targetFrame, display: true)

    // Animate in
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Constants.animationDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)

      self.animator().alphaValue = 1.0
      // No additional frame change needed - we already set the correct position above
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
      self.animator().setFrame(self.frame.offsetBy(dx: 0, dy: -20), display: true)  // Slide down for bottom-left position
    }) {
      // Close window after animation
      self.close()

      // Remove from active popups to allow deallocation
      PopupNotificationWindow.activePopups.remove(self)
    }
  }

  // MARK: - Timer Methods
  private func startAutoHideTimer() {
    autoHideTimer = Timer.scheduledTimer(
      withTimeInterval: Constants.displayDuration, repeats: false
    ) { [weak self] _ in
      DispatchQueue.main.async {
        self?.hide()
      }
    }
  }

  override func close() {

    // If close() is called directly (not from hide()), use hide() for proper cleanup
    hide()
  }

  // MARK: - Mouse Events
  override func mouseDown(with event: NSEvent) {
    // Hide popup when clicked
    hide()
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

  // Helper to check if popup notifications are enabled
  private static var arePopupNotificationsEnabled: Bool {
    let keyExists = UserDefaults.standard.object(forKey: "showPopupNotifications") != nil
    let value = UserDefaults.standard.bool(forKey: "showPopupNotifications")

    // Check if the key exists, if not, default to true (enabled)
    if !keyExists {
      return true  // Default to enabled
    }

    return value
  }

  static func showPromptResponse(_ response: String) {
    guard arePopupNotificationsEnabled else {
      return
    }

    let popup = PopupNotificationWindow(
      title: "Text Copied to Clipboard",
      text: response
    )

    // Keep strong reference until window closes
    activePopups.insert(popup)
    popup.show()
  }

  static func showTranscriptionResponse(_ transcription: String) {
    guard arePopupNotificationsEnabled else {
      return
    }

    let popup = PopupNotificationWindow(
      title: "Text Copied to Clipboard",
      text: transcription
    )

    // Keep strong reference until window closes
    activePopups.insert(popup)
    popup.show()
  }

  static func showVoiceResponse(_ response: String) {
    guard arePopupNotificationsEnabled else {
      return
    }

    let popup = PopupNotificationWindow(
      title: "Text Copied to Clipboard",
      text: response
    )

    // Keep strong reference until window closes
    activePopups.insert(popup)
    popup.show()
  }
}

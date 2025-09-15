import AppKit
import Foundation

class PopupNotificationWindow: NSWindow {

  // MARK: - Constants
  private enum Constants {
    static let windowWidth: CGFloat = 320  // Compact like macOS notifications
    static let maxHeight: CGFloat = 200  // Smaller max height
    static let minHeight: CGFloat = 80  // Smaller min height
    static let cornerRadius: CGFloat = 10
    static let shadowRadius: CGFloat = 12  // Subtler shadow
    static let shadowOpacity: Float = 0.2  // Less prominent shadow
    static let animationDuration: TimeInterval = 0.2  // Faster animation
    static let displayDuration: TimeInterval = 5.0  // Comfortable reading time
    static let padding: CGFloat = 16  // Tighter padding
    static let titleFontSize: CGFloat = 14  // Smaller title
    static let textFontSize: CGFloat = 12  // Smaller text
    static let maxPreviewLength = 100  // Short preview only
    static let screenMargin: CGFloat = 40  // More comfortable distance from screen edges
  }

  // MARK: - Properties
  private var customContentView: NSView!
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
    // Create visual effect view for modern blur effect
    let visualEffectView = NSVisualEffectView()
    visualEffectView.material = .hudWindow
    visualEffectView.blendingMode = .behindWindow
    visualEffectView.state = .active
    visualEffectView.wantsLayer = true
    visualEffectView.layer?.cornerRadius = Constants.cornerRadius
    visualEffectView.layer?.shadowColor = NSColor.black.cgColor
    visualEffectView.layer?.shadowOffset = NSSize(width: 2, height: 4)  // Shadow to right and above for bottom-left position
    visualEffectView.layer?.shadowRadius = Constants.shadowRadius
    visualEffectView.layer?.shadowOpacity = Constants.shadowOpacity

    customContentView = visualEffectView
    contentView = customContentView
  }

  private func setupLabels(title: String, text: String) {
    // Title label
    titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = NSFont.boldSystemFont(ofSize: Constants.titleFontSize)
    titleLabel.textColor = NSColor.labelColor
    titleLabel.alignment = .left
    titleLabel.isEditable = false
    titleLabel.isBordered = false
    titleLabel.backgroundColor = NSColor.clear
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    // Text label - show short preview only
    let displayText = createPreviewText(from: text)

    textLabel = NSTextField(labelWithString: displayText)
    textLabel.font = NSFont.systemFont(ofSize: Constants.textFontSize)
    textLabel.textColor = NSColor.secondaryLabelColor
    textLabel.alignment = .left
    textLabel.isEditable = false
    textLabel.isBordered = false
    textLabel.backgroundColor = NSColor.clear
    textLabel.lineBreakMode = .byWordWrapping
    textLabel.maximumNumberOfLines = 0  // Unlimited lines
    textLabel.translatesAutoresizingMaskIntoConstraints = false
    textLabel.preferredMaxLayoutWidth = Constants.windowWidth - (Constants.padding * 2)  // Ensure proper wrapping
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
    customContentView.addSubview(titleLabel)
    customContentView.addSubview(scrollView)

    // Set up constraints
    NSLayoutConstraint.activate([
      // Title label constraints
      titleLabel.topAnchor.constraint(
        equalTo: customContentView.topAnchor, constant: Constants.padding),
      titleLabel.leadingAnchor.constraint(
        equalTo: customContentView.leadingAnchor, constant: Constants.padding),
      titleLabel.trailingAnchor.constraint(
        equalTo: customContentView.trailingAnchor, constant: -Constants.padding),

      // Scroll view constraints
      scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
      scrollView.leadingAnchor.constraint(
        equalTo: customContentView.leadingAnchor, constant: Constants.padding),
      scrollView.trailingAnchor.constraint(
        equalTo: customContentView.trailingAnchor, constant: -Constants.padding),
      scrollView.bottomAnchor.constraint(
        equalTo: customContentView.bottomAnchor, constant: -Constants.padding),

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

    // Calculate title height
    let titleHeight = titleLabel.intrinsicContentSize.height
    let availableWidth = Constants.windowWidth - (Constants.padding * 2)

    // Set the preferred max layout width for proper text wrapping
    textLabel.preferredMaxLayoutWidth = availableWidth

    // Force layout to get accurate text measurements
    textLabel.layoutSubtreeIfNeeded()

    // Calculate text content height
    let textContentHeight = textLabel.intrinsicContentSize.height
    let maxTextHeight = maxWindowHeight - Constants.padding - titleHeight - 8 - Constants.padding
    let actualTextHeight = min(textContentHeight, maxTextHeight)

    // Calculate total window height
    let totalHeight = max(
      Constants.padding + titleHeight + 8 + actualTextHeight + Constants.padding,
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

    NSLog("🔔 POPUP: Window sized to \(totalHeight)px height, text content: \(textContentHeight)px")
  }

  private func positionWindow() {
    guard let screen = NSScreen.main else { return }

    let screenFrame = screen.visibleFrame
    let windowFrame = NSRect(
      x: screenFrame.minX + Constants.screenMargin,  // 20px vom linken Rand
      y: screenFrame.minY + Constants.screenMargin + Constants.minHeight,  // Popup höher positionieren
      width: Constants.windowWidth,
      height: Constants.minHeight
    )

    NSLog("🔔 POPUP-POSITION: Screen frame: \(screenFrame)")
    NSLog("🔔 POPUP-POSITION: Calculated window frame: \(windowFrame)")

    setFrame(windowFrame, display: false)

    // Verify actual position after setting
    let actualFrame = frame
    NSLog("🔔 POPUP-POSITION: Actual window frame after setFrame: \(actualFrame)")
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
    NSLog("🔔 POPUP: Showing notification popup")

    // Set initial alpha and position for bottom-left slide-in
    alphaValue = 0.0
    setFrame(frame.offsetBy(dx: 0, dy: -20), display: false)  // Start below final position

    // Show window without stealing focus or becoming main window
    orderFront(nil)

    // Debug: Check actual position after showing
    NSLog("🔔 POPUP-POSITION: Final position after show: \(frame)")

    // CRITICAL: macOS repositions windows after show() - force our position again
    guard let screen = NSScreen.main else { return }
    let screenFrame = screen.visibleFrame
    let targetFrame = NSRect(
      x: screenFrame.minX + Constants.screenMargin,  // 20px vom linken Rand
      y: screenFrame.minY + Constants.screenMargin,  // 20px Abstand vom unteren Rand (untere Kante des Popups)
      width: Constants.windowWidth,
      height: frame.height
    )
    setFrame(targetFrame, display: true)
    NSLog("🔔 POPUP-POSITION: Forced position after macOS override: \(frame)")

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
    NSLog("🔔 POPUP: PopupNotificationWindow deallocated")
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

    NSLog("🔔 POPUP-DEBUG: Key exists: \(keyExists), Value: \(value)")

    // Check if the key exists, if not, default to true (enabled)
    if !keyExists {
      NSLog("🔔 POPUP-DEBUG: Key doesn't exist, defaulting to enabled")
      return true  // Default to enabled
    }

    NSLog("🔔 POPUP-DEBUG: Using stored value: \(value)")
    return value
  }

  static func showPromptResponse(_ response: String) {
    guard arePopupNotificationsEnabled else {
      NSLog("🔔 POPUP: Popup notifications disabled - skipping prompt response popup")
      return
    }

    NSLog("🔔 POPUP: Creating prompt response popup")

    let popup = PopupNotificationWindow(
      title: "📋 Text Copied to Clipboard",
      text: response
    )

    // Keep strong reference until window closes
    activePopups.insert(popup)
    popup.show()
  }

  static func showTranscriptionResponse(_ transcription: String) {
    guard arePopupNotificationsEnabled else {
      NSLog("🔔 POPUP: Popup notifications disabled - skipping transcription response popup")
      return
    }

    NSLog("🔔 POPUP: Creating transcription response popup")

    let popup = PopupNotificationWindow(
      title: "📋 Text Copied to Clipboard",
      text: transcription
    )

    // Keep strong reference until window closes
    activePopups.insert(popup)
    popup.show()
  }

  static func showVoiceResponse(_ response: String) {
    guard arePopupNotificationsEnabled else {
      NSLog("🔔 POPUP: Popup notifications disabled - skipping voice response popup")
      return
    }

    NSLog("🔔 POPUP: Creating voice response popup")

    let popup = PopupNotificationWindow(
      title: "📋 Text Copied to Clipboard",
      text: response
    )

    // Keep strong reference until window closes
    activePopups.insert(popup)
    popup.show()
  }
}

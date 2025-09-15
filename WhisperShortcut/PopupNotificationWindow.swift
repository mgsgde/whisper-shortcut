import AppKit
import Foundation

class PopupNotificationWindow: NSWindow {

  // MARK: - Constants
  private enum Constants {
    static let windowWidth: CGFloat = 500
    static let maxHeight: CGFloat = 400  // Reasonable max height to fit on screen
    static let minHeight: CGFloat = 120
    static let cornerRadius: CGFloat = 12
    static let shadowRadius: CGFloat = 20
    static let shadowOpacity: Float = 0.3
    static let animationDuration: TimeInterval = 0.3
    static let displayDuration: TimeInterval = 8.0
    static let padding: CGFloat = 20
    static let titleFontSize: CGFloat = 16
    static let textFontSize: CGFloat = 13  // Slightly smaller for better fit
    static let maxTextLength = 1500  // Reasonable limit for readability
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
    level = .floating  // Use floating level for proper visibility
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
    customContentView = NSView()
    customContentView.wantsLayer = true
    customContentView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    customContentView.layer?.cornerRadius = Constants.cornerRadius
    customContentView.layer?.shadowColor = NSColor.black.cgColor
    customContentView.layer?.shadowOffset = NSSize(width: 0, height: -2)
    customContentView.layer?.shadowRadius = Constants.shadowRadius
    customContentView.layer?.shadowOpacity = Constants.shadowOpacity

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

    // Text label - show full text, no truncation
    let displayText =
      text.count > Constants.maxTextLength
      ? String(text.prefix(Constants.maxTextLength)) + "\n\n... (Text truncated for display)"
      : text

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
      x: screenFrame.maxX - Constants.windowWidth - 20,
      y: screenFrame.maxY - 100,
      width: Constants.windowWidth,
      height: 100
    )

    setFrame(windowFrame, display: false)
  }

  // MARK: - Animation Methods
  func show() {
    NSLog("🔔 POPUP: Showing notification popup")

    // Set initial alpha and scale
    alphaValue = 0.0
    setFrame(frame.offsetBy(dx: 0, dy: 20), display: false)

    // Show window without stealing focus or becoming main window
    orderFront(nil)

    // Animate in
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Constants.animationDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)

      self.animator().alphaValue = 1.0
      self.animator().setFrame(self.frame.offsetBy(dx: 0, dy: -20), display: true)
    }
  }

  func hide() {
    NSLog("🔔 POPUP: Hiding notification popup")

    // Cancel auto-hide timer
    autoHideTimer?.invalidate()
    autoHideTimer = nil

    // Animate out
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = Constants.animationDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)

      self.animator().alphaValue = 0.0
      self.animator().setFrame(self.frame.offsetBy(dx: 0, dy: 20), display: true)
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
    NSLog("🔔 POPUP: Window close() called directly - using hide() for proper cleanup")

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

  static func showPromptResponse(_ response: String) {
    NSLog("🔔 POPUP: Creating prompt response popup")

    let popup = PopupNotificationWindow(
      title: "🤖 AI Response Copied",
      text: response
    )

    // Keep strong reference until window closes
    activePopups.insert(popup)
    popup.show()
  }
}

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

class PopupNotificationWindow: NSWindow {

  // MARK: - Constants
  private enum Constants {
    static let windowWidth: CGFloat = 360  // Slightly wider for better readability
    static let maxHeight: CGFloat = 240  // More space for content
    static let minHeight: CGFloat = 100  // More breathing room
    static let cornerRadius: CGFloat = 12  // Modern macOS corner radius
    static let shadowRadius: CGFloat = 8  // Subtle shadow like native macOS notifications
    static let shadowOpacity: Float = 0.15  // Very subtle, barely visible shadow
    static let animationDuration: TimeInterval = 0.25  // Smoother animation
    static let displayDuration: TimeInterval = 7.0  // Comfortable reading time
    static let errorDisplayDuration: TimeInterval = 30.0  // Long duration for error messages with feedback option
    static let outerPadding: CGFloat = 20  // Generous outer padding
    static let innerPadding: CGFloat = 16  // Inner content padding
    static let titleBottomSpacing: CGFloat = 12  // More space between title and text
    static let iconSpacing: CGFloat = 12  // Better spacing between icon and text
    static let titleFontSize: CGFloat = 15  // Slightly larger for better readability
    static let textFontSize: CGFloat = 13  // Better readable text size
    static let maxPreviewLength = 120  // Slightly longer preview
    static let horizontalMargin: CGFloat = 50  // Distance from left/right screen edges
    static let verticalMargin: CGFloat = 50  // Distance from top/bottom screen edges (slightly less for better visual balance)
    static let iconAndSpacingWidth: CGFloat = 28  // Icon width + spacing for layout calculations
  }

  // MARK: - Properties
  private var customContentView: NSView!
  private var iconLabel: NSTextField!
  private var titleLabel: NSTextField!
  private var textLabel: NSTextField!
  private var scrollView: NSScrollView!
  private var whatsappIcon: NSImageView?
  private var autoHideTimer: Timer?
  private var isError: Bool = false
  private var errorText: String = ""

  // MARK: - Initialization
  init(title: String, text: String, isError: Bool = false) {
    // Create window with specific style for notifications
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: Constants.windowWidth, height: 100),
      styleMask: [],  // Completely borderless for custom styling
      backing: .buffered,
      defer: false
    )

    // Store error state and text for WhatsApp feedback
    self.isError = isError
    self.errorText = text

    setupWindow()
    setupContentView()
    setupIcon(isError: isError)
    setupLabels(title: title, text: text)
    setupScrollView()
    if isError {
      setupWhatsAppIcon()
    }
    layoutContent()

    // Make error notifications clickable for WhatsApp feedback
    if isError {
      setupErrorClickHandler()
    }

    // Start auto-hide timer with appropriate duration
    startAutoHideTimer(isError: isError)
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

  private func setupIcon(isError: Bool) {
    // For errors, skip the red X icon since we have WhatsApp icon for feedback
    // Only show green checkmark for success
    let iconText = isError ? "" : "✅"  // No icon for errors, green checkmark for success

    iconLabel = NSTextField(labelWithString: iconText)
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
    titleLabel.font = NSFont.systemFont(ofSize: Constants.titleFontSize, weight: .medium)  // Subtle, elegant weight like native notifications
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
    paragraphStyle.lineSpacing = 3  // Improved line spacing for better readability
    paragraphStyle.paragraphSpacing = 6  // Better paragraph spacing

    let attributedText = NSAttributedString(
      string: displayText,
      attributes: [
        .font: NSFont.systemFont(ofSize: Constants.textFontSize, weight: .regular),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraphStyle,
      ]
    )
    textLabel.attributedStringValue = attributedText

    textLabel.preferredMaxLayoutWidth =
      Constants.windowWidth - (Constants.outerPadding * 2) - Constants.iconAndSpacingWidth
  }

  private func setupWhatsAppIcon() {
    guard let whatsappImage = NSImage(named: "WhatsApp") else {
      return
    }

    whatsappIcon = NSImageView(image: whatsappImage)
    guard let icon = whatsappIcon else { return }

    // Icon styling - positioned next to title for better UX
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.imageScaling = .scaleProportionallyDown
    icon.wantsLayer = true
    icon.layer?.cornerRadius = 4
  }

  private func setupErrorClickHandler() {
    // Set up click handler for the clickable content view
    if let clickableView = customContentView as? ClickableContentView {
      clickableView.onClickHandler = { [weak self] in
        self?.errorWindowClicked()
      }
    }

    // Visual feedback through cursor change only - no border needed for clean design
    customContentView.wantsLayer = true
  }

  @objc private func errorWindowClicked() {
    // First open WhatsApp, then close notification
    openWhatsAppFeedback()

    // Delay closing the notification slightly to ensure WhatsApp opens
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      self.hide()
    }
  }

  private func openWhatsAppFeedback() {
    let baseMessage = "Hi! I encountered an error in WhisperShortcut:"

    // Limit error text length to prevent URL issues
    let maxErrorLength = 500
    let truncatedError =
      errorText.count > maxErrorLength
      ? String(errorText.prefix(maxErrorLength)) + "..."
      : errorText

    let errorMessage = "\n\nError Details:\n\(truncatedError)"
    let fullMessage = baseMessage + errorMessage

    guard
      let encodedMessage = fullMessage.addingPercentEncoding(
        withAllowedCharacters: .urlQueryAllowed),
      let whatsappURL = URL(
        string: "https://wa.me/\(AppConstants.whatsappSupportNumber)?text=\(encodedMessage)"),
      whatsappURL.scheme == "https",
      whatsappURL.host == "wa.me"
    else {
      return
    }

    // Open WhatsApp Web in default browser
    NSWorkspace.shared.open(whatsappURL)
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

    // Add WhatsApp icon for error notifications (positioned next to title)
    if isError, let icon = whatsappIcon {
      customContentView.addSubview(icon)
    }

    // Set up constraints with improved spacing
    NSLayoutConstraint.activate([
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
        equalTo: titleLabel.bottomAnchor, constant: Constants.titleBottomSpacing),
      scrollView.leadingAnchor.constraint(
        equalTo: customContentView.leadingAnchor, constant: Constants.outerPadding),
      scrollView.bottomAnchor.constraint(
        equalTo: customContentView.bottomAnchor, constant: -Constants.outerPadding),

      // Text label width constraint (for proper wrapping)
      textLabel.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
    ])

    // Set up constraints based on notification type
    if isError, let icon = whatsappIcon {
      // Error notifications: no left icon, WhatsApp icon on right
      NSLayoutConstraint.activate([
        // Title starts from left edge (no left icon)
        titleLabel.leadingAnchor.constraint(
          equalTo: customContentView.leadingAnchor, constant: Constants.outerPadding),

        // Position WhatsApp icon to the right of title
        icon.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        icon.leadingAnchor.constraint(
          equalTo: titleLabel.trailingAnchor, constant: Constants.iconSpacing),
        icon.trailingAnchor.constraint(
          equalTo: customContentView.trailingAnchor, constant: -Constants.outerPadding),
        icon.widthAnchor.constraint(equalToConstant: 20),
        icon.heightAnchor.constraint(equalToConstant: 20),

        // Scroll view spans full width
        scrollView.trailingAnchor.constraint(
          equalTo: customContentView.trailingAnchor, constant: -Constants.outerPadding),
      ])
    } else {
      // Success notifications: green checkmark on left, no right icon
      NSLayoutConstraint.activate([
        // Title positioned after left icon
        titleLabel.leadingAnchor.constraint(
          equalTo: iconLabel.trailingAnchor, constant: Constants.iconSpacing),
        titleLabel.trailingAnchor.constraint(
          equalTo: customContentView.trailingAnchor, constant: -Constants.outerPadding),

        // Scroll view spans full width
        scrollView.trailingAnchor.constraint(
          equalTo: customContentView.trailingAnchor, constant: -Constants.outerPadding),
      ])
    }

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
    let availableWidth =
      Constants.windowWidth - (Constants.outerPadding * 2) - Constants.iconAndSpacingWidth

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

    // Update window frame and position it properly (bottom-left)
    let newFrame = NSRect(
      x: screenFrame.minX + Constants.horizontalMargin,  // Left edge with margin
      y: screenFrame.minY + Constants.verticalMargin,  // Bottom edge with margin
      width: Constants.windowWidth,
      height: totalHeight
    )

    setFrame(newFrame, display: true)
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
      // CRITICAL: Always add ellipsis when text is truncated
      // Find a good break point (end of sentence or word)
      let preview = String(cleanText.prefix(Constants.maxPreviewLength))
      if let lastSentence = preview.lastIndex(of: "."),
        lastSentence > preview.index(preview.startIndex, offsetBy: 30)
      {
        // Always add ellipsis when text is truncated, even at sentence end
        return String(preview[...lastSentence]) + "..."
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
    //
    // DEBUGGING RESULTS (2025-09-15):
    // - macOS DOES override window position: Expected Y=50, Actual Y=30 (20px difference)
    // - Position correction is REQUIRED for proper bottom-left placement
    // - macOS does NOT override styling properties (borders, colors, etc.)
    // - Styling enforcement is NOT needed and was removed after testing
    //
    guard let screen = NSScreen.main else { return }
    let screenFrame = screen.visibleFrame
    let targetFrame = NSRect(
      x: screenFrame.minX + Constants.horizontalMargin,  // Left edge with margin
      y: screenFrame.minY + Constants.verticalMargin,  // Bottom edge with margin
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
      // Hide window instead of closing to prevent app termination
      self.orderOut(nil)  // Make window invisible

      // Remove from active popups to allow deallocation
      PopupNotificationWindow.activePopups.remove(self)
    }
  }

  // MARK: - Timer Methods
  private func startAutoHideTimer(isError: Bool) {
    let duration = isError ? Constants.errorDisplayDuration : Constants.displayDuration
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
    // Hide popup when clicked
    hide()
  }

  // MARK: - Window Behavior Overrides
  // CRITICAL: Prevent this window from becoming main window or causing app termination
  override var canBecomeMain: Bool {
    return false
  }

  override var canBecomeKey: Bool {
    return false
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

  private static func showSuccessNotification(
    title: String = "Text Copied to Clipboard", text: String
  ) {
    guard arePopupNotificationsEnabled else {
      return
    }

    let popup = PopupNotificationWindow(
      title: title,
      text: text
    )

    // Keep strong reference until window closes
    activePopups.insert(popup)
    popup.show()
  }

  static func showPromptResponse(_ response: String) {
    showSuccessNotification(text: response)
  }

  static func showTranscriptionResponse(_ transcription: String) {
    showSuccessNotification(text: transcription)
  }

  static func showVoiceResponse(_ response: String) {
    showSuccessNotification(text: response)
  }

  static func showReadingText(_ text: String) {
    showSuccessNotification(title: "🔊 Reading Text", text: text)
  }

  static func showError(_ error: String, title: String = "Error") {
    guard arePopupNotificationsEnabled else {
      return
    }

    let popup = PopupNotificationWindow(
      title: title,
      text: error,
      isError: true
    )

    // Keep strong reference until window closes
    activePopups.insert(popup)
    popup.show()
  }
}

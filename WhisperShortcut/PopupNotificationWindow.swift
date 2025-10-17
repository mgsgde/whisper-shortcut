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
    // CRITICAL FIX: More compact window sizing for better user experience
    // Reduced all widths to make notifications more compact
    static let minWindowWidth: CGFloat = 260  // Minimum width for compact notifications
    static let maxWindowWidth: CGFloat = 420  // Maximum width for very long content (reduced from 500px)
    static let defaultWindowWidth: CGFloat = 320  // Default width for medium content (reduced from 380px)
    static let maxHeight: CGFloat = 400  // Much more space for content
    static let minHeight: CGFloat = 120  // More breathing room
    static let cornerRadius: CGFloat = 12  // Modern macOS corner radius
    static let shadowRadius: CGFloat = 8  // Subtle shadow like native macOS notifications
    static let shadowOpacity: Float = 0.15  // Very subtle, barely visible shadow
    static let animationDuration: TimeInterval = 0.25  // Smoother animation
    static let displayDuration: TimeInterval = 7.0  // Comfortable reading time
    static let errorDisplayDuration: TimeInterval = 30.0  // Long duration for error messages with feedback option
    static let outerPadding: CGFloat = 20  // Generous outer padding
    static let innerPadding: CGFloat = 16  // Inner content padding
    static let titleBottomSpacing: CGFloat = 16  // More space between title and text
    static let iconSpacing: CGFloat = 12  // Better spacing between icon and text
    static let titleFontSize: CGFloat = 15  // Slightly larger for better readability
    static let textFontSize: CGFloat = 13  // Better readable text size
    static let maxPreviewLength = 180  // Even longer preview for better readability
    static let horizontalMargin: CGFloat = 50  // Distance from left/right screen edges
    static let verticalMargin: CGFloat = 50  // Distance from top/bottom screen edges (slightly less for better visual balance)
    static let iconAndSpacingWidth: CGFloat = 28  // Icon width + spacing for layout calculations
    static let optimalCharactersPerLine: CGFloat = 60  // Optimal number of characters per line for readability
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
  private var autoHideTimer: Timer?
  private var isError: Bool = false
  private var errorText: String = ""

  // MARK: - Initialization
  init(title: String, text: String, isError: Bool = false, modelInfo: String? = nil) {
    // Create window with specific style for notifications
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: Constants.defaultWindowWidth, height: 100),
      styleMask: [],  // Completely borderless for custom styling
      backing: .buffered,
      defer: false
    )

    // Store error state and text for WhatsApp feedback
    self.isError = isError
    self.errorText = text

    setupWindow()
    setupContentView()
    setupCloseButton()
    setupIcon(isError: isError)
    setupLabels(title: title, text: text, modelInfo: modelInfo)
    setupScrollView()
    if isError {
      setupWhatsAppIcon()
    }
    layoutContent()

    // Make error notifications clickable for WhatsApp feedback
    if isError {
      setupErrorClickHandler()
    } else {
      setupSuccessClickHandler()
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

  private func setupCloseButton() {
    closeButton = NSButton()
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

  private func setupLabels(title: String, text: String, modelInfo: String?) {
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

    // Model info label (only shown for success notifications with model info)
    if let modelInfo = modelInfo, !isError {
      modelInfoLabel = NSTextField(labelWithString: "🤖 \(modelInfo)")
      modelInfoLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
      modelInfoLabel.textColor = NSColor.secondaryLabelColor
      modelInfoLabel.alignment = .left
      modelInfoLabel.isEditable = false
      modelInfoLabel.isBordered = false
      modelInfoLabel.backgroundColor = NSColor.clear
      modelInfoLabel.translatesAutoresizingMaskIntoConstraints = false
      modelInfoLabel.lineBreakMode = .byTruncatingTail
      modelInfoLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    } else {
      modelInfoLabel = nil
    }

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
      Constants.defaultWindowWidth - (Constants.outerPadding * 2) - Constants.iconAndSpacingWidth
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

  private func setupSuccessClickHandler() {
    if let clickableView = customContentView as? ClickableContentView {
      clickableView.onClickHandler = { [weak self] in
        self?.successWindowClicked()
      }
    }

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

  @objc private func successWindowClicked() {
    openRecentHistory()
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

  private func openRecentHistory(limit: Int = 20) {
    guard let fileURL = HistoryLogger.shared.exportRecentToTempFile(limit: limit) else {
      return
    }

    // Always use the system default handler
    NSWorkspace.shared.open(fileURL)
    NSLog("🪟 Popup: Opened recent history via default handler at \(fileURL.path)")
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

    // Add WhatsApp icon for error notifications (positioned next to title)
    if isError, let icon = whatsappIcon {
      customContentView.addSubview(icon)
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
      scrollView.bottomAnchor.constraint(
        equalTo: customContentView.bottomAnchor, constant: -Constants.outerPadding),

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
    if isError, let icon = whatsappIcon {
      // Error notifications: no left icon, WhatsApp icon on right
      NSLayoutConstraint.activate([
        // Title starts from left edge (no left icon)
        titleLabel.leadingAnchor.constraint(
          equalTo: customContentView.leadingAnchor, constant: Constants.outerPadding),

        // Position WhatsApp icon to the right of title (leave space for close button)
        icon.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        icon.leadingAnchor.constraint(
          equalTo: titleLabel.trailingAnchor, constant: Constants.iconSpacing),
        icon.trailingAnchor.constraint(
          lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
        icon.widthAnchor.constraint(equalToConstant: 20),
        icon.heightAnchor.constraint(equalToConstant: 20),

        // Scroll view spans full width
        scrollView.trailingAnchor.constraint(
          equalTo: customContentView.trailingAnchor, constant: -Constants.outerPadding),
      ])
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
      ])
    }

    // Calculate and set window size
    updateWindowSize()
  }

  private func updateWindowSize() {
    // Get screen dimensions to ensure popup fits
    guard let screen = NSScreen.main else { return }
    let screenFrame = screen.visibleFrame
    let maxWindowHeight = min(Constants.maxHeight, screenFrame.height * 0.8)  // Max 80% of screen height

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

    // Calculate total required height
    let requiredHeight = Constants.outerPadding +  // Top padding
                         titleHeight +  // Title height
                         titleToModelSpacing +  // Gap to model info
                         modelInfoHeight +  // Model info height
                         modelToTextSpacing +  // Gap to text
                         textContentHeight +  // Text content height
                         Constants.outerPadding  // Bottom padding

    // Use the larger of required height or minimum height, but cap at max height
    let totalHeight = max(min(requiredHeight, maxWindowHeight), Constants.minHeight)

    // Update window frame and position it properly (bottom-left)
    let newFrame = NSRect(
      x: screenFrame.minX + Constants.horizontalMargin,  // Left edge with margin
      y: screenFrame.minY + Constants.verticalMargin,  // Bottom edge with margin
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
    
    // Calculate optimal characters per line based on text length (more compact scaling)
    let optimalCharsPerLine: CGFloat
    if textLength <= 30 {
      // Very short text: compact display
      optimalCharsPerLine = min(CGFloat(textLength) * 1.2, 35)
    } else if textLength <= 80 {
      // Short to medium text: gradual increase (more conservative)
      optimalCharsPerLine = 35 + (CGFloat(textLength - 30) * 0.2) // 35 to 45 chars
    } else if textLength <= 200 {
      // Medium text: moderate width
      optimalCharsPerLine = 45 + (CGFloat(textLength - 80) * 0.15) // 45 to 63 chars
    } else {
      // Long text: maximum width but still compact
      optimalCharsPerLine = min(63 + (CGFloat(textLength - 200) * 0.05), 75)
    }
    
    // Calculate final width
    let textWidth = averageCharWidth * optimalCharsPerLine
    let totalWidth = textWidth + baseWidth
    
    // Ensure width stays within bounds
    return max(min(totalWidth, Constants.maxWindowWidth), Constants.minWindowWidth)
  }

  private func createPreviewText(from text: String) -> String {
    // Clean up text - remove extra whitespace and newlines
    let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n+", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

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
    let screenFrame = screen.visibleFrame
    
    // Calculate final target frame
    let targetFrame = NSRect(
      x: screenFrame.minX + Constants.horizontalMargin,  // Left edge with margin
      y: screenFrame.minY + Constants.verticalMargin,  // Bottom edge with margin
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
    title: String = "Text Copied to Clipboard", text: String, modelInfo: String? = nil
  ) {
    guard arePopupNotificationsEnabled else {
      return
    }

    let popup = PopupNotificationWindow(
      title: title,
      text: text,
      modelInfo: modelInfo
    )

    // Keep strong reference until window closes
    activePopups.insert(popup)
    popup.show()
  }

  static func showPromptResponse(_ response: String, modelInfo: String? = nil) {
    HistoryLogger.shared.log(type: .prompt, text: response)
    showSuccessNotification(text: response, modelInfo: modelInfo)
  }

  static func showTranscriptionResponse(_ transcription: String, modelInfo: String? = nil) {
    HistoryLogger.shared.log(type: .transcription, text: transcription)
    showSuccessNotification(text: transcription, modelInfo: modelInfo)
  }

  static func showVoiceResponse(_ response: String, modelInfo: String? = nil) {
    HistoryLogger.shared.log(type: .voiceResponse, text: response)
    showSuccessNotification(text: response, modelInfo: modelInfo)
  }

  static func showReadingText(_ text: String) {
    HistoryLogger.shared.log(type: .readingText, text: text)
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

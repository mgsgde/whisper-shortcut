import Cocoa

class SettingsManager {
    static let shared = SettingsManager()
    private var settingsWindowController: SettingsWindowController?
    
    private init() {}
    
    func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}


import Testing
@testable import WhisperShortcut_AppStore

/// Pins the Settings sidebar's grouping.
///
/// The sidebar is the only navigation the Settings window has, so a tab that falls out of every
/// section is unreachable — no crash, no log line, just a pane the user can never open again.
/// These tests make that failure loud: every tab must sit in exactly one section, and the
/// sections must keep their order.
@Suite("Settings sidebar grouping")
struct SettingsSidebarGroupingTests {

  @Test("Every tab appears in exactly one section")
  func everyTabAppearsExactlyOnce() {
    let grouped = SettingsTab.sections.flatMap(\.tabs)

    #expect(grouped.count == SettingsTab.allCases.count)
    #expect(Set(grouped) == Set(SettingsTab.allCases))
    #expect(Set(grouped).count == grouped.count, "a tab is listed in more than one section")
  }

  @Test("No section is empty")
  func noSectionIsEmpty() {
    for section in SettingsTab.sections {
      #expect(!section.tabs.isEmpty, "section \(section.rawValue) has no tabs")
    }
  }

  @Test("Section order is stable")
  func sectionOrderIsStable() {
    #expect(
      SettingsTab.sections.map(\.rawValue) == ["General", "Dictation", "Chat & Meetings", "More"])
  }

  @Test("Tabs keep their allCases order inside a section")
  func tabsKeepAllCasesOrder() {
    for section in SettingsTab.sections {
      let expected = SettingsTab.allCases.filter { $0.section == section }
      #expect(section.tabs == expected)
    }
  }

  @Test("The persisted raw values are unchanged")
  func rawValuesAreStable() {
    // `settingsSelectedTab` stores these strings; renaming one silently resets the pane a user
    // last had open, so they are pinned here rather than left to the enum's declaration.
    #expect(
      SettingsTab.allCases.map(\.rawValue) == [
        "General", "Accounts", "Dictate", "Dictate Prompt", "Templates", "Screenshot",
        "Read Aloud", "Chat", "Meetings", "Smart Improvement", "Claude & AI Apps",
        "Privacy & Permissions", "About",
      ])
  }

  @Test("A stored tab still resolves to its section")
  func storedTabResolves() {
    for tab in SettingsTab.allCases {
      let restored = SettingsTab(rawValue: tab.rawValue)
      #expect(restored == tab)
      #expect(restored?.section == tab.section)
    }
  }
}

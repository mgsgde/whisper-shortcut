import Combine
import SwiftUI

/// Settings view of the IMAP mailboxes connected from chat. Connecting happens in the chat (the
/// password card); this is where the user sees what is connected and removes it.
struct MailAccountsSection: View {
  @State private var accounts: [MailAccount] = []

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Mail Accounts",
        systemImage: "envelope",
        subtitle: "IMAP mailboxes (IONOS, GMX, web.de, iCloud, …) the chat can search and read. Read-only."
      )

      if accounts.isEmpty {
        Text("None connected. Ask the chat, for example: \"Connect my mailbox me@example.de\". It asks for the password in a secure field.")
          .font(.callout)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(accounts) { account in
            HStack(spacing: 12) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
              VStack(alignment: .leading, spacing: 2) {
                Text(account.email)
                  .font(.callout)
                Text(account.host)
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
              Spacer()
              Button("Remove") {
                MailAccountStore.remove(email: account.email)
                reload()
              }
            }
          }
        }
      }
    }
    .onAppear(perform: reload)
    // An account connected from the chat while Settings is open shows up without reopening.
    .onReceive(
      NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
        .receive(on: RunLoop.main)
    ) { _ in
      let current = MailAccountStore.accounts()
      if current != accounts { accounts = current }
    }
  }

  private func reload() {
    accounts = MailAccountStore.accounts()
  }
}

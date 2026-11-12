import Foundation
import Observation

@MainActor @Observable
final class MailState {
    private(set) var accounts: [MailAccount] = []
    var selectedAccountID: UUID?
    var folders: [IMAPClient.Mailbox] = []
    var folder = "INBOX"
    private(set) var rows: [MailService.Summary] = []
    var selectedUID: UInt32?
    private(set) var busy = false
    var message: String?
    @ObservationIgnored private let store = MailAccountStore()

    var account: MailAccount? { accounts.first { $0.id == selectedAccountID } ?? accounts.first }
    var selected: MailService.Summary? { rows.first { $0.uid == selectedUID } }

    func load() {
        accounts = store.accounts()
        if selectedAccountID == nil { selectedAccountID = accounts.first?.id }
    }

    func add(_ account: MailAccount, password: String) {
        do {
            try store.save(account, password: password)
            load(); selectedAccountID = account.id; message = nil
            Task { await refresh() }
        } catch { message = error.localizedDescription }
    }

    /// Finds the servers, proves the sign-in works, then saves. Returns an explanation on failure, nil on success.
    func setUp(name: String, address: String, password: String, manual: MailAccount?) async -> String? {
        do {
            let account = try await MailSetup.run(name: name, address: address, password: password, manual: manual)
            try store.save(account, password: password)
            load(); selectedAccountID = account.id; message = nil
            Task { await refresh() }
            return nil
        } catch {
            return MailSetup.explain(error, provider: MailAutoconfig.domain(of: address))
        }
    }

    func remove(_ account: MailAccount) {
        try? store.remove(account)
        selectedAccountID = nil; rows = []; folders = []
        load()
    }

    func refresh() async {
        guard let account, !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        let service = MailService(account: account, store: store)
        do {
            if folders.isEmpty { folders = try await service.folders() }
            rows = try await service.recent(in: folder, limit: 30)
            if selectedUID == nil || selected == nil { selectedUID = rows.first?.uid }
        } catch { message = error.localizedDescription }
    }

    func send(_ draft: MailDraft) async -> Bool {
        guard let account else { return false }
        busy = true; defer { busy = false }
        do {
            let approval = SendApproval(accountID: account.id, recipients: (draft.to + draft.cc).map(\.email), subject: draft.subject)
            try await MailService(account: account, store: store).send(draft, approval: approval)
            message = "Sent to \((draft.to + draft.cc).map(\.email).joined(separator: ", "))."
            return true
        } catch { message = error.localizedDescription; return false }
    }
}

import SwiftUI

struct MailView: View {
    @State private var state = MailState()
    @State private var addingAccount = false
    @State private var composing: MailDraft?
    @State private var texting = false

    var body: some View {
        VStack(spacing: 0) {
            SSActivityHeader(title: "Mail", subtitle: state.account?.address ?? "Your accounts", symbol: "envelope", trailing: {
                HStack(spacing: 8) {
                    if state.busy { ProgressView().controlSize(.small) }
                    if state.accounts.count > 1 {
                        Picker("Account", selection: Binding(get: { state.account?.id ?? UUID() }, set: { state.selectedAccountID = $0; state.folders = []; Task { await state.refresh() } })) {
                            ForEach(state.accounts) { Text($0.address).tag($0.id) }
                        }.labelsHidden().fixedSize()
                    }
                    Button { texting = true } label: { Image(systemName: "message") }.help("New text message in Messages").accessibilityLabel("New text message")
                    Button { composing = newDraft() } label: { Label("New message", systemImage: "square.and.pencil") }.disabled(state.account == nil)
                    Button { Task { await state.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(state.account == nil || state.busy).help("Check for new mail").accessibilityLabel("Check for new mail")
                    Button { addingAccount = true } label: { Image(systemName: "plus") }.help("Add an account").accessibilityLabel("Add an account")
                }
            })
            if let note = state.message {
                Text(note).font(SSTypography.caption()).foregroundStyle(note.hasPrefix("Sent") ? Color.secondary : SSColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, SSSpacing.m).padding(.vertical, 4)
            }
            if state.account == nil {
                // Built here rather than with SSEmptyState, which fills the pane and pushed the button to the bottom edge.
                VStack(spacing: SSSpacing.s) {
                    Image(systemName: "envelope").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No mail account yet").font(SSTypography.headline())
                    Text("Add an account to read and write email. Passwords are kept in your Keychain; Kiln never shows them again.")
                        .font(SSTypography.caption()).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                    Button("Add an account") { addingAccount = true }.buttonStyle(.borderedProminent).padding(.top, SSSpacing.s)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    list.frame(minWidth: 260, idealWidth: 320)
                    reader.frame(minWidth: 320)
                }
            }
        }
        .background(SSColor.canvas)
        .task { state.load(); if state.account != nil { await state.refresh() } }
        .sheet(isPresented: $texting) { TextMessageSheet(isPresented: $texting) }
        .sheet(isPresented: $addingAccount) { AddMailAccountSheet(state: state, isPresented: $addingAccount) }
        .sheet(item: Binding(get: { composing.map(DraftBox.init) }, set: { composing = $0?.draft })) { box in
            ComposeSheet(state: state, draft: box.draft, close: { composing = nil })
        }
    }

    private struct DraftBox: Identifiable { var draft: MailDraft; var id: String { draft.subject + draft.body } }

    private func newDraft() -> MailDraft? {
        state.account.map { MailDraft(from: $0.sender, to: [], subject: "", body: "") }
    }

    private var list: some View {
        VStack(spacing: 0) {
            if !state.folders.isEmpty {
                Picker("Folder", selection: Binding(get: { state.folder }, set: { state.folder = $0; Task { await state.refresh() } })) {
                    ForEach(state.folders, id: \.name) { Text($0.name).tag($0.name) }
                }.labelsHidden().padding(8)
            }
            List(selection: Binding(get: { state.selectedUID }, set: { state.selectedUID = $0 })) {
                ForEach(state.rows, id: \.uid) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if row.isUnread { Circle().fill(SSColor.accent).frame(width: 7, height: 7).accessibilityLabel("Unread") }
                            Text(row.message.from.first.map { $0.name ?? $0.email } ?? "Unknown").fontWeight(row.isUnread ? .semibold : .regular).lineLimit(1)
                            Spacer()
                            if let date = row.message.date { Text(date, style: .date).font(SSTypography.caption()).foregroundStyle(.secondary) }
                        }
                        Text(row.message.subject.isEmpty ? "(no subject)" : row.message.subject).font(.system(size: 12)).lineLimit(1)
                        Text((row.message.plainText ?? "").prefix(120).replacingOccurrences(of: "\n", with: " ")).font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(row.uid).padding(.vertical, 2)
                }
            }.listStyle(.plain)
            if state.rows.isEmpty && !state.busy { Text("No messages loaded.").font(SSTypography.caption()).foregroundStyle(.secondary).padding() }
        }
    }

    @ViewBuilder private var reader: some View {
        if let row = state.selected {
            let m = row.message
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(m.subject.isEmpty ? "(no subject)" : m.subject).font(SSTypography.title())
                    Text("From \(m.from.map(\.display).joined(separator: ", "))").font(SSTypography.caption()).foregroundStyle(.secondary)
                    if !m.to.isEmpty { Text("To \(m.to.map(\.display).joined(separator: ", "))").font(SSTypography.caption()).foregroundStyle(.secondary) }
                    HStack {
                        Button { composing = state.account.map { MailDraft.reply(to: m, from: $0.sender) } } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                        Button { composing = state.account.map { MailDraft.reply(to: m, from: $0.sender, all: true) } } label: { Label("Reply all", systemImage: "arrowshape.turn.up.left.2") }
                    }.controlSize(.small)
                    Divider()
                    Text(m.plainText ?? m.html.map { $0.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) } ?? "(no text)")
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if !m.attachments.isEmpty {
                        Divider()
                        ForEach(m.attachments, id: \.filename) { Label("\($0.filename) · \($0.data.count / 1024) KB", systemImage: "paperclip").font(SSTypography.caption()) }
                    }
                }.padding(SSSpacing.m)
            }
        } else {
            SSEmptyState(symbol: "envelope.open", title: "No message selected", message: "Choose a message from the list.")
        }
    }
}

struct AddMailAccountSheet: View {
    let state: MailState
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var address = ""
    @State private var password = ""
    @State private var working = false
    @State private var failure: String?
    @State private var showAdvanced = false
    @State private var imapHost = ""
    @State private var smtpHost = ""
    @State private var imapPort = "993"
    @State private var smtpPort = "465"
    @State private var imapSecurity = MailSecurity.tls
    @State private var smtpSecurity = MailSecurity.tls

    private var domain: String? { MailAutoconfig.domain(of: address) }
    private var guide: MailProviderGuide.Note? { domain.flatMap(MailProviderGuide.note(for:)) }
    private var canContinue: Bool { !address.isEmpty && !password.isEmpty && !working && (!showAdvanced || (!imapHost.isEmpty && !smtpHost.isEmpty)) }

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.m) {
            Text("Add a mail account").font(SSTypography.title())
            Text("Enter your details. Kiln finds the servers and checks the sign-in before saving anything.").font(SSTypography.caption()).foregroundStyle(.secondary)
            TextField("Name", text: $name)
            TextField("Email address", text: $address).onSubmit { if canContinue { go() } }
            SecureField("Password", text: $password).onSubmit { if canContinue { go() } }
            if let guide {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(SSColor.accent)
                    Text(guide.text).font(SSTypography.caption()).foregroundStyle(.secondary)
                    if let url = guide.url { Link("Open", destination: url).font(SSTypography.caption()) }
                }
            }
            DisclosureGroup("Advanced: set the servers yourself", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Incoming server (IMAP)", text: $imapHost)
                    HStack {
                        TextField("Port", text: $imapPort).frame(width: 80)
                        Picker("Incoming security", selection: $imapSecurity) { ForEach(MailSecurity.allCases, id: \.self) { Text($0.label).tag($0) } }.labelsHidden().fixedSize()
                    }
                    TextField("Outgoing server (SMTP)", text: $smtpHost)
                    HStack {
                        TextField("Port", text: $smtpPort).frame(width: 80)
                        Picker("Outgoing security", selection: $smtpSecurity) { ForEach(MailSecurity.allCases, id: \.self) { Text($0.label).tag($0) } }.labelsHidden().fixedSize()
                    }
                    Text("Unencrypted connections are accepted only for localhost, to test with a local mail server.").font(SSTypography.caption()).foregroundStyle(.secondary)
                }.padding(.top, 4)
            }
            if let failure { Text(failure).font(SSTypography.caption()).foregroundStyle(SSColor.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if working { ProgressView().controlSize(.small); Text("Finding servers and checking your sign-in…").font(SSTypography.caption()).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Continue") { go() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!canContinue)
            }
        }
        .textFieldStyle(.roundedBorder).padding(SSSpacing.l).frame(width: 460)
    }

    private func go() {
        failure = nil; working = true
        let manual: MailAccount? = showAdvanced ? Int(imapPort).flatMap { imap in Int(smtpPort).map { smtp in
            MailAccount(displayName: name, address: address, imapHost: imapHost, imapPort: imap, imapSecurity: imapSecurity, smtpHost: smtpHost, smtpPort: smtp, smtpSecurity: smtpSecurity)
        } } : nil
        if showAdvanced && manual == nil { failure = "Ports must be numbers."; working = false; return }
        Task {
            let error = await state.setUp(name: name, address: address, password: password, manual: manual)
            working = false
            if let error { failure = error; if error.contains("Open Advanced") { showAdvanced = true } } else { isPresented = false }
        }
    }
}

/// Nothing leaves the Mac until the person presses Send here, with the recipients and subject in view.
struct ComposeSheet: View {
    let state: MailState
    @State var draft: MailDraft
    let close: () -> Void
    @State private var to = ""
    @State private var cc = ""
    @State private var suggestions: [ContactEntry] = []
    @State private var contactsAccess = ContactsService().access
    private let contacts = ContactsService()

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            Text("New message").font(SSTypography.title())
            Text("From \(draft.from.display)").font(SSTypography.caption()).foregroundStyle(.secondary)
            TextField("To (comma separated)", text: $to)
                .task(id: to) { await suggest(for: to) }
            if contactsAccess == .notDetermined {
                Button("Allow Contacts to complete addresses") { Task { contactsAccess = await contacts.ensureAccess() } }.controlSize(.small).buttonStyle(.link)
            }
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions.flatMap { c in c.emails.map { (c, $0) } }.prefix(8), id: \.1) { c, email in
                            Button { accept(email) } label: {
                                Text(c.name.isEmpty ? email : "\(c.name) · \(email)").font(.system(size: 11.5)).lineLimit(1)
                                    .padding(.horizontal, 8).padding(.vertical, 3).background(SSColor.surfaceRaised, in: Capsule())
                            }.buttonStyle(.plain).accessibilityLabel("Add \(email)")
                        }
                    }
                }
            }
            TextField("Cc", text: $cc)
            TextField("Subject", text: $draft.subject)
            TextEditor(text: $draft.body).font(.system(size: 13)).frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SSColor.hairline))
            if let message = state.message { Text(message).font(SSTypography.caption()).foregroundStyle(SSColor.danger) }
            HStack {
                Text(recipientsSummary).font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Discard", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("Send") {
                    draft.to = MIMEParser.addresses(to); draft.cc = MIMEParser.addresses(cc)
                    Task { if await state.send(draft) { close() } }
                }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
                    .disabled(MIMEParser.addresses(to).isEmpty || state.busy)
            }
        }
        .textFieldStyle(.roundedBorder).padding(SSSpacing.l).frame(width: 520)
        .onAppear { to = draft.to.map(\.email).joined(separator: ", "); cc = draft.cc.map(\.email).joined(separator: ", ") }
    }

    /// The part of the To field after the last comma is the address being typed.
    private func suggest(for text: String) async {
        let token = text.split(separator: ",", omittingEmptySubsequences: false).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard token.count >= 2, !token.contains("@") || token.count >= 3, contacts.access.isAuthorized else { suggestions = []; return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        suggestions = (try? await contacts.search(token, limit: 5)) ?? []
    }

    private func accept(_ email: String) {
        var parts = to.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty { parts = [email] } else { parts[parts.count - 1] = email }
        to = parts.joined(separator: ", ") + ", "
        suggestions = []
    }

    private var recipientsSummary: String {
        let all = MIMEParser.addresses(to) + MIMEParser.addresses(cc)
        return all.isEmpty ? "Add a recipient." : "Will be sent to \(all.map(\.email).joined(separator: ", "))."
    }
}


/// Opens a prefilled text in the Messages app. The person reviews and sends it there; Kiln cannot send, read replies or confirm delivery.
struct TextMessageSheet: View {
    @Binding var isPresented: Bool
    var initialTo = ""
    var body: some View { TextMessageForm(initialTo: initialTo, onClose: { isPresented = false }).frame(width: 500) }
}

/// The compose form itself, used in a sheet (Mail, Contacts) and as the page of the Messages activity.
struct TextMessageForm: View {
    var initialTo = ""
    var onClose: () -> Void
    @State private var to = ""
    @State private var seeded = false
    @State private var text = ""
    @State private var suggestions: [(name: String, value: String)] = []
    @State private var note: String?
    @State private var contactsAccess = ContactsService().access
    private let contacts = ContactsService()

    private var parsed: (valid: [MessageRecipient], invalid: [String]) { MessageRecipient.parseList(to) }

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            Text("New text message").font(SSTypography.title())
            TextField("To: phone numbers or Apple ID emails, comma separated", text: $to).textFieldStyle(.roundedBorder)
                .task(id: to) { await suggest() }
            if contactsAccess == .notDetermined {
                Button("Allow Contacts to find numbers") { Task { contactsAccess = await contacts.ensureAccess() } }.controlSize(.small).buttonStyle(.link)
            }
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.value) { s in
                            Button { accept(s.value) } label: {
                                Text("\(s.name) · \(s.value)").font(.system(size: 11.5)).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(SSColor.surfaceRaised, in: Capsule())
                            }.buttonStyle(.plain).accessibilityLabel("Add \(s.name), \(s.value)")
                        }
                    }
                }
            }
            TextEditor(text: $text).font(.system(size: 13)).frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SSColor.hairline))
            if !parsed.invalid.isEmpty { Text("Not a phone number or email: \(parsed.invalid.joined(separator: ", "))").font(SSTypography.caption()).foregroundStyle(SSColor.danger) }
            if let note { Text(note).font(SSTypography.caption()).foregroundStyle(.secondary) }
            Text("Kiln opens this in Messages for you to review and send. It cannot send for you, read replies or confirm delivery.")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close") { onClose() }.keyboardShortcut(.cancelAction)
                Button("Open in Messages") {
                    let r = parsed
                    Task {
                        let ok = await SystemMessageComposer().open(recipients: r.valid, body: text.trimmingCharacters(in: .whitespacesAndNewlines), attachments: [])
                        if ok { onClose() } else { note = "Messages could not open a compose window. Open the Messages app once and sign in." }
                    }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(parsed.valid.isEmpty || !parsed.invalid.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(SSSpacing.l).frame(maxWidth: 520)
        .onAppear { if !seeded { seeded = true; if !initialTo.isEmpty { to = initialTo } } }
    }

    private func suggest() async {
        let token = to.split(separator: ",", omittingEmptySubsequences: false).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard token.count >= 2, contacts.access.isAuthorized else { suggestions = []; return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let found = (try? await contacts.search(token, limit: 5)) ?? []
        suggestions = found.flatMap { c in (c.phones + c.emails).map { (name: c.name.isEmpty ? "Unnamed" : c.name, value: $0) } }.prefix(8).map { $0 }
    }

    private func accept(_ value: String) {
        var parts = to.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty { parts = [value] } else { parts[parts.count - 1] = value }
        to = parts.joined(separator: ", ") + ", "
        suggestions = []
    }
}

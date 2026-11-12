import SwiftUI

struct MailView: View {
    @State private var state = MailState()
    @State private var addingAccount = false
    @State private var composing: MailDraft?

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
                SSEmptyState(symbol: "envelope", title: "No mail account yet", message: "Add an account to read and write email. Passwords are kept in your Keychain; Kiln never shows them again.")
                    .overlay(alignment: .bottom) { Button("Add an account") { addingAccount = true }.buttonStyle(.borderedProminent).padding(.bottom, 80) }
            } else {
                HSplitView {
                    list.frame(minWidth: 260, idealWidth: 320)
                    reader.frame(minWidth: 320)
                }
            }
        }
        .background(SSColor.canvas)
        .task { state.load(); if state.account != nil { await state.refresh() } }
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
    @State private var imapHost = ""
    @State private var smtpHost = ""

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.m) {
            Text("Add a mail account").font(SSTypography.title())
            TextField("Your name", text: $name)
            TextField("Email address", text: $address).onChange(of: address) { _, v in
                if let preset = MailAccount.preset(for: v) { imapHost = preset.imapHost; smtpHost = preset.smtpHost }
            }
            SecureField("Password or app password", text: $password)
            TextField("Incoming server (IMAP)", text: $imapHost)
            TextField("Outgoing server (SMTP)", text: $smtpHost)
            Text("Connections use TLS (ports 993 and 465). Gmail, iCloud, Outlook and Yahoo need an app-specific password. The password is saved in your Keychain.")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
            if let message = state.message { Text(message).font(SSTypography.caption()).foregroundStyle(SSColor.danger) }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    state.add(MailAccount(displayName: name, address: address, imapHost: imapHost, smtpHost: smtpHost), password: password)
                    if state.message == nil { isPresented = false }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(address.isEmpty || password.isEmpty || imapHost.isEmpty || smtpHost.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder).padding(SSSpacing.l).frame(width: 440)
    }
}

/// Nothing leaves the Mac until the person presses Send here, with the recipients and subject in view.
struct ComposeSheet: View {
    let state: MailState
    @State var draft: MailDraft
    let close: () -> Void
    @State private var to = ""
    @State private var cc = ""

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            Text("New message").font(SSTypography.title())
            Text("From \(draft.from.display)").font(SSTypography.caption()).foregroundStyle(.secondary)
            TextField("To (comma separated)", text: $to)
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

    private var recipientsSummary: String {
        let all = MIMEParser.addresses(to) + MIMEParser.addresses(cc)
        return all.isEmpty ? "Add a recipient." : "Will be sent to \(all.map(\.email).joined(separator: ", "))."
    }
}

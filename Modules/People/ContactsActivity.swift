import SwiftUI

extension Activity { static let contacts = Activity("contacts") }

enum ContactsActivity {
    static let descriptor = ActivityDescriptor(id: "contacts", title: "Contacts", symbol: "person.crop.circle", summary: "Look people up in your Contacts", moduleIdentifier: nil,
        content: .custom { _ in AnyView(ContactsView()) },
        starterPrompts: { _ in [StarterPrompt(title: "Find someone", symbol: "person.crop.circle", text: "Look up a person in my Contacts and show their email and phone number.")] },
        toolPrefixes: ["contacts_"],
        agentPromptSentence: "Use contacts_search to find a person's email or phone number in the user's Contacts. It is read-only.",
        capabilities: [
            .tool("contacts_status", "Check Contacts access", .read),
            .tool("contacts_search", "Find people in Contacts", .read),
        ], registerTools: { context in ContactsTool.register(into: context.registry) })
}

struct ContactsView: View {
    @State private var query = ""
    @State private var results: [ContactEntry] = []
    @State private var access = ContactsService().access
    @State private var searched = false
    @State private var message: String?
    @State private var textingTo: TextTarget?
    private let service = ContactsService()

    private struct TextTarget: Identifiable { var to: String; var id: String { to } }

    var body: some View {
        VStack(spacing: 0) {
            SSActivityHeader(title: "Contacts", subtitle: "Read-only lookup in your Contacts", symbol: "person.crop.circle")
            if !access.isAuthorized {
                VStack(spacing: SSSpacing.s) {
                    Image(systemName: "person.crop.circle").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(access.explanation).font(SSTypography.caption()).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                    if access == .notDetermined {
                        Button("Allow access to Contacts") { Task { access = await service.ensureAccess() } }.buttonStyle(.borderedProminent)
                    }
                    Text("Kiln only reads contacts, to complete email addresses and let approved agents look people up. It never changes them.")
                        .font(SSTypography.caption()).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextField("Search by name, company or email", text: $query).textFieldStyle(.roundedBorder).padding(SSSpacing.m)
                    .task(id: query) { await search() }
                if let message { Text(message).font(SSTypography.caption()).foregroundStyle(SSColor.danger).padding(.horizontal, SSSpacing.m) }
                if results.isEmpty {
                    Text(searched ? "No contacts match." : "Type a name, company or email.").font(SSTypography.caption()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(results) { c in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name.isEmpty ? "(no name)" : c.name).fontWeight(.medium)
                                if !c.organization.isEmpty { Text(c.organization).font(SSTypography.caption()).foregroundStyle(.secondary) }
                                ForEach(c.emails, id: \.self) { Label($0, systemImage: "envelope").font(SSTypography.caption()).textSelection(.enabled) }
                                ForEach(c.phones, id: \.self) { Label($0, systemImage: "phone").font(SSTypography.caption()).textSelection(.enabled) }
                            }
                            Spacer()
                            if let first = c.phones.first ?? c.emails.first {
                                Button("Text…") { textingTo = TextTarget(to: first) }.controlSize(.small).help("Open a message to \(c.name) in Messages")
                            }
                        }.padding(.vertical, 3)
                    }.listStyle(.plain)
                }
            }
        }
        .background(SSColor.canvas)
        .sheet(item: $textingTo) { target in TextMessageSheet(isPresented: Binding(get: { true }, set: { if !$0 { textingTo = nil } }), initialTo: target.to) }
    }

    private func search() async {
        access = service.access
        let q = query.trimmingCharacters(in: .whitespaces)
        guard access.isAuthorized, q.count >= 1 else { results = []; searched = false; return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        do { results = try await service.search(q, limit: 40); searched = true; message = nil } catch { message = error.localizedDescription }
    }
}

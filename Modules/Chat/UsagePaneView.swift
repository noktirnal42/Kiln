import SwiftUI

/// Tokens and estimated cost per provider, model and day, a daily budget that stops runs, and prices for hosted models.
struct UsagePaneView: View {
    let session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var tick = 0
    @State private var budgetTokens = ""
    @State private var budgetUSD = ""
    @State private var priceModel = ""
    @State private var priceIn = ""
    @State private var priceOut = ""
    @State private var validationMessage: String?

    private var ledger: UsageLedger? { session.usageLedger }

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            HStack { Text("Usage").font(SSTypography.headline()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            if let ledger {
                let _ = tick
                let today = ledger.today()
                Text("Today: \(today.tokens.formatted()) tokens · \(today.runs) runs · \(cost(today))").font(SSTypography.body())
                Text("Costs are estimates from the prices you enter below. Local models are free; hosted models without a price show as unpriced.")
                    .font(SSTypography.caption()).foregroundStyle(.secondary)
                HStack {
                    TextField("Daily token budget (0 = none)", text: $budgetTokens).textFieldStyle(.roundedBorder)
                    TextField("Daily USD budget (0 = none)", text: $budgetUSD).textFieldStyle(.roundedBorder)
                    Button("Set budget") {
                        guard let budget = UsageInput.budget(tokens: budgetTokens, dollars: budgetUSD) else {
                            validationMessage = "Enter a nonnegative whole token count and a valid dollar amount. Use 0 for no limit."
                            return
                        }
                        ledger.setBudget(budget); validationMessage = "Budget saved."; tick += 1
                    }
                }
                HStack {
                    TextField("Model id", text: $priceModel).textFieldStyle(.roundedBorder)
                    TextField("$ / 1M in", text: $priceIn).textFieldStyle(.roundedBorder).frame(width: 90)
                    TextField("$ / 1M out", text: $priceOut).textFieldStyle(.roundedBorder).frame(width: 90)
                    Button("Set price") {
                        guard !priceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              let price = UsageInput.price(input: priceIn, output: priceOut) else {
                            validationMessage = "Enter a model ID and valid nonnegative input and output prices."
                            return
                        }
                        ledger.setPrice(price, forModel: priceModel.trimmingCharacters(in: .whitespacesAndNewlines)); validationMessage = "Price saved."; tick += 1
                    }
                }
                if let validationMessage { Text(validationMessage).font(.caption).accessibilityLabel(validationMessage) }
                List {
                    if !ledger.all.isEmpty {
                        Section("By provider") { ForEach(ledger.byProvider(), id: \.key) { row($0) } }
                        Section("By model") { ForEach(ledger.byModel(), id: \.key) { row($0) } }
                        Section("By day") { ForEach(ledger.daily(), id: \.key) { row($0) } }
                    }
                }
                .overlay {
                    if ledger.all.isEmpty {
                        ContentUnavailableView("No usage recorded", systemImage: "chart.bar",
                            description: Text("Token usage appears here after a model responds."))
                    }
                }
            } else {
                Text("Usage is not recorded in this build.").foregroundStyle(.secondary)
            }
        }
        .padding(SSSpacing.m).frame(width: 640, height: 520)
        .onAppear {
            if let b = ledger?.budget { budgetTokens = b.dailyTokens > 0 ? String(b.dailyTokens) : ""; budgetUSD = b.dailyUSD > 0 ? String(b.dailyUSD) : "" }
        }
    }

    private func cost(_ l: UsageLine) -> String {
        String(format: "$%.4f", l.costUSD) + (l.unpricedTokens > 0 ? " + \(l.unpricedTokens.formatted()) tokens unpriced" : "")
    }

    private func row(_ l: UsageLine) -> some View {
        HStack { Text(l.key).lineLimit(1); Spacer(); Text("\(l.tokens.formatted()) tokens · \(cost(l))").font(SSTypography.caption()).foregroundStyle(.secondary) }
    }
}

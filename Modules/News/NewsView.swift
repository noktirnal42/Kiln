import SwiftUI
import RSSReaderCore

struct NewsView: View {
    @State private var state = NewsState.shared
    @State private var query = ""
    @State private var customURL = ""
    @State private var category = "All"
    @State private var showDirectory = false
    private var sources: [DirectorySource] {
        BuiltInSources.all.filter { (category == "All" || $0.category == category) && (query.isEmpty || "\($0.name) \($0.summary) \($0.tags.joined(separator: " "))".localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(spacing: 0) {
            SSActivityHeader(title: "News", subtitle: "Your chosen sources", symbol: "newspaper", trailing: { EmptyView() })
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("Sources").font(.headline); Spacer(); Button("Discover") { showDirectory = true } }
                    HStack { TextField("Feed URL", text: $customURL).textFieldStyle(.roundedBorder); Button("Add") { add(customURL) }.disabled(customURL.isEmpty) }
                    List(selection: $state.selected) {
                        ForEach(state.sources, id: \.self) { source in
                            HStack { Text(BuiltInSources.all.first(where: { $0.url.absoluteString == source })?.name ?? source).lineLimit(2); Spacer()
                                Button { state.remove(source) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove subscription")
                            }.tag(source)
                        }
                    }.listStyle(.plain)
                    if state.sources.isEmpty { Text("Choose sources in Discover or add a feed URL.").font(.caption).foregroundStyle(.secondary) }
                }.padding(10).frame(width: 290)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    HStack { Text(state.title).font(.headline); Spacer(); if state.busy { ProgressView().controlSize(.small) }; Button("Refresh") { if let source = state.selected { refresh(source) } }.disabled(state.selected == nil || state.busy) }.padding(10)
                    Divider()
                    if state.articles.isEmpty {
                        ContentUnavailableView("No stories loaded", systemImage: "newspaper", description: Text(state.message ?? "Select a source to fetch its latest entries."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(state.articles) { article in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(article.title).font(.headline)
                                if let date = article.publishedAt { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                                Text(article.summaryHTML.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)).font(.callout).lineLimit(4)
                                if let url = article.link { Link("Open article", destination: url) }
                            }.padding(.vertical, 5)
                        }.listStyle(.plain)
                    }
                }
            }
        }
        .onChange(of: state.selected) { _, value in if let value { refresh(value) } }
        .sheet(isPresented: $showDirectory) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Discover sources").font(.headline); Spacer(); Button("Done") { showDirectory = false } }
                HStack { TextField("Search names, topics and tags", text: $query).textFieldStyle(.roundedBorder); Picker("Category", selection: $category) { Text("All").tag("All"); ForEach(BuiltInSources.categories, id: \.self) { Text($0).tag($0) } }.frame(width: 180) }
                List(sources) { source in
                    HStack { VStack(alignment: .leading) { Text(source.name).font(.headline); Text("\(source.category) · \(source.summary)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button(state.sources.contains(source.url.absoluteString) ? "Added" : "Add") { add(source.url.absoluteString) }.disabled(state.sources.contains(source.url.absoluteString)) }
                }.listStyle(.plain)
                if let message = state.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }.padding(16).frame(minWidth: 650, minHeight: 500)
        }
    }
    private func add(_ value: String) { do { try state.add(value); customURL = ""; state.message = nil } catch { state.message = error.localizedDescription } }
    private func refresh(_ value: String) { state.busy = true; Task { defer { state.busy = false }; do { try await state.refresh(value) } catch { state.message = error.localizedDescription; state.articles = [] } } }
}

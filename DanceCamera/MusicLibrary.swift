import SwiftUI

struct LibraryAccount {
    var server = ""
    var username = ""
    var secret = ""
    var useKey = false

    func client() throws -> Navidrome {
        try Navidrome(address: server, login: useKey ? .apiKey(secret) : .account(username, secret))
    }
}

struct MusicLibrary: View {
    @State private var account = LibraryAccount()
    @State private var client: Navidrome?
    @State private var connecting = false
    @State private var message = ""
    @State private var query = ""
    @State private var category = Category.songs
    @State private var selected: LibraryCollection?
    @State private var songs: [LibrarySong] = []
    @State private var collections: [LibraryCollection] = []
    @State private var busy = false
    @State private var hasMore = false
    @State private var page = 0
    @State private var revision = UUID()
    @State private var connectionOpen = false
    @ObservedObject var camera: DanceRecorder
    let pickMusic: () -> Void
    let pickFile: () -> Void

    enum Category: String, CaseIterable { case songs = "Songs", albums = "Albums", playlists = "Playlists" }
    var body: some View {
        List {
            Section {
                Button(action: pickMusic) { Label("iPhone Music Library", systemImage: "music.note.list") }
                Button(action: pickFile) { Label("Open from Files", systemImage: "folder") }
            }
            Section {
                if client == nil {
                    Button("Connect to Navidrome") { connectionOpen = true }
                } else {
                    if selected == nil {
                        Picker("Browse", selection: $category) {
                            ForEach(Category.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).onChange(of: category) { _, _ in reload() }
                        if category == .songs {
                            TextField("Search songs, artists or albums", text: $query)
                                .autocorrectionDisabled().submitLabel(.search)
                                .onChange(of: query) { _, _ in reload() }
                        }
                    } else {
                        Button { selected = nil; reload() } label: { Label(category.rawValue, systemImage: "chevron.left") }
                    }
                    if busy { ProgressView() }
                    if !message.isEmpty { Text(message).font(.footnote) }
                    if let selected { Text(selected.name).font(.title3.bold()) }
                    ForEach(songs) { song in
                        HStack {
                            Button { play(song, enqueue: false) } label: {
                                VStack(alignment: .leading) {
                                    Text(song.title).foregroundStyle(.primary)
                                    if let artist = song.artist { Text(artist).font(.caption).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { play(song, enqueue: true) } label: {
                                Image(systemName: "text.badge.plus").accessibilityLabel("Queue \(song.title)")
                            }.buttonStyle(.borderless)
                        }
                    }
                    ForEach(collections) { item in
                        Button { selected = item; reload() } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.name)
                                    if let artist = item.artist { Text(artist).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                        }
                    }
                    if hasMore && !busy { Button("More albums") { page += 1; revision = UUID() } }
                }
            } header: { Text("Navidrome") }
            if !camera.upcoming.isEmpty {
                Section("Up next") {
                    ForEach(Array(camera.upcoming.enumerated()), id: \.offset) { entry in Text(entry.element) }
                }
            }
            if client != nil {
                Button("Disconnect Navidrome") {
                    client = nil; account.secret = ""; selected = nil; query = ""; reload()
                }
            }
        }
        .task(id: revision) { await load() }
        .sheet(isPresented: $connectionOpen) {
            NavigationStack {
                Form {
                    TextField("Server URL", text: $account.server)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Picker("Sign in with", selection: $account.useKey) {
                        Text("Account").tag(false)
                        Text("API key").tag(true)
                    }.onChange(of: account.useKey) { _, _ in account.secret = "" }
                    if account.useKey {
                        SecureField("API key", text: $account.secret)
                    } else {
                        TextField("Username", text: $account.username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $account.secret)
                            .textContentType(.password)
                    }
                    Button("Connect") {
                        connecting = true
                        Task {
                            defer { connecting = false }
                            do {
                                let server = try account.client()
                                _ = try await server.songs(matching: "")
                                client = server
                                connectionOpen = false
                                reload()
                            } catch { message = error.localizedDescription }
                        }
                    }.disabled(connecting || account.secret.isEmpty || account.server.isEmpty)
                    if connecting { ProgressView() }
                    if !message.isEmpty { Text(message).font(.footnote) }
                }.navigationTitle("Navidrome")
                .toolbar { Button("Close") { connectionOpen = false }.disabled(connecting) }
            }.interactiveDismissDisabled(connecting)
        }
    }

    private func reload() {
        page = 0
        hasMore = false
        songs = []
        collections = []
        message = ""
        revision = UUID()
    }

    @MainActor private func load() async {
        guard let client else { busy = false; return }
        let ticket = revision
        busy = true
        defer { if ticket == revision { busy = false } }
        do {
            if let selected {
                let result = try await client.tracks(in: selected, album: category == .albums)
                try Task.checkCancellation()
                guard revision == ticket else { return }
                songs = result
            } else if category == .songs {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
                let result = try await client.songs(matching: query)
                try Task.checkCancellation()
                guard revision == ticket else { return }
                songs = result
            } else {
                let result = try await client.collections(albums: category == .albums, offset: page * 100)
                try Task.checkCancellation()
                guard revision == ticket else { return }
                if page == 0 { collections = result } else { collections += result }
                hasMore = category == .albums && result.count == 100
            }
            message = songs.isEmpty && collections.isEmpty ? "No results." : ""
        } catch { if !Task.isCancelled && revision == ticket { message = error.localizedDescription } }
    }

    private func play(_ song: LibrarySong, enqueue: Bool) {
        guard let client else { return }
        camera.selectStream(client.streamRequest(for: song), title: song.displayName,
                            key: client.base.absoluteString + "|" + song.id, enqueue: enqueue)
    }
}

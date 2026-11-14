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
    @Environment(\.dismiss) private var dismiss
    @Binding var account: LibraryAccount
    let select: (URL, String) throws -> Void
    @State private var query = ""
    @State private var songs: [LibrarySong] = []
    @State private var message = ""
    @State private var busy = false
    @State private var connected = false
    @State private var work: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                if !connected {
                    Section("Navidrome server") {
                        TextField("Server URL", text: $account.server)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Picker("Sign in with", selection: $account.useKey) {
                            Text("Account").tag(false)
                            Text("API key").tag(true)
                        }.onChange(of: account.useKey) { _, _ in account.secret = "" }
                        if !account.useKey {
                            TextField("Username", text: $account.username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        SecureField(account.useKey ? "API key" : "Password", text: $account.secret)
                        Button("Connect") { search() }
                            .disabled(account.server.isEmpty || account.secret.isEmpty || (!account.useKey && account.username.isEmpty))
                    }.disabled(busy)
                } else {
                    Section("Library") {
                        TextField("Song, artist or album", text: $query)
                            .submitLabel(.search).onSubmit { if !busy { search() } }
                        Button("Search") { search() }
                        Button("Sign out", role: .destructive) {
                            account.secret = ""
                            songs = []
                            query = ""
                            connected = false
                            message = ""
                        }
                    }.disabled(busy)
                }
                if busy { ProgressView(message) }
                else if !message.isEmpty { Text(message).font(.footnote) }
                if !songs.isEmpty {
                    Section("Songs") {
                        ForEach(songs) { song in
                            Button { prepare(song) } label: {
                                VStack(alignment: .leading) {
                                    Text(song.title)
                                    if let artist = song.artist { Text(artist).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }.disabled(busy)
                }
            }
            .navigationTitle("Navidrome")
            .toolbar { Button("Close") { work?.cancel(); dismiss() } }
        }
        .onAppear {
            if !account.secret.isEmpty && !busy && !connected { search() }
        }
        .onDisappear { work?.cancel() }
    }

    private func search() {
        guard !busy else { return }
        busy = true
        songs = []
        message = "Loading songs…"
        work = Task {
            defer { busy = false }
            do {
                let result = try await account.client().songs(matching: query)
                try Task.checkCancellation()
                connected = true
                songs = result
                message = result.isEmpty ? "No songs found. Try a different search." : ""
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }

    private func prepare(_ song: LibrarySong) {
        guard !busy else { return }
        busy = true
        message = "Preparing \(song.title)…"
        work = Task {
            defer { busy = false }
            do {
                let file = try await account.client().prepare(song)
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                try select(file, song.displayName)
                dismiss()
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}

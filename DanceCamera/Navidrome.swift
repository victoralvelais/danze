import Foundation
import CryptoKit
import Network

struct LibrarySong: Decodable, Identifiable {
    let id: String
    let title: String
    let artist: String?

    var displayName: String {
        guard let artist, !artist.isEmpty else { return title }
        return "\(title) — \(artist)"
    }
}

struct LibraryCollection: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let artist: String?
}

private struct SubsonicReply: Decodable {
    struct Body: Decodable {
        struct Failure: Decodable { let code: Int }
        struct Songs: Decodable { let song: [LibrarySong]? }
        struct Albums: Decodable { let album: [LibraryCollection]? }
        struct Playlists: Decodable { let playlist: [LibraryCollection]? }
        struct Playlist: Decodable { let entry: [LibrarySong]? }
        let albumList2: Albums?
        let album: Songs?
        let playlists: Playlists?
        let playlist: Playlist?
        let status: String
        let error: Failure?
        let searchResult3: Songs?
        let randomSongs: Songs?
    }

    let body: Body
    enum CodingKeys: String, CodingKey { case body = "subsonic-response" }

    static func checked(_ data: Data) throws -> Body {
        guard let body = try? JSONDecoder().decode(Self.self, from: data).body else {
            throw TakeError("This address did not return a Navidrome response. Check the server URL, including any base path.")
        }
        guard body.status == "ok" else {
            switch body.error?.code {
            case 40, 41, 42, 43: throw TakeError("Navidrome rejected the sign-in. Check your credentials and sign-in method.")
            case 50: throw TakeError("This account does not have access to the requested music.")
            case 70: throw TakeError("Navidrome could not find that song. Search the library again.")
            default: throw TakeError("Navidrome returned an error (code \(body.error?.code ?? 0)).")
            }
        }
        return body
    }
}

private final class NavidromeRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A 307/308 can replay the form, including its authentication, to another server.
        completionHandler(nil)
    }
}

struct Navidrome {
    enum Login {
        case account(String, String)
        case apiKey(String)
    }

    let base: URL
    let login: Login

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: NavidromeRedirects(), delegateQueue: nil)
    }()

    init(address: String, login: Login) throws {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              let url = parts.url, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let scheme = parts.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && Self.isLocal(host)) else {
            throw TakeError("Enter your server's HTTPS address or a local HTTP address, including any base path.")
        }
        switch login {
        case .apiKey(let key):
            guard !key.isEmpty else { throw TakeError("Enter your Navidrome API key.") }
        case .account(let name, let password):
            guard !name.isEmpty, !password.isEmpty else { throw TakeError("Enter your Navidrome username and password.") }
        }
        self.base = url
        self.login = login
    }

    private static func isLocal(_ name: String) -> Bool {
        let host = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let address = IPv4Address(host) {
            let b = Array(address.rawValue)
            return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1])) ||
                (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254) ||
                (b[0] == 100 && (64...127).contains(b[1]))
        }
        if let address = IPv6Address(host) {
            let b = Array(address.rawValue)
            return host == "::1" || (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80)
        }
        return host.hasSuffix(".local") || (!host.contains(".") && !host.contains(":") && host.contains(where: \.isLetter))
    }

    private func request(_ method: String, _ params: [URLQueryItem] = []) -> URLRequest {
        let url = base.appendingPathComponent("rest").appendingPathComponent(method + ".view")
        var args = [URLQueryItem(name: "v", value: "1.16.1"), .init(name: "c", value: "DanceCamera"), .init(name: "f", value: "json")]
        switch login {
        case .apiKey(let key):
            args.append(.init(name: "apiKey", value: key))
        case .account(let user, let password):
            let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let token = Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
            args += [.init(name: "u", value: user), .init(name: "s", value: salt), .init(name: "t", value: token)]
        }
        var form = URLComponents()
        form.queryItems = args + params
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return request
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw TakeError("The music server did not respond.") }
        if (300..<400).contains(http.statusCode) {
            throw TakeError("Enter the server's final address. This address redirects the sign-in request.")
        }
        guard (200..<300).contains(http.statusCode) else { throw TakeError("Music server returned HTTP \(http.statusCode).") }
    }

    func songs(matching text: String) async throws -> [LibrarySong] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let req = query.isEmpty ? request("getRandomSongs", [.init(name: "size", value: "30")]) :
            request("search3", [.init(name: "query", value: query), .init(name: "artistCount", value: "0"),
                                .init(name: "albumCount", value: "0"), .init(name: "songCount", value: "50")])
        let (data, response) = try await Self.session.data(for: req)
        try check(response)
        let body = try SubsonicReply.checked(data)
        return (query.isEmpty ? body.randomSongs?.song : body.searchResult3?.song) ?? []
    }

    func collections(albums: Bool, offset: Int = 0) async throws -> [LibraryCollection] {
        let req = albums ? request("getAlbumList2", [.init(name: "type", value: "alphabeticalByName"),
                                                     .init(name: "size", value: "100"), .init(name: "offset", value: String(offset))])
                         : request("getPlaylists")
        let (data, response) = try await Self.session.data(for: req)
        try check(response)
        let body = try SubsonicReply.checked(data)
        return (albums ? body.albumList2?.album : body.playlists?.playlist) ?? []
    }

    func tracks(in collection: LibraryCollection, album: Bool) async throws -> [LibrarySong] {
        let (data, response) = try await Self.session.data(for: request(album ? "getAlbum" : "getPlaylist", [.init(name: "id", value: collection.id)]))
        try check(response)
        let body = try SubsonicReply.checked(data)
        return (album ? body.album?.song : body.playlist?.entry) ?? []
    }

    func streamRequest(for song: LibrarySong) -> URLRequest {
        request("stream", [.init(name: "id", value: song.id), .init(name: "format", value: "mp3")])
    }
}

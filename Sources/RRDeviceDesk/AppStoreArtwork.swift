import Foundation

enum AppStoreArtwork {
    static let batchSize = 100

    private struct Lookup: Decodable {
        struct Item: Decodable {
            let trackId: Int64?
            let artworkUrl100: URL?
            let artworkUrl60: URL?
        }
        let results: [Item]
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        return URLSession(configuration: configuration)
    }()

    static func images(for ids: [Int64]) async -> [Int64: Data]? {
        let country = Locale.current.region?.identifier.lowercased() ?? "us"
        var urls: [Int64: URL] = [:]
        var checkedCountries: Set<String> = []
        var receivedCatalogue = false
        for storefront in [country, "us", "kz"] where checkedCountries.insert(storefront).inserted {
            guard !Task.isCancelled else { return nil }
            let missing = ids.filter { urls[$0] == nil }
            guard !missing.isEmpty else { break }
            if let found = await lookup(missing, country: storefront) {
                receivedCatalogue = true
                urls.merge(found) { current, _ in current }
            }
        }
        guard receivedCatalogue else { return nil }

        return await withTaskGroup(of: (Int64, Data?).self) { group in
            var remaining = urls.makeIterator()
            for _ in 0..<min(6, urls.count) {
                guard let next = remaining.next() else { break }
                group.addTask { (next.key, await image(at: next.value)) }
            }
            var images: [Int64: Data] = [:]
            while let (id, bytes) = await group.next() {
                images[id] = bytes
                if !Task.isCancelled, let next = remaining.next() {
                    group.addTask { (next.key, await image(at: next.value)) }
                }
            }
            return images
        }
    }

    private static func lookup(_ ids: [Int64], country: String) async -> [Int64: URL]? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/lookup"
        components.queryItems = [URLQueryItem(name: "id", value: ids.map(String.init).joined(separator: ",")),
                                 URLQueryItem(name: "entity", value: "software"), URLQueryItem(name: "country", value: country),
                                 URLQueryItem(name: "limit", value: String(ids.count))]
        guard let url = components.url, let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 4 * 1024 * 1024, let reply = try? JSONDecoder().decode(Lookup.self, from: data) else { return nil }
        let requested = Set(ids)
        var images: [Int64: URL] = [:]
        for item in reply.results {
            guard let id = item.trackId, requested.contains(id), let artwork = item.artworkUrl100 ?? item.artworkUrl60,
                  isArtworkURL(artwork) else { continue }
            images[id] = artwork
        }
        return images
    }

    private static func image(at url: URL) async -> Data? {
        guard let (bytes, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let origin = http.url, isArtworkURL(origin),
              http.mimeType?.hasPrefix("image/") == true, bytes.count <= 512 * 1024 else { return nil }
        return bytes
    }

    private static func isArtworkURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return false }
        return host == "mzstatic.com" || host.hasSuffix(".mzstatic.com")
    }
}

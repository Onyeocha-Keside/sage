//
//  AppConfiguration.swift
//  Sage
//
//  Reads the Worker address from SageSecrets.plist.
//
//  SageSecrets.plist is git-ignored so local configuration never lands in a public
//  repo. To set it up, copy config/SageSecrets.example.plist to
//  leanring-buddy/App/SageSecrets.plist and fill in WorkerBaseURL. Xcode picks
//  the file up automatically because the app folder is a synced group.
//

import Foundation

struct SageConfigurationError: LocalizedError {
    var errorDescription: String? {
        "Sage isn't configured yet. Add SageSecrets.plist with WorkerBaseURL, then enter your access token from the Sage menu."
    }
}

enum AppConfiguration {
    private static let secretsFileName = "SageSecrets"
    private static let workerBaseURLKey = "WorkerBaseURL"

    private static let secretsDictionary: [String: Any] = {
        guard let secretsFileURL = Bundle.main.url(forResource: secretsFileName, withExtension: "plist"),
              let loadedDictionary = NSDictionary(contentsOf: secretsFileURL) as? [String: Any] else {
            print("⚠️ Sage: SageSecrets.plist not found in the app bundle")
            return [:]
        }
        return loadedDictionary
    }()

    /// The deployed Worker, e.g. https://sage-api.yourname.workers.dev,
    /// or http://localhost:8787 while running `npx wrangler dev`.
    static var workerBaseURL: URL? {
        guard let rawWorkerBaseURL = trimmedNonEmptySecret(forKey: workerBaseURLKey) else { return nil }
        let workerBaseURLWithoutTrailingSlash = rawWorkerBaseURL.hasSuffix("/")
            ? String(rawWorkerBaseURL.dropLast())
            : rawWorkerBaseURL
        return validatedWorkerURL(workerBaseURLWithoutTrailingSlash)
    }

    /// Credentials may travel over HTTP only to an explicit local development host.
    static func validatedWorkerURL(_ rawValue: String) -> URL? {
        guard let url = URL(string: rawValue), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let isLocalHost = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())
        guard url.scheme?.lowercased() == "https" || (url.scheme?.lowercased() == "http" && isLocalHost) else { return nil }
        return url
    }

    static var isConfigured: Bool {
        workerBaseURL != nil && AccessTokenStore.token != nil
    }

    /// Builds an authenticated POST request to a Worker route like "chat" or "tts".
    static func makeWorkerRequest(path: String) throws -> URLRequest {
        guard let workerBaseURL, let accessToken = AccessTokenStore.token else {
            throw SageConfigurationError()
        }

        var workerRequest = URLRequest(url: workerBaseURL.appendingPathComponent(path))
        workerRequest.httpMethod = "POST"
        workerRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        workerRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return workerRequest
    }

    private static func trimmedNonEmptySecret(forKey key: String) -> String? {
        guard let rawValue = secretsDictionary[key] as? String else { return nil }
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

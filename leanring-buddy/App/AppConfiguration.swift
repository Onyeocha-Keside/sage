//
//  AppConfiguration.swift
//  Sage
//
//  Reads the Worker address and app key from SageSecrets.plist.
//
//  SageSecrets.plist is git-ignored so the app key never lands in a public
//  repo. To set it up, copy config/SageSecrets.example.plist to
//  leanring-buddy/App/SageSecrets.plist and fill in both values. Xcode picks
//  the file up automatically because the app folder is a synced group.
//

import Foundation

struct SageConfigurationError: LocalizedError {
    var errorDescription: String? {
        "Sage isn't configured yet. Add SageSecrets.plist with WorkerBaseURL and AppKey."
    }
}

enum AppConfiguration {
    private static let secretsFileName = "SageSecrets"
    private static let workerBaseURLKey = "WorkerBaseURL"
    private static let appKeyKey = "AppKey"

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
        return URL(string: workerBaseURLWithoutTrailingSlash)
    }

    /// Shared secret the Worker checks on every request (the SAGE_APP_KEY secret).
    static var appKey: String? {
        trimmedNonEmptySecret(forKey: appKeyKey)
    }

    static var isConfigured: Bool {
        workerBaseURL != nil && appKey != nil
    }

    /// Builds an authenticated POST request to a Worker route like "chat" or "tts".
    static func makeWorkerRequest(path: String) throws -> URLRequest {
        guard let workerBaseURL, let appKey else {
            throw SageConfigurationError()
        }

        var workerRequest = URLRequest(url: workerBaseURL.appendingPathComponent(path))
        workerRequest.httpMethod = "POST"
        workerRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        workerRequest.setValue(appKey, forHTTPHeaderField: "x-sage-app-key")
        return workerRequest
    }

    private static func trimmedNonEmptySecret(forKey key: String) -> String? {
        guard let rawValue = secretsDictionary[key] as? String else { return nil }
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

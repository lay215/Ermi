import Foundation
import Testing
import Darwin
@testable import ErmiCore

struct LocalFanAuthorizationTests {
    private let hash = String(repeating: "a", count: 40)

    @Test func acceptsExactBuildRulesButRejectsInjectionAndUnknownSchema() throws {
        let value = try LocalFanAuthorization(userID: 501, clientHash: hash, helperHash: String(repeating: "b", count: 40))
        _ = try FanCodeSignature.requirement(value.clientRequirement)
        _ = try FanCodeSignature.requirement(value.helperRequirement)
        #expect(throws: (any Error).self) { try LocalFanAuthorization(userID: 0, clientHash: hash, helperHash: hash) }
        #expect(throws: (any Error).self) { try LocalFanAuthorization(userID: 501, clientHash: "\(hash)\" or true", helperHash: hash) }
        #expect(throws: (any Error).self) { try LocalFanAuthorization(userID: 501, clientHash: String(repeating: "a", count: 64), helperHash: hash) }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        json["version"] = 3
        let newer = try JSONDecoder().decode(LocalFanAuthorization.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: (any Error).self) { try newer.validate() }
    }

    @Test func stableCertificateRuleSurvivesClientBuildChangesAndPreservesLegacy() throws {
        let legacy = try LocalFanAuthorization(userID: 501, clientHash: hash, helperHash: hash)
        let restored = try JSONDecoder().decode(LocalFanAuthorization.self, from: JSONEncoder().encode(legacy))
        try restored.validate()
        #expect(restored.version == 1)
        #expect(restored.clientRequirement.contains("cdhash"))
        let stable = try LocalFanAuthorization(userID: 501, clientHash: hash, helperHash: hash, clientCertificateSHA1: hash)
        let changed = try LocalFanAuthorization(userID: 501, clientHash: String(repeating: "b", count: 40), helperHash: hash, clientCertificateSHA1: hash)
        #expect(stable.clientRequirement == changed.clientRequirement)
        #expect(stable.helperRequirement == legacy.helperRequirement)
        _ = try FanCodeSignature.requirement(stable.clientRequirement)
        #expect(throws: (any Error).self) {
            try LocalFanAuthorization(userID: 501, clientHash: hash, helperHash: hash, clientCertificateSHA1: "")
        }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stable)) as? [String: Any])
        json.removeValue(forKey: "clientCertificateSHA1")
        let missing = try JSONDecoder().decode(LocalFanAuthorization.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: (any Error).self) { try missing.validate() }
    }

    @Test func realSignatureAcceptsPinnedBinaryAndRejectsChangedHashAndContent() throws {
        let original = URL(fileURLWithPath: "/usr/bin/true")
        let fingerprint = try FanCodeSignature.fingerprint(at: original)
        let rule = "identifier \"\(fingerprint.identifier)\" and cdhash H\"\(fingerprint.hash)\""
        #expect(FanCodeSignature.matches(at: original, requirement: rule))
        let certificate = try #require(fingerprint.certificateSHA1)
        #expect(FanCodeSignature.matches(at: original, requirement: "certificate leaf = H\"\(certificate)\""))
        #expect(!FanCodeSignature.matches(at: original, requirement: "certificate leaf = H\"\(hash)\""))
        #expect(!FanCodeSignature.matches(at: original, requirement: "cdhash H\"\(hash)\""))
        #expect(!FanCodeSignature.matches(at: original, requirement: "identifier \"app.ermi.local\" and cdhash H\"\(fingerprint.hash)\""))
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("changed")
        var bytes = try Data(contentsOf: original)
        bytes[4096] ^= 1
        try bytes.write(to: copy)
        #expect(!FanCodeSignature.matches(at: copy, requirement: rule))
        #expect(throws: (any Error).self) { try FanCodeSignature.fingerprint(at: copy) }
    }

    @Test func refusesWritableWrongOwnerSymlinkAndOversizedAuthorization() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("authorization.json")
        let bytes = try JSONEncoder().encode(LocalFanAuthorization(userID: 501, clientHash: hash, helperHash: hash))
        try bytes.write(to: file)
        chmod(file.path, 0o600)
        #expect(try LocalFanAuthorization.readProtectedFile(file, owner: getuid()) == bytes)
        if getuid() != 0 { #expect(throws: (any Error).self) { try LocalFanAuthorization.readProtectedFile(file) } }
        chmod(file.path, 0o666)
        #expect(throws: (any Error).self) { try LocalFanAuthorization.readProtectedFile(file, owner: getuid()) }
        chmod(file.path, 0o600)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try LocalFanAuthorization.readProtectedFile(link, owner: getuid()) }
        chmod(directory.path, 0o777)
        #expect(throws: (any Error).self) { try LocalFanAuthorization.readProtectedFile(file, owner: getuid()) }
        chmod(directory.path, 0o700)
        try Data(repeating: 65, count: 8193).write(to: file)
        #expect(throws: (any Error).self) { try LocalFanAuthorization.readProtectedFile(file, owner: getuid()) }
    }

    @Test func differentBuildCannotAuthorizeCurrentProcess() throws {
        let value = try LocalFanAuthorization(userID: getuid(), clientHash: hash, helperHash: hash)
        #expect(throws: (any Error).self) { try value.validateClient() }
        #expect(throws: (any Error).self) { try value.validateHelper() }
    }

    private func fixtureDirectory() throws -> URL {
        // 放在工作区中，避免 /tmp 的可写父目录掩盖生产检查所针对的问题。
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
            .appendingPathComponent(".build/local-auth-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
}

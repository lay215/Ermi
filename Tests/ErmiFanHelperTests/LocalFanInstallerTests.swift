import Testing
import ErmiCore
@testable import ErmiFanHelper

@MainActor struct LocalFanInstallerTests {
    private let hash = String(repeating: "a", count: 40)
    @Test func requiresMatchingCertificateAndExpectedIdentifiers() throws {
        let client = FanCodeSignature.Fingerprint(identifier: "app.ermi.local", hash: hash, certificateSHA1: hash)
        let helper = FanCodeSignature.Fingerprint(identifier: FanServiceIdentity.service, hash: hash, certificateSHA1: hash)
        let authorization = try LocalFanInstaller.authorization(client: client, helper: helper, userID: 501)
        #expect(authorization.version == 2)
        #expect(authorization.clientCertificateSHA1 == hash)
        for certificate in [nil, String(repeating: "b", count: 40)] as [String?] {
            let wrong = FanCodeSignature.Fingerprint(identifier: helper.identifier, hash: hash, certificateSHA1: certificate)
            #expect(throws: (any Error).self) {
                try LocalFanInstaller.authorization(client: client, helper: wrong, userID: 501)
            }
        }
        let unsigned = FanCodeSignature.Fingerprint(identifier: client.identifier, hash: hash, certificateSHA1: nil)
        #expect(throws: (any Error).self) {
            try LocalFanInstaller.authorization(client: unsigned, helper: helper, userID: 501)
        }
        let wrongIdentity = FanCodeSignature.Fingerprint(identifier: "other.app", hash: hash, certificateSHA1: hash)
        #expect(throws: (any Error).self) {
            try LocalFanInstaller.authorization(client: wrongIdentity, helper: helper, userID: 501)
        }
        #expect(throws: (any Error).self) {
            try LocalFanInstaller.authorization(client: client, helper: helper, userID: 0)
        }
    }
}

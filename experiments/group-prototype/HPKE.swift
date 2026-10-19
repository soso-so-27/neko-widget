import Foundation
import CryptoKit

struct PrototypeDevice {
    let person: String
    let id: String
    let wrapping = Curve25519.KeyAgreement.PrivateKey()
    let signing = Curve25519.Signing.PrivateKey()
}
struct Envelope {
    let epoch: Int; let device: String; let encapsulated: Data; let ciphertext: Data; let signature: Data
}
enum PrototypeHPKE {
    static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    static func context(epoch: Int, device: String) -> Data { Data("synthetic-room|\(epoch)|\(device)".utf8) }
    static func wrap(_ key: Data, epoch: Int, device: PrototypeDevice, owner: PrototypeDevice) throws -> Envelope {
        let info = context(epoch: epoch, device: device.id)
        var sender = try HPKE.Sender(recipientKey: device.wrapping.publicKey, ciphersuite: suite, info: info)
        let encrypted = try sender.seal(key, authenticating: info)
        let encapsulated = sender.encapsulatedKey
        let signature = try owner.signing.signature(for: info + encapsulated + encrypted)
        return Envelope(epoch: epoch, device: device.id, encapsulated: encapsulated, ciphertext: encrypted, signature: signature)
    }
    static func unwrap(_ envelope: Envelope, device: PrototypeDevice, owner: PrototypeDevice) throws -> Data {
        let info = context(epoch: envelope.epoch, device: envelope.device)
        guard envelope.device == device.id,
              owner.signing.publicKey.isValidSignature(envelope.signature, for: info + envelope.encapsulated + envelope.ciphertext)
        else { throw CocoaError(.fileReadCorruptFile) }
        var recipient = try HPKE.Recipient(privateKey: device.wrapping, ciphersuite: suite,
            info: info, encapsulatedKey: envelope.encapsulated)
        return try recipient.open(envelope.ciphertext, authenticating: info)
    }
    static func runCases() throws -> Data {
        let a = PrototypeDevice(person: "alice", id: "a1")
        let b1 = PrototypeDevice(person: "bob", id: "b1")
        let c = PrototypeDevice(person: "charlie", id: "c1")
        let b2 = PrototypeDevice(person: "bob", id: "b2")
        func epoch(_ number: Int, devices: [PrototypeDevice]) throws -> (Data, [String: Envelope]) {
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            return (key, try Dictionary(uniqueKeysWithValues: devices.map { ($0.id, try wrap(key, epoch: number, device: $0, owner: a)) }))
        }
        let first = try epoch(1, devices: [a,b1,c])
        for device in [a,b1,c] { let key = try unwrap(first.1[device.id]!, device: device, owner: a); precondition(key == first.0) }
        print("HPKE PASS three people")
        let second = try epoch(2, devices: [a,b1,b2,c])
        for device in [a,b1,b2,c] { let key = try unwrap(second.1[device.id]!, device: device, owner: a); precondition(key == second.0) }
        print("HPKE PASS one person two independent devices")
        let third = try epoch(3, devices: [a,c])
        precondition(third.1[b1.id] == nil && third.1[b2.id] == nil)
        let cipher = try AES.GCM.seal(Data("after removal".utf8), using: SymmetricKey(data: third.0), authenticating: Data("room|3|a1".utf8))
        precondition((try? AES.GCM.open(cipher, using: SymmetricKey(data: second.0), authenticating: Data("room|3|a1".utf8))) == nil)
        print("HPKE PASS removed both devices cannot decrypt next epoch")
        let roster = Set([a.id,c.id]); let currentEpoch = 3
        func relayAccepts(sender: String, epoch: Int) -> Bool { epoch == currentEpoch && roster.contains(sender) }
        precondition(!relayAccepts(sender: b1.id, epoch: 2) && !relayAccepts(sender: b2.id, epoch: 3))
        print("HPKE PASS immediate stale send rejected by relay model")
        let resumed = try unwrap(third.1[c.id]!, device: c, owner: a)
        let recovered = try AES.GCM.open(cipher, using: SymmetricKey(data: resumed), authenticating: Data("room|3|a1".utf8)); precondition(recovered == Data("after removal".utf8))
        do { _ = try unwrap(third.1[c.id]!, device: b1, owner: a); preconditionFailure("wrong device accepted") }
        catch { }
        print("HPKE PASS offline latest epoch catch-up and wrong-device rejection")
        return third.0
    }
}
#if PROTOTYPE_CLI
@main enum Probe { static func main() throws { _ = try PrototypeHPKE.runCases() } }
#endif

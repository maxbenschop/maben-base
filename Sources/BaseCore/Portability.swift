import CommonCrypto
import CryptoKit
import Foundation

/// Encrypts data with a passphrase: AES-GCM under a key from PBKDF2-SHA256 (210,000 rounds, random salt).
public enum SecretBox {
    public struct Sealed: Codable, Equatable, Sendable {
        public var salt: Data
        public var box: Data
    }

    static func key(_ passphrase: String, salt: Data) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(passphrase.utf8)
        pw.withUnsafeBufferPointer { p in
            salt.withUnsafeBytes { s in
                _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), UnsafeRawPointer(p.baseAddress!).assumingMemoryBound(to: CChar.self), p.count,
                                         s.bindMemory(to: UInt8.self).baseAddress, s.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                         210_000, &out, out.count)
            }
        }
        return SymmetricKey(data: out)
    }

    public static func seal(_ data: Data, passphrase: String) throws -> Sealed {
        let salt = Data(Crypto.randomBytes(16))
        let box = try AES.GCM.seal(data, using: key(passphrase, salt: salt))
        return Sealed(salt: salt, box: box.combined!)
    }

    public static func open(_ sealed: Sealed, passphrase: String) throws -> Data {
        guard let box = try? AES.GCM.SealedBox(combined: sealed.box), let plain = try? AES.GCM.open(box, using: key(passphrase, salt: sealed.salt)) else {
            throw DatabaseError("The passphrase is wrong.")
        }
        return plain
    }
}

/// Merging two copies of the connection list (this Mac and the iCloud Drive file).
public enum ConnectionMerge {
    /// The newer version of each connection wins; a deletion wins over versions older than it.
    public static func merge(local: [ConnectionConfig], remote: [ConnectionConfig], deleted: [UUID: Date]) -> [ConnectionConfig] {
        var byID: [UUID: ConnectionConfig] = [:]
        for c in local { byID[c.id] = c }
        for c in remote {
            if let mine = byID[c.id], mine.modified >= c.modified { continue }
            byID[c.id] = c
        }
        let kept = byID.values.filter { c in deleted[c.id].map { $0 < c.modified } ?? true }
        let order = local.map(\.id) + remote.map(\.id)
        return kept.sorted { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max, ib = order.firstIndex(of: b.id) ?? Int.max
            return ia != ib ? ia < ib : a.displayName < b.displayName
        }
    }
}

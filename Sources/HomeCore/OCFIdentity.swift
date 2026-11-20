import Foundation
import Security

/// The client certificate for the appliances' local DTLS interface.
///
/// Samsung appliances come with an access list that gives every right to one
/// identity, the SmartThings cloud service, named by a UUID in the
/// certificate's subject. Their TizenRT stack reads that UUID and doesn't
/// check who signed the certificate, so a self-signed one that carries it is
/// let in. (Found and published by the LocalThings and SmartThings-Local
/// projects; a firmware update could close it.) The key and the certificate
/// are made once and kept in the login keychain, where only this app can use
/// them.
public enum OCFIdentity {
  public static let serviceUUID = "ab0b0ac4-aae9-4958-a04d-8ec36fe1b2f9"
  static let label = "Domotica: Samsung appliance client"
  static let keyTag = Data("dev.balsamo.home-control.ocf-client".utf8)

  public enum Failure: LocalizedError {
    case certificate

    public var errorDescription: String? { "Non riesco a creare il certificato per gli elettrodomestici." }
  }

  /// The identity in the keychain, made on first use.
  public static func load() throws -> SecIdentity {
    if let certificate = storedCertificate(), let identity = identity(for: certificate) { return identity }
    return try create()
  }

  /// The certificate made for our key. The keychain labels certificates
  /// after their subject whatever label they're added with, so they're found
  /// through the key instead: by its tag, then by its public key hash, which
  /// the certificate shares.
  static func storedCertificate() -> SecCertificate? {
    let keyQuery: [String: Any] = [kSecClass as String: kSecClassKey,
                                   kSecAttrApplicationTag as String: keyTag,
                                   kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                                   kSecReturnAttributes as String: true]
    var key: CFTypeRef?
    guard SecItemCopyMatching(keyQuery as CFDictionary, &key) == errSecSuccess,
          let hash = (key as? [String: Any])?[kSecAttrApplicationLabel as String] as? Data else { return nil }
    let certificateQuery: [String: Any] = [kSecClass as String: kSecClassCertificate,
                                           kSecAttrPublicKeyHash as String: hash,
                                           kSecReturnRef as String: true]
    var result: CFTypeRef?
    guard SecItemCopyMatching(certificateQuery as CFDictionary, &result) == errSecSuccess, let result,
          CFGetTypeID(result) == SecCertificateGetTypeID() else { return nil }
    return (result as! SecCertificate)
  }

  static func identity(for certificate: SecCertificate) -> SecIdentity? {
    var identity: SecIdentity?
    return SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess ? identity : nil
  }

  static func create() throws -> SecIdentity {
    // What an earlier, interrupted attempt may have left: our key, and the
    // certificates labelled with the subject's CN.
    SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: keyTag] as CFDictionary)
    while SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: "urn:uuid:\(serviceUUID)"] as CFDictionary)
      == errSecSuccess {}
    var error: Unmanaged<CFError>?
    let attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits: 256,
      kSecAttrLabel: label,
      kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true, kSecAttrApplicationTag: keyTag, kSecAttrLabel: label],
    ]
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
      throw error?.takeRetainedValue() ?? Failure.certificate
    }
    guard let certificate = SecCertificateCreateWithData(nil, try selfSignedCertificate(key: key) as CFData)
    else { throw Failure.certificate }
    let status = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: certificate] as CFDictionary, nil)
    guard status == errSecSuccess || status == errSecDuplicateItem else { throw KeychainError(status: status) }
    guard let identity = identity(for: certificate) else { throw Failure.certificate }
    Log.info("made the Samsung appliance client certificate")
    return identity
  }

  /// X.509 v3, ECDSA P-256 with SHA-256, with the service UUID in OU, CN and
  /// the URI alternative names, as the appliances look for it. A P-256 key
  /// keeps the certificate small: TizenRT drops a certificate that DTLS
  /// splits over two datagrams.
  public static func selfSignedCertificate(key: SecKey, now: Date = Date()) throws -> Data {
    guard let publicKey = SecKeyCopyPublicKey(key),
          let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw Failure.certificate }
    let ecdsaWithSHA256 = DER.sequence(DER.oid("1.2.840.10045.4.3.2"))
    let name = DER.sequence(
      DER.set(DER.sequence(DER.oid("2.5.4.11") + DER.utf8("uuid:\(serviceUUID)")))
        + DER.set(DER.sequence(DER.oid("2.5.4.3") + DER.utf8("urn:uuid:\(serviceUUID)"))))
    let publicKeyInfo = DER.sequence(DER.sequence(DER.oid("1.2.840.10045.2.1") + DER.oid("1.2.840.10045.3.1.7"))
                                       + DER.bitString(point))
    let validity = DER.sequence(DER.utcTime(now.addingTimeInterval(-86_400))
                                  + DER.utcTime(now.addingTimeInterval(10 * 365 * 86_400)))
    let alternativeNames = ["urn:uuid:", "uri:uuid:", "uuid:"]
      .map { DER.tagged(0x86, Data(($0 + serviceUUID).utf8)) }
      .reduce(Data(), +)
    let extensions = DER.sequence(
      DER.extensionField("2.5.29.19", DER.sequence(Data()))  // basic constraints: not a CA
        + DER.extensionField("2.5.29.15", Data([0x03, 0x02, 0x07, 0x80]), critical: true)  // digitalSignature
        + DER.extensionField("2.5.29.37", DER.sequence(DER.oid("1.3.6.1.5.5.7.3.2") + DER.oid("1.3.6.1.5.5.7.3.1")))
        + DER.extensionField("2.5.29.17", DER.sequence(alternativeNames)))
    var serial = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    serial[0] = (serial[0] & 0x7F) | 0x01
    let tbs = DER.sequence(DER.tagged(0xA0, DER.integer(Data([2]))) + DER.integer(serial) + ecdsaWithSHA256
                             + name + validity + name + publicKeyInfo + DER.tagged(0xA3, extensions))
    var error: Unmanaged<CFError>?
    guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data?
    else { throw error?.takeRetainedValue() ?? Failure.certificate }
    return DER.sequence(tbs + ecdsaWithSHA256 + DER.bitString(signature))
  }
}

/// Just enough DER to write a certificate.
enum DER {
  static func tagged(_ tag: UInt8, _ content: Data) -> Data {
    Data([tag]) + length(content.count) + content
  }

  static func length(_ count: Int) -> Data {
    guard count >= 0x80 else { return Data([UInt8(count)]) }
    var bytes: [UInt8] = []
    var rest = count
    while rest > 0 {
      bytes.insert(UInt8(rest & 0xFF), at: 0)
      rest >>= 8
    }
    return Data([0x80 | UInt8(bytes.count)] + bytes)
  }

  static func sequence(_ content: Data) -> Data { tagged(0x30, content) }
  static func set(_ content: Data) -> Data { tagged(0x31, content) }
  static func utf8(_ text: String) -> Data { tagged(0x0C, Data(text.utf8)) }
  static func bitString(_ bytes: Data) -> Data { tagged(0x03, Data([0]) + bytes) }
  static func octetString(_ bytes: Data) -> Data { tagged(0x04, bytes) }
  static func boolean(_ value: Bool) -> Data { tagged(0x01, Data([value ? 0xFF : 0])) }

  static func integer(_ bytes: Data) -> Data {
    var value = bytes
    if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
    return tagged(0x02, value)
  }

  static func oid(_ dotted: String) -> Data {
    let arcs = dotted.split(separator: ".").compactMap { UInt64($0) }
    var out = Data([UInt8(arcs[0] * 40 + arcs[1])])
    for arc in arcs.dropFirst(2) {
      var chunk = [UInt8(arc & 0x7F)]
      var rest = arc >> 7
      while rest > 0 {
        chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
        rest >>= 7
      }
      out += chunk
    }
    return tagged(0x06, out)
  }

  static func utcTime(_ date: Date) -> Data {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyMMddHHmmss'Z'"
    return tagged(0x17, Data(formatter.string(from: date).utf8))
  }

  static func extensionField(_ oid: String, _ value: Data, critical: Bool = false) -> Data {
    sequence(self.oid(oid) + (critical ? boolean(true) : Data()) + octetString(value))
  }
}

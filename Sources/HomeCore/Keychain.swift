import Foundation
import Security

/// Generic passwords in the login keychain. macOS lets only the app that
/// created an item read it without asking, so the app must keep a stable
/// signature (run.sh signs with the Apple Development identity).
public struct Keychain: Sendable {
  public let service: String

  public init(service: String) { self.service = service }

  public func read<T: Decodable>(_ type: T.Type, account: String) -> T? {
    guard let data = data(account: account) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  public func write<T: Encodable>(_ value: T, account: String) throws {
    try set(try JSONEncoder().encode(value), account: account)
  }

  public func data(account: String) -> Data? {
    var query = baseQuery(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }

  public func set(_ data: Data, account: String) throws {
    let status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = baseQuery(account)
      item[kSecValueData as String] = data
      item[kSecAttrLabel as String] = "Domotica (\(account))"
      let added = SecItemAdd(item as CFDictionary, nil)
      guard added == errSecSuccess else { throw KeychainError(status: added) }
    } else if status != errSecSuccess {
      throw KeychainError(status: status)
    }
  }

  public func remove(account: String) {
    SecItemDelete(baseQuery(account) as CFDictionary)
  }

  private func baseQuery(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account]
  }
}

public struct KeychainError: LocalizedError {
  public let status: OSStatus

  public var errorDescription: String? {
    (SecCopyErrorMessageString(status, nil) as String?) ?? "Errore del portachiavi (\(status))."
  }
}

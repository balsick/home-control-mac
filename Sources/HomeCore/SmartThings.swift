import Foundation

/// A device from `GET /v1/devices`.
public struct STDevice: Decodable, Sendable, Identifiable, Equatable {
  public struct Component: Decodable, Sendable, Equatable {
    public let id: String
    public let capabilities: [Capability]
  }

  public struct Capability: Decodable, Sendable, Equatable {
    public let id: String
  }

  public struct OCF: Decodable, Sendable, Equatable {
    public let ocfDeviceType: String?
    public let manufacturerName: String?
    public let modelNumber: String?
  }

  public let deviceId: String
  public let name: String?
  public let label: String?
  public let manufacturerName: String?
  public let components: [Component]?
  public let ocf: OCF?

  public var id: String { deviceId }
  public var displayName: String { label ?? name ?? deviceId }

  public var capabilityIds: Set<String> {
    Set((components ?? []).flatMap { $0.capabilities.map(\.id) })
  }

  /// Washers and dryers; nil for every other device.
  public var applianceKind: ApplianceKind? {
    switch ocf?.ocfDeviceType {
    case "oic.d.washer": return .washer
    case "oic.d.dryer": return .dryer
    default: break
    }
    let capabilities = capabilityIds
    if capabilities.contains("samsungce.washerOperatingState") || capabilities.contains("washerOperatingState") {
      return .washer
    }
    if capabilities.contains("samsungce.dryerOperatingState") || capabilities.contains("dryerOperatingState") {
      return .dryer
    }
    return nil
  }
}

public enum SmartThingsError: LocalizedError, Equatable {
  case notConfigured
  case http(Int, String?)
  /// A personal token that SmartThings no longer accepts: they last 24 hours.
  case tokenRejected
  /// The OAuth refresh token was refused: the user must authorize again.
  case reauthorizationNeeded
  case badCode

  public var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "SmartThings non è collegato."
    case .http(let code, let message):
      return "SmartThings ha risposto \(code)" + (message.map { ": \($0)" } ?? ".")
    case .tokenRejected:
      return "Il token SmartThings è scaduto (dura 24 ore): creane uno nuovo."
    case .reauthorizationNeeded:
      return "L'autorizzazione SmartThings è scaduta: autorizza di nuovo Domotica nelle impostazioni."
    case .badCode:
      return "Non trovo il codice di autorizzazione in quello che hai incollato."
    }
  }
}

/// The SmartThings REST API, for the devices of the connected account.
public struct SmartThingsClient: Sendable {
  public static let api = URL(string: "https://api.smartthings.com/v1/")!

  public let auth: SmartThingsAuth

  public init(auth: SmartThingsAuth) { self.auth = auth }

  public func devices() async throws -> [STDevice] {
    struct Page: Decodable {
      struct Links: Decodable { let next: Link? }
      struct Link: Decodable { let href: String }
      let items: [STDevice]
      let links: Links?
      enum CodingKeys: String, CodingKey {
        case items
        case links = "_links"
      }
    }
    var next: URL? = Self.api.appending(path: "devices")
    var devices: [STDevice] = []
    while let url = next {
      let page = try JSONDecoder().decode(Page.self, from: try await get(url))
      devices += page.items
      next = page.links?.next.flatMap { URL(string: $0.href) }
    }
    return devices
  }

  /// The device's whole status, decoded, and the raw JSON for diagnostics.
  public func status(of deviceId: String) async throws -> (JSONValue, Data) {
    let data = try await get(Self.api.appending(path: "devices/\(deviceId)/status"))
    return (try JSONDecoder().decode(JSONValue.self, from: data), data)
  }

  func get(_ url: URL) async throws -> Data {
    var token = try await auth.accessToken()
    for attempt in 0..<2 {
      var request = URLRequest(url: url)
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      let (data, response) = try await URLSession.shared.data(for: request)
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      if code == 401, attempt == 0 {
        token = try await auth.tokenAfterUnauthorized(token)
        continue
      }
      guard (200..<300).contains(code) else { throw SmartThingsError.http(code, Self.message(in: data)) }
      return data
    }
    throw SmartThingsError.reauthorizationNeeded
  }

  /// The error text of an API or OAuth error body.
  static func message(in data: Data) -> String? {
    guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      let text = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : text
    }
    if let message = json["error"]?["message"]?.string { return message }
    if let error = json["error"]?.string {
      return [error, json["error_description"]?.string].compactMap { $0 }.joined(separator: ": ")
    }
    return json["message"]?.string
  }
}

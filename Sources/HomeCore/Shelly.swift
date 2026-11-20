import Foundation
import Network

/// `GET /shelly`, answered by every Shelly. Gen1 devices answer with another
/// shape (no `id`), so they fail to decode and are skipped.
public struct ShellyInfo: Decodable, Sendable, Equatable {
  public let id: String
  public let name: String?
  public let mac: String
  public let model: String?
  public let generation: Int?
  public let app: String?
  public let version: String?
  public let profile: String?
  public let authEnabled: Bool?

  enum CodingKeys: String, CodingKey {
    case id, name, mac, model, app, profile
    case generation = "gen"
    case version = "ver"
    case authEnabled = "auth_en"
  }
}

/// One `light:N` component: a dimmable white channel. The Plus RGBW PM in
/// the "light" profile has four of them.
public struct ShellyLight: Sendable, Equatable {
  public let id: Int
  public var isOn: Bool
  /// 0–100. Kept while the channel is off: it's the level it comes back at.
  public var brightness: Int
  public var power: Double?
  public var voltage: Double?
  public var temperature: Double?
}

/// `Shelly.GetStatus`, reduced to the lights and the firmware update offer.
public struct ShellyStatus: Decodable, Sendable {
  public var lights: [ShellyLight]
  public var availableUpdate: String?

  private struct LightDTO: Decodable {
    struct Temperature: Decodable { let tC: Double? }
    let id: Int
    let output: Bool
    let brightness: Double?
    let apower: Double?
    let voltage: Double?
    let temperature: Temperature?
  }

  private struct SysDTO: Decodable {
    struct Updates: Decodable { let stable: Version? }
    struct Version: Decodable { let version: String }
    let availableUpdates: Updates?
    enum CodingKeys: String, CodingKey { case availableUpdates = "available_updates" }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: AnyKey.self)
    var lights: [ShellyLight] = []
    for key in container.allKeys where key.stringValue.hasPrefix("light:") {
      let dto = try container.decode(LightDTO.self, forKey: key)
      lights.append(ShellyLight(id: dto.id, isOn: dto.output, brightness: Int((dto.brightness ?? 0).rounded()),
                                power: dto.apower, voltage: dto.voltage, temperature: dto.temperature?.tC))
    }
    self.lights = lights.sorted { $0.id < $1.id }
    availableUpdate = try? container.decodeIfPresent(SysDTO.self, forKey: AnyKey("sys"))?.availableUpdates?.stable?.version
  }
}

/// `Shelly.GetConfig`, reduced to the names the user gave in the Shelly app.
public struct ShellyConfig: Decodable, Sendable {
  public var deviceName: String?
  public var lightNames: [Int: String]

  private struct NamedDTO: Decodable {
    let id: Int
    let name: String?
  }

  private struct SysDTO: Decodable {
    struct Device: Decodable { let name: String? }
    let device: Device?
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: AnyKey.self)
    var names: [Int: String] = [:]
    for key in container.allKeys where key.stringValue.hasPrefix("light:") {
      let dto = try container.decode(NamedDTO.self, forKey: key)
      if let name = dto.name, !name.isEmpty { names[dto.id] = name }
    }
    lightNames = names
    deviceName = try? container.decodeIfPresent(SysDTO.self, forKey: AnyKey("sys"))?.device?.name
  }
}

struct AnyKey: CodingKey {
  let stringValue: String
  init(_ string: String) { stringValue = string }
  init?(stringValue: String) { self.stringValue = stringValue }
  var intValue: Int? { nil }
  init?(intValue: Int) { return nil }
}

public enum ShellyError: LocalizedError {
  case http(Int, String?)
  case rpc(Int, String)

  public var errorDescription: String? {
    switch self {
    case .http(401, _): return "Lo Shelly è protetto da password: Domotica non la gestisce ancora."
    case .http(let code, let message): return "Lo Shelly ha risposto \(code)" + (message.map { " (\($0))" } ?? "") + "."
    case .rpc(_, let message): return "Lo Shelly ha rifiutato il comando (\(message))."
    }
  }
}

/// The Gen2+ RPC API over plain HTTP on the local network.
public struct ShellyClient: Sendable {
  public let host: String

  public init(host: String) { self.host = host }

  static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 4
    configuration.timeoutIntervalForResource = 8
    // The ESP32 serves few connections at a time.
    configuration.httpMaximumConnectionsPerHost = 2
    return URLSession(configuration: configuration)
  }()

  public func info() async throws -> ShellyInfo { try await get("shelly") }
  public func status() async throws -> ShellyStatus { try await get("rpc/Shelly.GetStatus") }
  public func config() async throws -> ShellyConfig { try await get("rpc/Shelly.GetConfig") }

  /// `Light.Set`. A nil argument leaves that property alone; a nil
  /// `transition` (seconds) uses the fade configured on the device.
  public func setLight(id: Int, on: Bool? = nil, brightness: Int? = nil, transition: Double? = nil) async throws {
    var params: [String: Any] = ["id": id]
    if let on { params["on"] = on }
    if let brightness { params["brightness"] = min(max(brightness, 0), 100) }
    if let transition { params["transition_duration"] = transition }
    try await rpc("Light.Set", params)
  }

  func get<T: Decodable>(_ path: String) async throws -> T {
    let (data, response) = try await Self.session.data(from: url(path))
    try check(response, data)
    return try JSONDecoder().decode(T.self, from: data)
  }

  func rpc(_ method: String, _ params: [String: Any]) async throws {
    var request = URLRequest(url: url("rpc"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
    let (data, response) = try await Self.session.data(for: request)
    try check(response, data)
    if let reply = try? JSONDecoder().decode(RPCReply.self, from: data), let error = reply.error {
      throw ShellyError.rpc(error.code, error.message)
    }
  }

  private func url(_ path: String) -> URL { URL(string: "http://\(host)/\(path)")! }

  private func check(_ response: URLResponse, _ data: Data) throws {
    guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
    throw ShellyError.http(http.statusCode, (try? JSONDecoder().decode(RPCReply.Failure.self, from: data))?.message)
  }

  private struct RPCReply: Decodable {
    struct Failure: Decodable {
      let code: Int
      let message: String
    }
    let error: Failure?
  }
}

/// Finds Gen2+ Shelly devices through Bonjour (`_shelly._tcp`).
public enum ShellyDiscovery {
  /// The IPv4 address of every device that answers within `timeout`.
  public static func discover(timeout: TimeInterval = 6) async -> [String] {
    let endpoints = await browse(timeout: timeout)
    return await withTaskGroup(of: String?.self) { group in
      for endpoint in endpoints { group.addTask { await resolveIPv4(endpoint) } }
      var hosts = Set<String>()
      for await host in group { if let host { hosts.insert(host) } }
      return hosts.sorted()
    }
  }

  /// Collects services until `timeout`, or until `settle` seconds after the
  /// first one shows up: the first answer can take a few seconds, the rest
  /// follow quickly.
  static func browse(timeout: TimeInterval, settle: TimeInterval = 1.5) async -> [NWEndpoint] {
    await withCheckedContinuation { continuation in
      let queue = DispatchQueue(label: "shelly-browse")
      let browser = NWBrowser(for: .bonjour(type: "_shelly._tcp", domain: "local."), using: .tcp)
      let endpoints = Locked<[NWEndpoint]>([])
      let once = Once()
      let finish: @Sendable () -> Void = {
        guard once.claim() else { return }
        browser.cancel()
        continuation.resume(returning: endpoints.get())
      }
      browser.stateUpdateHandler = { state in
        switch state {
        case .failed(let error), .waiting(let error): Log.info("Bonjour browse: \(error)")
        default: break
        }
      }
      browser.browseResultsChangedHandler = { results, _ in
        let first = endpoints.get().isEmpty && !results.isEmpty
        endpoints.set(results.map(\.endpoint))
        if first { queue.asyncAfter(deadline: .now() + settle, execute: finish) }
      }
      browser.start(queue: queue)
      queue.asyncAfter(deadline: .now() + timeout, execute: finish)
    }
  }

  /// Connects to the service once, over IPv4, to learn its address.
  static func resolveIPv4(_ endpoint: NWEndpoint, timeout: TimeInterval = 3) async -> String? {
    let parameters = NWParameters.tcp
    if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
    let connection = NWConnection(to: endpoint, using: parameters)
    defer { connection.cancel() }
    do {
      try await connection.open(timeout: timeout)
    } catch {
      Log.info("Bonjour resolve \(endpoint): \(error)")
      return nil
    }
    guard case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint, case .ipv4(let address) = host
    else { return nil }
    return address.rawValue.map(String.init).joined(separator: ".")
  }
}

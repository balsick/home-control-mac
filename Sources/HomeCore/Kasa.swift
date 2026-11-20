import Darwin
import Foundation
import Network

/// The TP-Link Kasa legacy protocol (HS100, HS110 and the other plugs from
/// before 2020): JSON scrambled with an XOR autokey cipher, sent over TCP 9999
/// with a 4-byte length in front, or over UDP 9999 without it for discovery.
/// Newer Kasa devices speak KLAP instead, which needs the TP-Link account.
public enum KasaCodec {
  static let initialKey: UInt8 = 171

  public static func encrypt(_ plain: Data) -> Data {
    var key = initialKey
    var out = Data(capacity: plain.count)
    for byte in plain {
      key ^= byte
      out.append(key)
    }
    return out
  }

  public static func decrypt(_ cipher: Data) -> Data {
    var key = initialKey
    var out = Data(capacity: cipher.count)
    for byte in cipher {
      out.append(key ^ byte)
      key = byte
    }
    return out
  }

  /// A TCP message: the payload length as a big-endian UInt32, then the payload.
  public static func frame(_ plain: Data) -> Data {
    let payload = encrypt(plain)
    let n = UInt32(payload.count)
    var out = Data([UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
    out.append(payload)
    return out
  }
}

/// The part of `system.get_sysinfo` the app uses, for plugs with one relay.
public struct KasaSysInfo: Decodable, Sendable, Equatable {
  /// The next scheduled change. `secondsOfDay` counts from local midnight and
  /// does not say which day; `type` is -1 when nothing is scheduled.
  public struct NextAction: Decodable, Sendable, Equatable {
    public let type: Int
    public let secondsOfDay: Int?
    public let action: Int?

    enum CodingKeys: String, CodingKey {
      case type, action
      case secondsOfDay = "schd_sec"
    }
  }

  public let alias: String
  public let model: String
  public let mac: String
  public let deviceId: String
  public let relayState: Int
  public let onTime: Int?
  public let rssi: Int?
  public let activeMode: String?
  public let nextAction: NextAction?
  public let softwareVersion: String?

  public var isOn: Bool { relayState == 1 }

  enum CodingKeys: String, CodingKey {
    case alias, model, mac, deviceId, rssi
    case relayState = "relay_state"
    case onTime = "on_time"
    case activeMode = "active_mode"
    case nextAction = "next_action"
    case softwareVersion = "sw_ver"
  }

  /// Decodes `{"system":{"get_sysinfo":{...}}}`.
  static func fromReply(_ data: Data) throws -> KasaSysInfo {
    struct Reply: Decodable {
      struct System: Decodable {
        let info: KasaSysInfo
        enum CodingKeys: String, CodingKey { case info = "get_sysinfo" }
      }
      let system: System
    }
    return try JSONDecoder().decode(Reply.self, from: data).system.info
  }
}

public enum KasaError: LocalizedError {
  case device(String)

  public var errorDescription: String? {
    switch self {
    case .device(let message): return "La presa ha rifiutato il comando (\(message))."
    }
  }
}

public struct KasaClient: Sendable {
  public let host: String

  public init(host: String) { self.host = host }

  public func sysInfo() async throws -> KasaSysInfo {
    try KasaSysInfo.fromReply(try await call(#"{"system":{"get_sysinfo":{}}}"#))
  }

  public func setRelay(on: Bool) async throws {
    struct Reply: Decodable {
      struct System: Decodable {
        let outcome: Outcome
        enum CodingKeys: String, CodingKey { case outcome = "set_relay_state" }
      }
      struct Outcome: Decodable {
        let code: Int
        let message: String?
        enum CodingKeys: String, CodingKey {
          case code = "err_code"
          case message = "err_msg"
        }
      }
      let system: System
    }
    let data = try await call(#"{"system":{"set_relay_state":{"state":\#(on ? 1 : 0)}}}"#)
    let outcome = try JSONDecoder().decode(Reply.self, from: data).system.outcome
    guard outcome.code == 0 else { throw KasaError.device(outcome.message ?? "codice \(outcome.code)") }
  }

  /// One request per connection: the plug closes it after answering.
  func call(_ json: String, timeout: TimeInterval = 4) async throws -> Data {
    let connection = NWConnection(host: NWEndpoint.Host(host), port: 9999, using: .tcp)
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
      connection.cancel()
    }
    defer {
      watchdog.cancel()
      connection.cancel()
    }
    try await connection.open(timeout: timeout)
    try await connection.sendAll(KasaCodec.frame(Data(json.utf8)))
    let header = try await connection.receive(exactly: 4)
    let length = header.reduce(0) { ($0 << 8) | Int($1) }
    guard (1...1_000_000).contains(length) else { throw NetError.badReply }
    return KasaCodec.decrypt(try await connection.receive(exactly: length))
  }
}

/// Finds legacy Kasa devices by broadcasting `get_sysinfo` on UDP 9999.
public enum KasaDiscovery {
  public struct Found: Sendable, Equatable {
    public let host: String
    public let info: KasaSysInfo
  }

  public static func discover(timeout: TimeInterval = 2.5) async -> [Found] {
    await Task.detached(priority: .utility) { run(timeout: timeout) }.value
  }

  static func run(timeout: TimeInterval) -> [Found] {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return [] }
    defer { close(fd) }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
    var wait = timeval(tv_sec: 0, tv_usec: 250_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

    let query = [UInt8](KasaCodec.encrypt(Data(#"{"system":{"get_sysinfo":{}}}"#.utf8)))
    for address in broadcastAddresses() {
      var target = sockaddr_in()
      target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      target.sin_family = sa_family_t(AF_INET)
      target.sin_port = UInt16(9999).bigEndian
      target.sin_addr = address
      for _ in 0..<2 {
        _ = withUnsafePointer(to: &target) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(fd, query, query.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
          }
        }
      }
    }

    var found: [String: KasaSysInfo] = [:]
    var buffer = [UInt8](repeating: 0, count: 8192)
    let capacity = buffer.count
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      var sender = sockaddr_in()
      var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
      let count = withUnsafeMutablePointer(to: &sender) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          recvfrom(fd, &buffer, capacity, 0, $0, &senderLength)
        }
      }
      guard count > 0 else { continue }
      let plain = KasaCodec.decrypt(Data(buffer[0..<count]))
      // Bulbs and strips answer too, with another shape: they don't decode.
      guard let info = try? KasaSysInfo.fromReply(plain) else { continue }
      found[ipString(sender.sin_addr)] = info
    }
    return found.map { Found(host: $0.key, info: $0.value) }.sorted { $0.host < $1.host }
  }

  /// The broadcast address of every IPv4 interface that is up.
  static func broadcastAddresses() -> [in_addr] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [in_addr(s_addr: 0xFFFF_FFFF)] }
    defer { freeifaddrs(list) }
    var result: [in_addr] = []
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let flags = Int32(entry.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
            let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
            let broadcast = entry.pointee.ifa_dstaddr
      else { continue }
      result.append(broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr })
    }
    return result.isEmpty ? [in_addr(s_addr: 0xFFFF_FFFF)] : result
  }

  static func ipString(_ address: in_addr) -> String {
    var address = address
    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN))
    return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}

import Darwin
import Foundation

/// What an OCF device says about itself in `/oic/d`, readable by anyone on
/// the LAN over plain CoAP.
public struct OCFDeviceInfo: Sendable, Equatable, Codable {
  public var host: String
  public let deviceID: String
  public let types: [String]
  public let name: String?
  public let model: String?

  public var applianceKind: ApplianceKind? {
    if types.contains("oic.d.washer") { return .washer }
    if types.contains("oic.d.dryer") { return .dryer }
    return nil
  }

  public init?(host: String, json: JSONValue) {
    guard let deviceID = json["di"]?.string else { return nil }
    self.host = host
    self.deviceID = deviceID
    types = json["rt"]?.array?.compactMap(\.string) ?? []
    name = json["n"]?.string
    model = json["mnmc"]?.string
  }
}

/// Finds Samsung appliances by asking every host of the LAN for `/oic/d`
/// over plain CoAP (UDP 5683): they don't answer multicast discovery here.
public enum OCFDiscovery {
  public static func probe(_ hosts: [String], timeout: TimeInterval = 3) async -> [OCFDeviceInfo] {
    await Task.detached(priority: .utility) {
      var found: [String: OCFDeviceInfo] = [:]
      PlainCoAP.exchange(hosts.map { ($0, CoAPMessage.get("/oic/d", messageID: 1, token: CoAPMessage.newToken())) },
                         timeout: timeout) { host, reply in
        guard reply.isSuccess, let json = try? CBOR.decode(reply.payload),
              let info = OCFDeviceInfo(host: host, json: json) else { return }
        found[info.deviceID] = info
      }
      return found.values.sorted { $0.host < $1.host }
    }.value
  }

  /// The port of the appliance's DTLS endpoint, from the security resource
  /// it advertises in a filtered discovery (one small block).
  public static func securePort(of host: String, timeout: TimeInterval = 3) async -> UInt16? {
    await Task.detached(priority: .utility) {
      var port: UInt16?
      let request = CoAPMessage.get("/oic/res", query: ["rt=oic.r.doxm"], messageID: 1, token: CoAPMessage.newToken())
      PlainCoAP.exchange([(host, request)], timeout: timeout) { _, reply in
        guard reply.isSuccess, let json = try? CBOR.decode(reply.payload) else { return }
        let devices = json.array ?? [json]
        for link in devices.flatMap({ $0["links"]?.array ?? [] }) {
          if link["p"]?["sec"]?.bool == true, let value = link["p"]?["port"]?.number, value > 0 {
            port = UInt16(value)
          }
        }
      }
      return port
    }.value
  }

  /// Every host of this Mac's IPv4 subnets, up to a /22 each, but this Mac.
  public static func subnetHosts() -> [String] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(list) }
    var hosts: [String] = []
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let flags = Int32(entry.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
            let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
            let netmask = entry.pointee.ifa_netmask else { continue }
      let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
      let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
      guard mask >= 0xFFFF_FC00 else { continue }  // larger than a /22: not a home LAN
      let network = ip & mask
      let broadcast = network | ~mask
      guard broadcast > network + 1 else { continue }
      for candidate in (network + 1)..<broadcast where candidate != ip {
        hosts.append([24, 16, 8, 0].map { String((candidate >> $0) & 0xFF) }.joined(separator: "."))
      }
    }
    return hosts
  }
}

/// Unencrypted CoAP over a BSD UDP socket, for discovery: many requests out
/// at once, answers collected until `timeout`.
enum PlainCoAP {
  static func exchange(_ requests: [(host: String, message: CoAPMessage)], port: UInt16 = 5683,
                       timeout: TimeInterval, onReply: (String, CoAPMessage) -> Void) {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var wait = timeval(tv_sec: 0, tv_usec: 200_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

    func address(_ host: String) -> sockaddr_in? {
      var target = sockaddr_in()
      target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      target.sin_family = sa_family_t(AF_INET)
      target.sin_port = port.bigEndian
      return inet_pton(AF_INET, host, &target.sin_addr) == 1 ? target : nil
    }
    func send(_ data: Data, to target: sockaddr_in) {
      var target = target
      let bytes = [UInt8](data)
      _ = withUnsafePointer(to: &target) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }

    var tokens: [Data: String] = [:]
    for (host, message) in requests {
      guard let target = address(host) else { continue }
      tokens[message.token] = host
      send(message.encoded(), to: target)
    }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let capacity = buffer.count
    var answered = Set<Data>()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline, answered.count < tokens.count {
      var sender = sockaddr_in()
      var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
      let count = withUnsafeMutablePointer(to: &sender) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          recvfrom(fd, &buffer, capacity, 0, $0, &senderLength)
        }
      }
      guard count > 0, let reply = CoAPMessage.decode(Data(buffer[0..<count])) else { continue }
      // A confirmable response wants an ACK, or the appliance repeats it.
      if reply.kind == .confirmable { send(CoAPMessage.emptyAck(reply.messageID).encoded(), to: sender) }
      guard !reply.isEmpty, let host = tokens[reply.token], !answered.contains(reply.token) else { continue }
      answered.insert(reply.token)
      onReply(host, reply)
    }
  }
}

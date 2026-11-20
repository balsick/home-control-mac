import Foundation

/// A CoAP option (RFC 7252 §5.4).
public struct CoAPOption: Equatable, Sendable {
  public let number: Int
  public let value: Data

  public init(_ number: Int, _ value: Data) {
    self.number = number
    self.value = value
  }

  /// An unsigned integer in the fewest bytes (zero is empty).
  public init(_ number: Int, uint: UInt32) {
    var bytes: [UInt8] = []
    var rest = uint
    while rest > 0 {
      bytes.insert(UInt8(rest & 0xFF), at: 0)
      rest >>= 8
    }
    self.init(number, Data(bytes))
  }

  public init(_ number: Int, string: String) {
    self.init(number, Data(string.utf8))
  }

  public var uint: UInt32 { value.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
}

/// A CoAP message (RFC 7252), with the options Samsung's OCF appliances use:
/// Observe (RFC 7641) and Block2 (RFC 7959).
public struct CoAPMessage: Equatable, Sendable {
  public enum Kind: UInt8, Sendable {
    case confirmable = 0, nonConfirmable = 1, acknowledgement = 2, reset = 3
  }

  public enum OptionNumber {
    public static let observe = 6
    public static let uriPath = 11
    public static let contentFormat = 12
    public static let uriQuery = 15
    public static let block2 = 23
  }

  public var kind: Kind
  /// Class in the top 3 bits, detail in the low 5: 0x01 is GET, 0x45 is 2.05.
  public var code: UInt8
  public var messageID: UInt16
  public var token: Data
  public var options: [CoAPOption]
  public var payload: Data

  public init(kind: Kind, code: UInt8, messageID: UInt16, token: Data = Data(), options: [CoAPOption] = [],
              payload: Data = Data()) {
    self.kind = kind
    self.code = code
    self.messageID = messageID
    self.token = token
    self.options = options
    self.payload = payload
  }

  /// A confirmable GET. `block2` asks for that block of a 1024-byte-block
  /// transfer; `observe` 0 registers for notifications, 1 deregisters.
  public static func get(_ path: String, query: [String] = [], messageID: UInt16, token: Data,
                         observe: UInt32? = nil, block2: Int? = nil) -> CoAPMessage {
    // In option-number order, as they go on the wire.
    var options = observe.map { [CoAPOption(OptionNumber.observe, uint: $0)] } ?? []
    options += path.split(separator: "/").map { CoAPOption(OptionNumber.uriPath, string: String($0)) }
    options += query.map { CoAPOption(OptionNumber.uriQuery, string: $0) }
    if let block2 { options.append(CoAPOption(OptionNumber.block2, uint: UInt32(block2 << 4 | 6))) }
    return CoAPMessage(kind: .confirmable, code: 0x01, messageID: messageID, token: token, options: options)
  }

  public static func emptyAck(_ messageID: UInt16) -> CoAPMessage {
    CoAPMessage(kind: .acknowledgement, code: 0, messageID: messageID)
  }

  public var isEmpty: Bool { code == 0 }
  public var isSuccess: Bool { code >> 5 == 2 }
  public var codeDescription: String { "\(code >> 5).\(String(format: "%02d", code & 0x1F))" }

  public func values(_ number: Int) -> [Data] { options.filter { $0.number == number }.map(\.value) }
  public var observe: UInt32? { values(OptionNumber.observe).first.map { CoAPOption(0, $0).uint } }

  /// The Block2 option of a response: its number, and whether more follow.
  public var block2: (number: Int, more: Bool)? {
    guard let raw = values(OptionNumber.block2).first else { return nil }
    let value = CoAPOption(0, raw).uint
    return (Int(value >> 4), value & 0x08 != 0)
  }

  public func encoded() -> Data {
    var out = Data([0x40 | (kind.rawValue << 4) | UInt8(min(token.count, 8)), code,
                    UInt8(messageID >> 8), UInt8(messageID & 0xFF)])
    out += token.prefix(8)
    // Options go in number order; repeated ones (the path) keep their order.
    let ordered = options.enumerated().sorted { ($0.element.number, $0.offset) < ($1.element.number, $1.offset) }
    var last = 0
    for option in ordered.map(\.element) {
      let (delta, deltaExtra) = Self.nibble(option.number - last)
      let (length, lengthExtra) = Self.nibble(option.value.count)
      out.append(delta << 4 | length)
      out += deltaExtra + lengthExtra + option.value
      last = option.number
    }
    if !payload.isEmpty {
      out.append(0xFF)
      out += payload
    }
    return out
  }

  private static func nibble(_ value: Int) -> (UInt8, Data) {
    switch value {
    case ..<13: return (UInt8(value), Data())
    case ..<269: return (13, Data([UInt8(value - 13)]))
    default: return (14, Data([UInt8((value - 269) >> 8), UInt8((value - 269) & 0xFF)]))
    }
  }

  public static func decode(_ data: Data) -> CoAPMessage? {
    let bytes = [UInt8](data)
    guard bytes.count >= 4, bytes[0] >> 6 == 1, let kind = Kind(rawValue: (bytes[0] >> 4) & 0x03) else { return nil }
    let tokenLength = Int(bytes[0] & 0x0F)
    guard tokenLength <= 8, bytes.count >= 4 + tokenLength else { return nil }
    var index = 4 + tokenLength
    var options: [CoAPOption] = []
    var number = 0
    func extended(_ nibble: Int) -> Int? {
      switch nibble {
      case 13:
        guard index < bytes.count else { return nil }
        index += 1
        return Int(bytes[index - 1]) + 13
      case 14:
        guard index + 1 < bytes.count else { return nil }
        index += 2
        return (Int(bytes[index - 2]) << 8 | Int(bytes[index - 1])) + 269
      case 15:
        return nil
      default:
        return nibble
      }
    }
    while index < bytes.count, bytes[index] != 0xFF {
      let head = bytes[index]
      index += 1
      guard let delta = extended(Int(head >> 4)), let length = extended(Int(head & 0x0F)),
            index + length <= bytes.count else { return nil }
      number += delta
      options.append(CoAPOption(number, Data(bytes[index..<index + length])))
      index += length
    }
    let payload = index < bytes.count ? Data(bytes[(index + 1)...]) : Data()
    return CoAPMessage(kind: kind, code: bytes[1], messageID: UInt16(bytes[2]) << 8 | UInt16(bytes[3]),
                       token: Data(bytes[4..<4 + tokenLength]), options: options, payload: payload)
  }

  public static func newToken() -> Data { Data((0..<4).map { _ in UInt8.random(in: 0...255) }) }
}

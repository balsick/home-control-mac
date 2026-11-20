import Foundation

/// A CBOR decoder (RFC 8949) for OCF payloads, into `JSONValue`. Map keys
/// become strings, byte strings become hex, tags are dropped.
public enum CBOR {
  public enum DecodeError: Error, Equatable {
    case truncated
    case unsupported(UInt8)
  }

  public static func decode(_ data: Data) throws -> JSONValue {
    var reader = Reader(bytes: [UInt8](data))
    return try reader.value()
  }

  private struct Reader {
    let bytes: [UInt8]
    var index = 0

    mutating func byte() throws -> UInt8 {
      guard index < bytes.count else { throw DecodeError.truncated }
      defer { index += 1 }
      return bytes[index]
    }

    func peek() throws -> UInt8 {
      guard index < bytes.count else { throw DecodeError.truncated }
      return bytes[index]
    }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
      guard count >= 0, index + count <= bytes.count else { throw DecodeError.truncated }
      defer { index += count }
      return bytes[index..<index + count]
    }

    /// The argument of an initial byte; nil means indefinite length.
    mutating func argument(_ info: UInt8) throws -> UInt64? {
      switch info {
      case 0..<24: return UInt64(info)
      case 24: return UInt64(try byte())
      case 25: return try take(2).reduce(0) { $0 << 8 | UInt64($1) }
      case 26: return try take(4).reduce(0) { $0 << 8 | UInt64($1) }
      case 27: return try take(8).reduce(0) { $0 << 8 | UInt64($1) }
      case 31: return nil
      default: throw DecodeError.unsupported(info)
      }
    }

    mutating func length(_ info: UInt8) throws -> Int? {
      guard let n = try argument(info) else { return nil }
      guard n <= UInt64(bytes.count) else { throw DecodeError.truncated }
      return Int(n)
    }

    mutating func value() throws -> JSONValue {
      let initial = try byte()
      let major = initial >> 5
      let info = initial & 0x1F
      switch major {
      case 0:
        return .number(Double(try argument(info) ?? 0))
      case 1:
        return .number(-1 - Double(try argument(info) ?? 0))
      case 2, 3:
        var raw: [UInt8] = []
        if let n = try length(info) {
          raw = Array(try take(n))
        } else {
          // Indefinite: definite chunks of the same type until a break.
          while try peek() != 0xFF {
            let chunk = try byte()
            guard chunk >> 5 == major, let n = try length(chunk & 0x1F) else { throw DecodeError.unsupported(chunk) }
            raw += try take(n)
          }
          index += 1
        }
        return major == 3 ? .string(String(decoding: raw, as: UTF8.self))
                          : .string(raw.map { String(format: "%02x", $0) }.joined())
      case 4:
        var items: [JSONValue] = []
        if let n = try length(info) {
          for _ in 0..<n { items.append(try value()) }
        } else {
          while try peek() != 0xFF { items.append(try value()) }
          index += 1
        }
        return .array(items)
      case 5:
        var object: [String: JSONValue] = [:]
        if let n = try length(info) {
          for _ in 0..<n { try pair(into: &object) }
        } else {
          while try peek() != 0xFF { try pair(into: &object) }
          index += 1
        }
        return .object(object)
      case 6:
        _ = try argument(info)
        return try value()
      default:
        return try simple(info)
      }
    }

    mutating func pair(into object: inout [String: JSONValue]) throws {
      let key = try value()
      let name: String
      switch key {
      case .string(let s): name = s
      case .number(let n): name = n.rounded() == n ? String(Int(n)) : String(n)
      default: name = "\(key)"
      }
      object[name] = try value()
    }

    mutating func simple(_ info: UInt8) throws -> JSONValue {
      switch info {
      case 20: return .bool(false)
      case 21: return .bool(true)
      case 22, 23: return .null
      case 25:
        let bits = try take(2).reduce(0) { $0 << 8 | UInt16($1) }
        return .number(Double(halfFloat(bits)))
      case 26:
        let bits = try take(4).reduce(0) { $0 << 8 | UInt32($1) }
        return .number(Double(Float(bitPattern: bits)))
      case 27:
        let bits = try take(8).reduce(0) { $0 << 8 | UInt64($1) }
        return .number(Double(bitPattern: bits))
      default:
        throw DecodeError.unsupported(info)
      }
    }
  }

}

/// IEEE 754 half precision, without relying on the Float16 type.
private func halfFloat(_ bits: UInt16) -> Float {
  let sign: Float = bits & 0x8000 == 0 ? 1 : -1
  let exponent = Int((bits >> 10) & 0x1F)
  let fraction = Float(bits & 0x3FF)
  switch exponent {
  case 0: return sign * fraction / 1024 * pow(2, -14)
  case 31: return fraction == 0 ? sign * .infinity : .nan
  default: return sign * (1 + fraction / 1024) * pow(2, Float(exponent - 15))
  }
}

import Foundation

/// Tells the home network from others by its router's MAC address, so the
/// app doesn't sweep an office or hotel network for appliances. (The Wi-Fi
/// name would need location access.)
public enum NetworkFingerprint {
  /// The MAC address of the default gateway, or nil when it can't be read.
  public static func current() -> String? {
    guard let route = output("/sbin/route", ["-n", "get", "default"]),
          let gateway = capture(#"gateway:\s*([0-9.]+)"#, in: route),
          let arp = output("/usr/sbin/arp", ["-n", gateway]),
          let mac = capture(#" at ([0-9a-fA-F]{1,2}(?::[0-9a-fA-F]{1,2}){5}) "#, in: arp) else { return nil }
    return normalized(mac)
  }

  /// "0:1b:63:a:4c:ff" → "00:1b:63:0a:4c:ff".
  static func normalized(_ mac: String) -> String {
    mac.split(separator: ":").map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":").lowercased()
  }

  private static func output(_ path: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)
  }

  private static func capture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
  }
}

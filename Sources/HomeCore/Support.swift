import Foundation
import Network
import os

/// Lets exactly one of several racing callbacks resume a continuation.
final class Once: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if claimed { return false }
    claimed = true
    return true
  }
}

/// A value shared by callbacks that run on different queues.
final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) { self.value = value }

  func get() -> Value {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set(_ newValue: Value) {
    lock.lock()
    value = newValue
    lock.unlock()
  }
}

public enum NetError: LocalizedError {
  case timeout
  case closed
  case badReply
  case localNetworkDenied

  public var errorDescription: String? {
    switch self {
    case .timeout: return "Il dispositivo non risponde."
    case .closed: return "Il dispositivo ha chiuso la connessione."
    case .badReply: return "Il dispositivo ha dato una risposta che non capisco."
    case .localNetworkDenied:
      return "Domotica non ha l'accesso alla rete locale: consentilo in Impostazioni di Sistema › Privacy e sicurezza › Rete locale."
    }
  }
}

extension NWConnection {
  /// Starts the connection and waits until it is ready. A connection that
  /// would wait for the network to change counts as failed: callers only
  /// talk to devices that are on the network right now.
  func open(timeout: TimeInterval) async throws {
    let once = Once()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready:
          if once.claim() { continuation.resume() }
        case .waiting(let error), .failed(let error):
          let denied = self?.currentPath?.unsatisfiedReason == .localNetworkDenied
          if once.claim() { continuation.resume(throwing: denied ? NetError.localNetworkDenied : error) }
          self?.cancel()
        case .cancelled:
          if once.claim() { continuation.resume(throwing: NetError.timeout) }
        default:
          break
        }
      }
      start(queue: .global(qos: .userInitiated))
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
        guard once.claim() else { return }
        continuation.resume(throwing: NetError.timeout)
        self?.cancel()
      }
    }
  }

  func sendAll(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      send(content: data, completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      })
    }
  }

  /// Waits for exactly `count` bytes. Cancelling the connection ends the wait.
  func receive(exactly count: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
      receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let data, data.count == count {
          continuation.resume(returning: data)
        } else {
          continuation.resume(throwing: NetError.closed)
        }
      }
    }
  }
}

/// Timestamped lines in ~/Library/Logs/Domotica.log, and in the unified log.
public enum Log {
  public static let fileURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Domotica.log")
  private static let logger = Logger(subsystem: "dev.balsamo.home-control", category: "app")
  private static let queue = DispatchQueue(label: "home-control.log")
  private static let stamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()

  public static func info(_ message: String) {
    logger.info("\(message, privacy: .public)")
    let line = Data("\(stamp.string(from: Date())) \(message)\n".utf8)
    queue.async {
      if let handle = try? FileHandle(forWritingTo: fileURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
      } else {
        try? line.write(to: fileURL)
      }
    }
  }
}

extension Bundle {
  public var shortVersion: String {
    object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
  }
}

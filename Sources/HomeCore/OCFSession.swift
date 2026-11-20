import Foundation
import Network
import Security

/// CoAP over DTLS (RFC 7252 §9) to one Samsung appliance, read-only (GET
/// and Observe). An appliance takes one local connection at a time, so
/// there is one session per appliance, kept open.
///
/// Wire details that matter, all seen on a DA_WM_TP1_21_COMMON washer:
/// - DTLS 1.2 with ECDHE-ECDSA-AES128-GCM-SHA256, a client certificate, no
///   session tickets;
/// - large responses come as an empty ACK, then a confirmable response that
///   must be acknowledged, or the appliance keeps resending it;
/// - every block of a Block2 transfer must carry the token of the first,
///   or the appliance doesn't answer.
public final class OCFSession: @unchecked Sendable {
  public enum Failure: LocalizedError {
    case timeout
    case closed
    case handshake(String)

    public var errorDescription: String? {
      switch self {
      case .timeout: return "L'elettrodomestico non risponde."
      case .closed: return "Il collegamento con l'elettrodomestico si è chiuso."
      case .handshake(let detail): return "Collegamento cifrato con l'elettrodomestico non riuscito (\(detail))."
      }
    }
  }

  public let host: String
  public let port: UInt16

  private struct Pending {
    let deliver: (CoAPMessage) -> Void
    let fail: (Error) -> Void
  }

  private let queue: DispatchQueue
  private let connection: NWConnection
  // Everything below is touched only on `queue`.
  private var pending: [Data: Pending] = [:]
  private var observers: [Data: @Sendable (CoAPMessage) -> Void] = [:]
  private var messageID = UInt16.random(in: .min ... .max)
  private var finished = false
  private var closeHandler: (@Sendable (Error?) -> Void)?

  public init(host: String, port: UInt16, identity: SecIdentity) {
    self.host = host
    self.port = port
    queue = DispatchQueue(label: "ocf-session-\(host)")
    connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 49154,
                              using: Self.parameters(identity: identity, queue: queue))
  }

  /// Runs the DTLS handshake. `onClose` is called once when the session
  /// ends for any reason after that, on the session's queue.
  public func open(timeout: TimeInterval = 12, onClose: (@Sendable (Error?) -> Void)? = nil) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = Once()
      queue.async {
        self.closeHandler = onClose
        self.connection.stateUpdateHandler = { [weak self] state in
          guard let self else { return }
          switch state {
          case .ready:
            if once.claim() {
              continuation.resume()
              self.receive()
            }
          case .failed(let error), .waiting(let error):
            if once.claim() { continuation.resume(throwing: Failure.handshake(error.localizedDescription)) }
            self.finish(error)
          case .cancelled:
            if once.claim() { continuation.resume(throwing: Failure.closed) }
            self.finish(nil)
          default:
            break
          }
        }
        self.connection.start(queue: self.queue)
        self.queue.asyncAfter(deadline: .now() + timeout) {
          guard once.claim() else { return }
          continuation.resume(throwing: Failure.timeout)
          self.finish(Failure.timeout)
        }
      }
    }
  }

  /// GET, following Block2 with one token for the whole transfer.
  public func get(_ path: String, query: [String] = [], timeout: TimeInterval = 8) async throws -> CoAPMessage {
    let token = CoAPMessage.newToken()
    var reply = try await exchange(path, query: query, token: token, timeout: timeout)
    var body = reply.payload
    var blocks = 0
    while let block = reply.block2, block.more, blocks < 64 {
      blocks += 1
      reply = try await exchange(path, query: query, token: token, block2: block.number + 1, timeout: timeout)
      body += reply.payload
    }
    reply.payload = body
    return reply
  }

  /// Registers for notifications on `path` and returns the current
  /// representation; later ones go to `onChange`, on the session's queue.
  public func observe(_ path: String, timeout: TimeInterval = 8,
                      onChange: @escaping @Sendable (CoAPMessage) -> Void) async throws -> CoAPMessage {
    try await exchange(path, token: CoAPMessage.newToken(), observe: 0, observer: onChange, timeout: timeout)
  }

  public func close() {
    queue.async { self.finish(nil) }
  }

  // MARK: - Internals

  /// Sends a confirmable request and waits for its response, resending the
  /// same datagram after 2 and 4 seconds.
  private func exchange(_ path: String, query: [String] = [], token: Data, observe: UInt32? = nil,
                        block2: Int? = nil, observer: (@Sendable (CoAPMessage) -> Void)? = nil,
                        timeout: TimeInterval) async throws -> CoAPMessage {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CoAPMessage, Error>) in
      queue.async {
        guard !self.finished else {
          continuation.resume(throwing: Failure.closed)
          return
        }
        self.messageID &+= 1
        let request = CoAPMessage.get(path, query: query, messageID: self.messageID, token: token,
                                      observe: observe, block2: block2)
        let once = Once()
        self.pending[token] = Pending(deliver: { reply in if once.claim() { continuation.resume(returning: reply) } },
                                      fail: { error in if once.claim() { continuation.resume(throwing: error) } })
        if let observer { self.observers[token] = observer }
        self.send(request)
        for delay in [2.0, 4.0] where delay < timeout {
          self.queue.asyncAfter(deadline: .now() + delay) {
            if !self.finished, self.pending[token] != nil { self.send(request) }
          }
        }
        self.queue.asyncAfter(deadline: .now() + timeout) {
          guard let waiting = self.pending.removeValue(forKey: token) else { return }
          self.observers.removeValue(forKey: token)
          waiting.fail(Failure.timeout)
        }
      }
    }
  }

  private func send(_ message: CoAPMessage) {
    connection.send(content: message.encoded(), completion: .contentProcessed { _ in })
  }

  private func receive() {
    connection.receiveMessage { [weak self] data, _, _, error in
      guard let self else { return }
      if let data, let message = CoAPMessage.decode(data) { self.handle(message) }
      if let error {
        self.finish(error)
      } else if !self.finished {
        self.receive()
      }
    }
  }

  private func handle(_ message: CoAPMessage) {
    if message.kind == .confirmable { send(.emptyAck(message.messageID)) }
    // An empty ACK only says the response will come on its own.
    guard !message.isEmpty, message.kind != .reset else { return }
    if let waiting = pending.removeValue(forKey: message.token) {
      waiting.deliver(message)
    } else if let observer = observers[message.token] {
      observer(message)
    }
  }

  private func finish(_ error: Error?) {
    guard !finished else { return }
    finished = true
    connection.cancel()
    let waiting = pending.values
    pending.removeAll()
    observers.removeAll()
    for request in waiting { request.fail(Failure.closed) }
    closeHandler?(error)
    closeHandler = nil
  }

  private static func parameters(identity: SecIdentity, queue: DispatchQueue) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let options = tls.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(options, .DTLSv12)
    sec_protocol_options_set_max_tls_protocol_version(options, .DTLSv12)
    sec_protocol_options_append_tls_ciphersuite(options, .ECDHE_ECDSA_WITH_AES_128_GCM_SHA256)
    sec_protocol_options_set_tls_tickets_enabled(options, false)
    if let local = sec_identity_create(identity) { sec_protocol_options_set_local_identity(options, local) }
    sec_protocol_options_set_verify_block(options, { _, trust, complete in
      complete(isSamsungAppliance(sec_trust_copy_ref(trust).takeRetainedValue()))
    }, queue)
    return NWParameters(dtls: tls, udp: NWProtocolUDP.Options())
  }

  /// The appliances present Samsung "OCF HA Device" certificates, whose root
  /// isn't shipped here: the leaf's subject is the check.
  static func isSamsungAppliance(_ trust: SecTrust) -> Bool {
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
          let summary = SecCertificateCopySubjectSummary(leaf) as String? else { return false }
    return summary.hasPrefix("OCF Device")
  }
}

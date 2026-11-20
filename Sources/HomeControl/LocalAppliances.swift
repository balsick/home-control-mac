import Foundation
import HomeCore
import Security

/// Samsung washers and dryers read on the LAN over their own OCF interface:
/// no cloud, no token. One DTLS session per appliance stays open (they take
/// one local connection at a time), with Observe on the operational state
/// for changes as they happen, and a read every 30 s while running, 60 s
/// otherwise, which also notices a dead session.
@MainActor
final class LocalAppliances {
  struct Device: Identifiable {
    let id: String
    let info: OCFDeviceInfo
    let connected: Bool
    let problem: String?
  }

  private struct Entry {
    var info: OCFDeviceInfo
    var status: ApplianceStatus?
    var updated: Date?
    var power: JSONValue?
    var problem: String?
  }

  private enum ReadError: LocalizedError {
    case refused(String)

    var errorDescription: String? {
      switch self {
      case .refused(let code): return "L'elettrodomestico non accetta più la lettura locale (\(code))."
      }
    }
  }

  /// Called after every change, on the main actor.
  var onChange: (() -> Void)?
  private let network: HomeNetwork
  private(set) var searching = false
  private(set) var discoveredOnce = false

  private var entries: [String: Entry] = [:]
  private var sessions: [String: OCFSession] = [:]
  private var loops: [String: Task<Void, Never>] = [:]
  private var identity: SecIdentity?
  private var enabled = false
  private var discovery: Task<Void, Never>?
  private var lastDiscovery = Date.distantPast
  private static let savedKey = "localAppliances"
  private static let freshness: TimeInterval = 180

  init(network: HomeNetwork) {
    self.network = network
  }

  /// Appliances read in the last 3 minutes.
  var appliances: [Home.Appliance] {
    let fresh = entries.values.filter { entry in
      entry.status != nil && Date().timeIntervalSince(entry.updated ?? .distantPast) < Self.freshness
    }
    return fresh.compactMap { entry in
      guard let kind = entry.info.applianceKind, let status = entry.status else { return nil }
      let sameKind = fresh.filter { $0.info.applianceKind == kind }.count
      let name = kind == .washer ? "Lavatrice" : "Asciugatrice"
      return Home.Appliance(id: "local-\(entry.info.deviceID)",
                            name: sameKind > 1 ? "\(name) \(entry.info.model ?? entry.info.host)" : name,
                            kind: kind, status: status, updated: entry.updated, source: .local)
    }
  }

  /// The kinds of the appliances found on the LAN that aren't being read
  /// right now: those still need SmartThings. Nil while nothing was found.
  var unreadKinds: Set<ApplianceKind>? {
    guard !entries.isEmpty else { return nil }
    let read = Set(appliances.map(\.kind))
    return Set(entries.values.compactMap(\.info.applianceKind)).subtracting(read)
  }

  var devices: [Device] {
    entries.values.sorted { $0.info.host < $1.info.host }.map { entry in
      Device(id: entry.info.deviceID, info: entry.info, connected: sessions[entry.info.deviceID] != nil,
             problem: entry.problem)
    }
  }

  func start() {
    guard !enabled else { return }
    enabled = true
    for info in Self.saved() { entries[info.deviceID] = Entry(info: info) }
    for id in entries.keys { run(id) }
    discover(force: true)
  }

  func stop() {
    enabled = false
    discovery?.cancel()
    discovery = nil
    loops.values.forEach { $0.cancel() }
    loops.removeAll()
    sessions.values.forEach { $0.close() }
    sessions.removeAll()
    entries.removeAll()
    onChange?()
  }

  /// Asks every host of the LAN for /oic/d; at most every 10 minutes
  /// unless `force`, and only on the home network unless `manual`: sweeping
  /// an office network for appliances would be rude.
  func discover(force: Bool = false, manual: Bool = false) {
    guard enabled, discovery == nil, force || Date().timeIntervalSince(lastDiscovery) > 600,
          manual || network.isHome else { return }
    lastDiscovery = Date()
    searching = true
    onChange?()
    discovery = Task {
      let found = await OCFDiscovery.probe(OCFDiscovery.subnetHosts()).filter { $0.applianceKind != nil }
      guard enabled else { return }
      for info in found {
        if let known = entries[info.deviceID] {
          guard known.info.host != info.host else { continue }
          // It moved: the session to the old address is useless.
          entries[info.deviceID]?.info.host = info.host
          sessions.removeValue(forKey: info.deviceID)?.close()
          Log.info("local \(info.applianceKind?.rawValue ?? "?") moved to \(info.host)")
        } else {
          entries[info.deviceID] = Entry(info: info)
          run(info.deviceID)
        }
      }
      if !found.isEmpty { network.remember() }
      Self.save(entries.values.map(\.info))
      Log.info("local appliances: \(found.map { "\($0.applianceKind?.rawValue ?? "?") \($0.model ?? "") at \($0.host)" })")
      searching = false
      discoveredOnce = true
      discovery = nil
      onChange?()
    }
  }

  // MARK: - One appliance

  private func run(_ id: String) {
    guard loops[id] == nil else { return }
    loops[id] = Task { await loop(id) }
  }

  private func loop(_ id: String) async {
    var failures = 0
    while enabled, !Task.isCancelled, let info = entries[id]?.info {
      // Away from home that address is someone else's, or nobody's.
      guard network.isHome else {
        try? await Task.sleep(for: .seconds(60))
        continue
      }
      do {
        let session = try await connect(info)
        sessions[id] = session
        failures = 0
        try await read(id, session)
        // Push updates; the periodic read below still catches what they miss.
        _ = try? await session.observe("/operational/state/0") { [weak self] message in
          Task { @MainActor in self?.notified(id, message) }
        }
        while enabled, !Task.isCancelled, sessions[id] === session {
          try await Task.sleep(for: .seconds(entries[id]?.status?.isActive == true ? 30 : 60))
          try await read(id, session)
        }
        session.close()
      } catch is CancellationError {
        break
      } catch {
        failures += 1
        sessions.removeValue(forKey: id)?.close()
        entries[id]?.problem = error.localizedDescription
        if failures == 1 { Log.info("local \(info.host): \(error.localizedDescription)") }
        onChange?()
        // After a few failures the address may have changed.
        if failures == 3 { discover(force: true) }
        try? await Task.sleep(for: .seconds(min(10 * pow(2, Double(failures - 1)), 300)))
      }
    }
    loops[id] = nil
  }

  private func connect(_ info: OCFDeviceInfo) async throws -> OCFSession {
    if identity == nil { identity = try OCFIdentity.load() }
    guard let identity else { throw OCFIdentity.Failure.certificate }
    // The appliance assigns its DTLS port, and it can change.
    let port = await OCFDiscovery.securePort(of: info.host) ?? 49154
    let session = OCFSession(host: info.host, port: port, identity: identity)
    try await session.open()
    Log.info("local \(info.applianceKind?.rawValue ?? "?") at \(info.host):\(port) connected")
    return session
  }

  private func read(_ id: String, _ session: OCFSession) async throws {
    let power = try? await session.get("/power/0")
    let powerValue = power.flatMap { $0.isSuccess ? try? CBOR.decode($0.payload) : nil }
    let standard = try await session.get("/operational/state/0")
    if standard.isSuccess, let json = try? CBOR.decode(standard.payload) {
      update(id, ApplianceStatus(localState: json, power: powerValue), power: powerValue)
      return
    }
    // Models without the standard resource have Samsung's own.
    let samsung = try await session.get("/operational/state/vs/0")
    guard samsung.isSuccess, let json = try? CBOR.decode(samsung.payload) else {
      throw ReadError.refused(standard.codeDescription)
    }
    update(id, ApplianceStatus(samsungState: json, power: powerValue), power: powerValue)
  }

  private func notified(_ id: String, _ message: CoAPMessage) {
    guard message.isSuccess, let json = try? CBOR.decode(message.payload), json["currentMachineState"] != nil
    else { return }
    update(id, ApplianceStatus(localState: json, power: entries[id]?.power), power: nil)
  }

  private func update(_ id: String, _ status: ApplianceStatus, power: JSONValue?) {
    guard var entry = entries[id] else { return }
    entry.status = status
    entry.updated = Date()
    entry.problem = nil
    if let power { entry.power = power }
    entries[id] = entry
    onChange?()
  }

  // MARK: - Persistence

  private static func saved() -> [OCFDeviceInfo] {
    guard let data = UserDefaults.standard.data(forKey: savedKey) else { return [] }
    return (try? JSONDecoder().decode([OCFDeviceInfo].self, from: data)) ?? []
  }

  private static func save(_ devices: [OCFDeviceInfo]) {
    UserDefaults.standard.set(try? JSONEncoder().encode(devices), forKey: savedKey)
  }
}

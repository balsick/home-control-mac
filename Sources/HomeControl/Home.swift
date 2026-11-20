import AppKit
import HomeCore
import Observation

/// Everything the panel shows, and its actions. Local devices (Shelly, Kasa)
/// are polled every 3 s while the panel is on screen and every 20 s
/// otherwise. Washers and dryers are read on the LAN (`LocalAppliances`);
/// SmartThings only fills in what the LAN doesn't give. It counts API calls
/// (the Developer Plan allows 100,000 a month), so a running appliance is
/// read every minute and an idle one every 5.
@MainActor @Observable
final class Home {
  struct LightChannel: Identifiable, Equatable {
    let id: Int
    var name: String
    var isOn: Bool
    var brightness: Int
    var power: Double?
  }

  struct LightDevice: Identifiable, Equatable {
    let id: String
    var host: String
    var name = "Shelly"
    var model = ""
    var channels: [LightChannel] = []
    var reachable = false
    var update: String?
  }

  struct Plug: Identifiable, Equatable {
    struct Next: Equatable {
      var turnsOn: Bool
      var at: Date
    }

    let id: String
    var host: String
    var name = "Presa"
    var model = ""
    var isOn = false
    var onSince: Date?
    var next: Next?
    var reachable = false
  }

  struct Appliance: Identifiable, Equatable {
    enum Source: Equatable { case local, cloud }

    let id: String
    var name: String
    var kind: ApplianceKind
    var status: ApplianceStatus?
    var updated: Date?
    var source = Source.cloud
  }

  enum Cloud: Equatable {
    case loading, notConfigured, connected, failed(String)
    /// The personal token expired or the OAuth authorization was revoked.
    case needsToken(String)
  }

  private(set) var lights: [LightDevice] = []
  private(set) var plugs: [Plug] = []
  private(set) var appliances: [Appliance] = []
  private(set) var cloud = Cloud.loading
  private(set) var scanning = false
  private(set) var scannedOnce = false
  private(set) var message: String?
  /// When the personal token stops working (24 h after it was saved); nil
  /// with OAuth, which renews itself.
  private(set) var tokenExpiry: Date?
  /// False while the LAN gives every appliance: then SmartThings, its token
  /// and its errors don't matter.
  private(set) var cloudNeeded = true
  private(set) var localSearching = false

  /// The appliances card has something to say: appliances, a search under
  /// way, or SmartThings set up (its state, or its trouble). Without any of
  /// these, someone with no Samsung appliances doesn't see it at all.
  var showsAppliances: Bool {
    !appliances.isEmpty || localSearching || (cloud != .notConfigured && cloud != .loading)
  }
  private(set) var localDevices: [LocalAppliances.Device] = []

  /// Read washers and dryers on the LAN, over their undocumented local
  /// interface.
  var localEnabled: Bool {
    didSet {
      guard localEnabled != oldValue else { return }
      UserDefaults.standard.set(localEnabled, forKey: Keys.localEnabled)
      if localEnabled { local.start() } else { local.stop() }
      recomputeAppliances()
      Task { await refreshCloud(force: true) }
    }
  }

  /// Set while the popover or the floating panel is on screen.
  var visible = false {
    didSet {
      if visible, !oldValue { Task { await refreshLocal() } }
    }
  }

  var channelVisibility: [String: Bool] {
    didSet { UserDefaults.standard.set(channelVisibility, forKey: Keys.channelVisibility) }
  }

  var notifyWhenDone: Bool {
    didSet { UserDefaults.standard.set(notifyWhenDone, forKey: Keys.notifyWhenDone) }
  }

  @ObservationIgnored let auth: SmartThingsAuth
  @ObservationIgnored let local: LocalAppliances
  @ObservationIgnored private let network: HomeNetwork
  @ObservationIgnored var onAppliancesChanged: (() -> Void)?
  @ObservationIgnored private var cloudAppliances: [Appliance] = []
  @ObservationIgnored private let smartThings: SmartThingsClient
  @ObservationIgnored private var started = false
  @ObservationIgnored private var heldUntil: [String: Date] = [:]
  @ObservationIgnored private var pendingBrightness: [String: Int] = [:]
  @ObservationIgnored private var brightnessSenders: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var configFetched: [String: Date] = [:]
  @ObservationIgnored private var smartThingsDevices: [STDevice]?
  @ObservationIgnored private var smartThingsDevicesFetched = Date.distantPast
  @ObservationIgnored private var statusFetched: [String: Date] = [:]
  @ObservationIgnored private var toldTokenProblem = false
  @ObservationIgnored private var reminderScheduled = false
  @ObservationIgnored private var reminderExpiry: Date?
  @ObservationIgnored private var lastRescan = Date.distantPast
  @ObservationIgnored private var messageTimer: Task<Void, Never>?
  @ObservationIgnored private var askedNotificationPermission = false

  private enum Keys {
    static let shellyHosts = "shellyHosts"
    static let kasaHosts = "kasaHosts"
    static let channelVisibility = "channelVisibility"
    static let notifyWhenDone = "notifyWhenDone"
    static let localEnabled = "localAppliancesEnabled"
  }

  init() {
    let defaults = UserDefaults.standard
    channelVisibility = defaults.dictionary(forKey: Keys.channelVisibility) as? [String: Bool] ?? [:]
    notifyWhenDone = defaults.object(forKey: Keys.notifyWhenDone) as? Bool ?? true
    localEnabled = defaults.object(forKey: Keys.localEnabled) as? Bool ?? true
    auth = SmartThingsAuth()
    smartThings = SmartThingsClient(auth: auth)
    let network = HomeNetwork()
    self.network = network
    local = LocalAppliances(network: network)
    // Last known addresses, so the panel fills in before discovery ends.
    for (id, host) in Self.savedHosts(Keys.shellyHosts) { lights.append(LightDevice(id: id, host: host)) }
    for (id, host) in Self.savedHosts(Keys.kasaHosts) { plugs.append(Plug(id: id, host: host)) }
    local.onChange = { [weak self] in self?.recomputeAppliances() }
  }

  func start(demo: Bool = false) {
    guard !started else { return }
    started = true
    Task { await localLoop() }
    if demo {
      loadDemoAppliances()
      return
    }
    if localEnabled { local.start() }
    Task { await cloudLoop() }
  }

  /// `--demo`: two running appliances, as if read on the LAN, to look at
  /// the UI (and take screenshots) without real ones running.
  private func loadDemoAppliances() {
    cloudAppliances = [
      Appliance(id: "demo-washer", name: "Lavatrice", kind: .washer,
                status: ApplianceStatus(state: .running, phase: "Rinse", estimatedEnd: Date().addingTimeInterval(42 * 60),
                                        progress: 0.64, isOn: true), updated: Date(), source: .local),
      Appliance(id: "demo-dryer", name: "Asciugatrice", kind: .dryer,
                status: ApplianceStatus(state: .running, phase: "Drying", estimatedEnd: Date().addingTimeInterval(65 * 60),
                                        progress: 0.3, isOn: true), updated: Date(), source: .local),
    ]
    cloud = .connected
    recomputeAppliances()
  }

  // MARK: - Polling

  private func localLoop() async {
    await rescan()
    var last = Date()
    while true {
      try? await Task.sleep(for: .seconds(1))
      guard Date().timeIntervalSince(last) >= (visible ? 3 : 20) else { continue }
      last = Date()
      await refreshLocal()
      guard network.isHome else { continue }
      // Devices that stopped answering may have a new address: look again
      // every 2 minutes. New devices: every 10.
      let unreachable = lights.contains { !$0.reachable } || plugs.contains { !$0.reachable }
      if Date().timeIntervalSince(lastRescan) > (unreachable ? 120 : 600) { await rescan() }
    }
  }

  private func cloudLoop() async {
    // The LAN answers in a few seconds: give it the first word, so a stale
    // token doesn't flash a warning for appliances read locally anyway.
    if localEnabled { try? await Task.sleep(for: .seconds(12)) }
    while true {
      await refreshCloud()
      try? await Task.sleep(for: .seconds(60))
    }
  }

  /// Looks for Shelly (Bonjour) and Kasa (UDP broadcast) devices again;
  /// only on the home network unless `manual`.
  func rescan(manual: Bool = false) async {
    guard !scanning, manual || network.isHome else { return }
    scanning = true
    lastRescan = Date()
    async let shellyHosts = ShellyDiscovery.discover()
    async let kasaFound = KasaDiscovery.discover(timeout: 2.5)
    let (hosts, found) = await (shellyHosts, kasaFound)
    for host in hosts {
      guard let info = try? await ShellyClient(host: host).info(), (info.generation ?? 0) >= 2 else { continue }
      if let index = lights.firstIndex(where: { $0.id == info.id }) {
        lights[index].host = host
      } else {
        lights.append(LightDevice(id: info.id, host: host, name: info.name ?? "Shelly", model: info.app ?? ""))
      }
    }
    for plug in found {
      if !plugs.contains(where: { $0.id == plug.info.deviceId }) {
        plugs.append(Plug(id: plug.info.deviceId, host: plug.host))
      }
      if let index = plugs.firstIndex(where: { $0.id == plug.info.deviceId }) {
        plugs[index].host = plug.host
        apply(plug.info, at: index)
      }
    }
    saveHosts()
    if !hosts.isEmpty || !found.isEmpty { network.remember() }
    scanning = false
    scannedOnce = true
    Log.info("scan: Shelly \(hosts), Kasa \(found.map(\.host))")
    await refreshLocal()
  }

  func refreshLocal() async {
    // Away from home the saved addresses are someone else's: no requests.
    guard network.isHome else {
      markAway()
      return
    }
    await withTaskGroup(of: Void.self) { group in
      for id in lights.map(\.id) { group.addTask { await self.refreshLight(id) } }
      for id in plugs.map(\.id) { group.addTask { await self.refreshPlug(id) } }
    }
  }

  /// Discovery, local devices and SmartThings, now.
  func refreshEverything() {
    smartThingsDevices = nil
    // Asked for: even off the home network (a new router, say).
    Task { await rescan(manual: true) }
    local.discover(force: true, manual: true)
    Task { await refreshCloud(force: true) }
  }

  private func markAway() {
    for index in lights.indices where lights[index].reachable { lights[index].reachable = false }
    for index in plugs.indices where plugs[index].reachable { plugs[index].reachable = false }
  }

  private func refreshLight(_ id: String) async {
    guard let host = lights.first(where: { $0.id == id })?.host else { return }
    let client = ShellyClient(host: host)
    do {
      // Names change rarely: the configuration is read every 5 minutes.
      let config = Date().timeIntervalSince(configFetched[id] ?? .distantPast) > 300 ? try await client.config() : nil
      let status = try await client.status()
      guard let index = lights.firstIndex(where: { $0.id == id }) else { return }
      var device = lights[index]
      if let config {
        configFetched[id] = Date()
        if let name = config.deviceName { device.name = name }
      }
      device.channels = status.lights.map { light in
        let previous = device.channels.first { $0.id == light.id }
        var channel = LightChannel(id: light.id,
                                   name: config?.lightNames[light.id] ?? previous?.name ?? "Canale \(light.id + 1)",
                                   isOn: light.isOn, brightness: light.brightness, power: light.power)
        // Right after a command the device may still report the old state.
        if let previous, isHeld(channelKey(id, light.id)) {
          channel.isOn = previous.isOn
          channel.brightness = previous.brightness
        }
        return channel
      }
      device.update = status.availableUpdate
      if !device.reachable { Log.info("Shelly \(id) reachable at \(host)") }
      device.reachable = true
      if lights[index] != device { lights[index] = device }
    } catch {
      guard let index = lights.firstIndex(where: { $0.id == id }), lights[index].reachable else { return }
      lights[index].reachable = false
      Log.info("Shelly \(id) at \(host) unreachable: \(error.localizedDescription)")
    }
  }

  private func refreshPlug(_ id: String) async {
    guard let host = plugs.first(where: { $0.id == id })?.host else { return }
    do {
      let info = try await KasaClient(host: host).sysInfo()
      guard let index = plugs.firstIndex(where: { $0.id == id }) else { return }
      apply(info, at: index)
    } catch {
      guard let index = plugs.firstIndex(where: { $0.id == id }), plugs[index].reachable else { return }
      plugs[index].reachable = false
      Log.info("Kasa \(id) at \(host) unreachable: \(error.localizedDescription)")
    }
  }

  private func apply(_ info: KasaSysInfo, at index: Int) {
    var plug = plugs[index]
    plug.name = info.alias
    plug.model = info.model
    if !isHeld("kasa#\(plug.id)") { plug.isOn = info.isOn }
    if plug.isOn, info.isOn, let onTime = info.onTime {
      let since = Date().addingTimeInterval(-Double(onTime))
      // `on_time` has whole seconds: keep the old value unless it moved.
      if plug.onSince.map({ abs($0.timeIntervalSince(since)) > 5 }) ?? true { plug.onSince = since }
    } else if !plug.isOn {
      plug.onSince = nil
    }
    plug.next = Self.nextAction(info.nextAction)
    plug.reachable = true
    if plugs[index] != plug { plugs[index] = plug }
  }

  static func nextAction(_ action: KasaSysInfo.NextAction?, now: Date = Date()) -> Plug.Next? {
    guard let action, action.type != -1, let seconds = action.secondsOfDay, let act = action.action else { return nil }
    var at = Calendar.current.startOfDay(for: now).addingTimeInterval(TimeInterval(seconds))
    if at < now.addingTimeInterval(-60) { at = Calendar.current.date(byAdding: .day, value: 1, to: at) ?? at }
    return Plug.Next(turnsOn: act == 1, at: at)
  }

  // MARK: - SmartThings

  /// Reads from SmartThings the appliances the LAN doesn't give (not found
  /// locally, or failing there) and that are due (see the type's comment);
  /// `force` reads them all. When the LAN gives everything, the cloud isn't
  /// contacted at all.
  func refreshCloud(force: Bool = false) async {
    // nil: nothing was found on the LAN, so every kind comes from the cloud.
    let wanted = local.unreadKinds
    if !cloudNeeded, wanted?.isEmpty == true {
      if !cloudAppliances.isEmpty {
        cloudAppliances = []
        recomputeAppliances()
      }
      return
    }
    do {
      if smartThingsDevices == nil || Date().timeIntervalSince(smartThingsDevicesFetched) > 6 * 3600 {
        smartThingsDevices = try await smartThings.devices().filter { $0.applianceKind != nil }
        smartThingsDevicesFetched = Date()
        statusFetched = [:]
      }
      let summary = await auth.summary()
      tokenExpiry = summary.mode == .personalToken ? summary.personalTokenSavedAt?.addingTimeInterval(86_400) : nil
      if cloudNeeded, !reminderScheduled || reminderExpiry != tokenExpiry {
        reminderScheduled = true
        reminderExpiry = tokenExpiry
        Notifier.remindTokenExpiry(at: tokenExpiry)
      }
      var updated: [Appliance] = []
      for device in smartThingsDevices ?? [] {
        guard let kind = device.applianceKind, wanted?.contains(kind) ?? true else { continue }
        let current = cloudAppliances.first { $0.id == device.deviceId }
        let interval: TimeInterval = current?.status?.isActive == true ? 60 : 300
        if !force, let current, let last = statusFetched[device.deviceId],
           Date().timeIntervalSince(last) < interval - 5 {
          updated.append(current)
          continue
        }
        let (json, _) = try await smartThings.status(of: device.deviceId)
        statusFetched[device.deviceId] = Date()
        updated.append(Appliance(id: device.deviceId, name: device.displayName, kind: kind,
                                 status: ApplianceStatus(parsing: json, kind: kind), updated: Date()))
      }
      cloudAppliances = updated
      if cloud != .connected { Log.info("SmartThings connected: \(updated.map(\.name))") }
      cloud = .connected
      toldTokenProblem = false
    } catch SmartThingsError.notConfigured {
      cloudAppliances = []
      cloud = .notConfigured
    } catch let error as SmartThingsError where error == .tokenRejected || error == .reauthorizationNeeded {
      // What's on screen would be stale: better nothing and a way to fix it.
      cloudAppliances = []
      cloud = .needsToken(error.localizedDescription)
      if cloudNeeded, !toldTokenProblem {
        toldTokenProblem = true
        Notifier.smartThingsNeedsAttention(error.localizedDescription)
        Log.info("SmartThings: \(error.localizedDescription)")
      }
    } catch {
      cloud = .failed(error.localizedDescription)
      Log.info("SmartThings: \(error.localizedDescription)")
    }
    recomputeAppliances()
  }

  /// Local readings first; SmartThings only for the kinds they don't cover.
  /// Cycle ends are noticed here, whichever side reported them.
  private func recomputeAppliances() {
    let readLocally = local.appliances
    let localKinds = Set(readLocally.map(\.kind))
    let merged = (readLocally + cloudAppliances.filter { !localKinds.contains($0.kind) })
      .sorted { ($0.kind == .washer ? 0 : 1, $0.name) < ($1.kind == .washer ? 0 : 1, $1.name) }
    for appliance in merged {
      guard notifyWhenDone, let new = appliance.status,
            let old = appliances.first(where: { $0.kind == appliance.kind })?.status,
            old.isActive, !new.isActive else { continue }
      Notifier.cycleFinished(appliance.name, kind: appliance.kind)
      Log.info("\(appliance.name) finished")
    }
    // Asked the first time an appliance shows up: the notifications are about them.
    if !merged.isEmpty, notifyWhenDone, !askedNotificationPermission {
      askedNotificationPermission = true
      Notifier.requestPermission()
    }
    if merged != appliances { appliances = merged }
    let needed = !(local.unreadKinds?.isEmpty == true && !readLocally.isEmpty)
    if needed != cloudNeeded {
      cloudNeeded = needed
      Log.info(needed ? "SmartThings needed again" : "washer and dryer read on the LAN: SmartThings not needed")
      if !needed {
        Notifier.remindTokenExpiry(at: nil)
        reminderScheduled = false
      }
    }
    if localSearching != local.searching { localSearching = local.searching }
    localDevices = local.devices
    onAppliancesChanged?()
  }

  /// After the credentials change in the settings.
  func smartThingsChanged() {
    smartThingsDevices = nil
    cloud = .loading
    Task { await refreshCloud(force: true) }
  }

  // MARK: - Actions

  func setLight(_ deviceID: String, channel: Int, on: Bool) {
    guard let (d, c) = indices(deviceID, channel) else { return }
    lights[d].channels[c].isOn = on
    let key = channelKey(deviceID, channel)
    hold(key)
    let host = lights[d].host
    let name = lights[d].channels[c].name
    Log.info("command: \(name) \(on ? "on" : "off")")
    Task {
      do {
        try await ShellyClient(host: host).setLight(id: channel, on: on)
      } catch {
        show("\(name): \(error.localizedDescription)")
      }
      heldUntil[key] = nil
      await refreshLight(deviceID)
    }
  }

  /// Called for every step of the slider: sends the latest value, at most
  /// one request in flight per channel.
  func setBrightness(_ deviceID: String, channel: Int, to value: Int) {
    guard let (d, c) = indices(deviceID, channel) else { return }
    let value = min(max(value, 1), 100)
    guard lights[d].channels[c].brightness != value || !lights[d].channels[c].isOn else { return }
    lights[d].channels[c].brightness = value
    lights[d].channels[c].isOn = true
    let key = channelKey(deviceID, channel)
    hold(key)
    pendingBrightness[key] = value
    guard brightnessSenders[key] == nil else { return }
    let host = lights[d].host
    let name = lights[d].channels[c].name
    brightnessSenders[key] = Task {
      var last: Int?
      while let next = pendingBrightness.removeValue(forKey: key) {
        do {
          try await ShellyClient(host: host).setLight(id: channel, on: true, brightness: next, transition: 0.5)
          last = next
        } catch {
          show(error.localizedDescription)
        }
        try? await Task.sleep(for: .milliseconds(150))
      }
      brightnessSenders[key] = nil
      hold(key, for: 2)
      // One line per drag, with where it ended.
      if let last { Log.info("command: \(name) on at \(last)%") }
    }
  }

  func setPlug(_ id: String, on: Bool) {
    guard let index = plugs.firstIndex(where: { $0.id == id }) else { return }
    plugs[index].isOn = on
    plugs[index].onSince = on ? Date() : nil
    let key = "kasa#\(id)"
    hold(key)
    let host = plugs[index].host
    let name = plugs[index].name
    Log.info("command: \(name) \(on ? "on" : "off")")
    Task {
      do {
        try await KasaClient(host: host).setRelay(on: on)
      } catch {
        show("\(name): \(error.localizedDescription)")
      }
      heldUntil[key] = nil
      await refreshPlug(id)
    }
  }

  // MARK: - Channel visibility

  func visibleChannels(of device: LightDevice) -> [LightChannel] {
    device.channels.filter { isVisible(device.id, $0) }
  }

  /// Channels named like "Disconnessa" start hidden.
  func isVisible(_ deviceID: String, _ channel: LightChannel) -> Bool {
    channelVisibility[channelKey(deviceID, channel.id)] ?? !Self.looksUnused(channel.name)
  }

  func setVisible(_ visible: Bool, _ deviceID: String, _ channelID: Int) {
    channelVisibility[channelKey(deviceID, channelID)] = visible
  }

  static func looksUnused(_ name: String) -> Bool {
    let name = name.lowercased()
    return ["disconness", "scollegat", "non usat", "disconnected", "unused"].contains { name.contains($0) }
  }

  // MARK: - Helpers

  private func show(_ text: String) {
    message = text
    Log.info("shown: \(text)")
    messageTimer?.cancel()
    messageTimer = Task {
      try? await Task.sleep(for: .seconds(6))
      if !Task.isCancelled { message = nil }
    }
  }

  private func indices(_ deviceID: String, _ channel: Int) -> (Int, Int)? {
    guard let d = lights.firstIndex(where: { $0.id == deviceID }),
          let c = lights[d].channels.firstIndex(where: { $0.id == channel }) else { return nil }
    return (d, c)
  }

  private func channelKey(_ deviceID: String, _ channel: Int) -> String { "\(deviceID)#\(channel)" }

  private func hold(_ key: String, for seconds: TimeInterval = 5) {
    heldUntil[key] = Date().addingTimeInterval(seconds)
  }

  private func isHeld(_ key: String) -> Bool { (heldUntil[key] ?? .distantPast) > Date() }

  private static func savedHosts(_ key: String) -> [(String, String)] {
    ((UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:])
      .sorted { $0.key < $1.key }
      .map { ($0.key, $0.value) }
  }

  private func saveHosts() {
    UserDefaults.standard.set(Dictionary(lights.map { ($0.id, $0.host) }, uniquingKeysWith: { first, _ in first }),
                              forKey: Keys.shellyHosts)
    UserDefaults.standard.set(Dictionary(plugs.map { ($0.id, $0.host) }, uniquingKeysWith: { first, _ in first }),
                              forKey: Keys.kasaHosts)
  }
}

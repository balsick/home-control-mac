import Foundation

public enum ApplianceKind: String, Sendable, Codable {
  case washer, dryer
}

/// What a Samsung washer or dryer reports through SmartThings, reduced to
/// what the app shows. Recent appliances report `samsungce.*OperatingState`
/// (state, remaining minutes, progress); every one reports the standard
/// `washerOperatingState` / `dryerOperatingState` (state and an absolute
/// completion time). Both are read, the Samsung one first.
public struct ApplianceStatus: Sendable, Equatable {
  public enum State: String, Sendable {
    case running, paused, idle, unknown
  }

  public var state: State
  /// The raw job state, e.g. "wash", "rinse", "spin", "drying", "cooling".
  public var phase: String?
  public var estimatedEnd: Date?
  /// 0...1.
  public var progress: Double?
  public var isOn: Bool?
  public var remoteControl: Bool?
  /// Watts, when the appliance reports its consumption.
  public var power: Double?

  public var isActive: Bool { state == .running || state == .paused }
  public var hasFinished: Bool { state == .idle && ["finish", "finished"].contains(phase?.lowercased() ?? "") }

  public init(state: State, phase: String? = nil, estimatedEnd: Date? = nil, progress: Double? = nil,
              isOn: Bool? = nil, remoteControl: Bool? = nil, power: Double? = nil) {
    self.state = state
    self.phase = phase
    self.estimatedEnd = estimatedEnd
    self.progress = progress
    self.isOn = isOn
    self.remoteControl = remoteControl
    self.power = power
  }

  /// `status` is the JSON of `GET /v1/devices/{id}/status`.
  public init(parsing status: JSONValue, kind: ApplianceKind, now: Date = Date()) {
    let main = status["components"]?["main"]
    func attribute(_ capability: String, _ name: String) -> JSONValue? { main?[capability]?[name] }
    func value(_ capability: String, _ name: String) -> JSONValue? {
      guard let value = attribute(capability, name)?["value"], value != .null else { return nil }
      return value
    }
    func updated(_ capability: String, _ name: String) -> Date {
      attribute(capability, name)?["timestamp"]?.string.flatMap(Self.date) ?? .distantPast
    }

    let samsung = kind == .washer ? "samsungce.washerOperatingState" : "samsungce.dryerOperatingState"
    let standard = kind == .washer ? "washerOperatingState" : "dryerOperatingState"
    let job = kind == .washer ? "washerJobState" : "dryerJobState"

    let samsungState = value(samsung, "operatingState")?.string
      .flatMap { ["running": State.running, "paused": .paused, "ready": .idle][$0] }
    let standardState = value(standard, "machineState")?.string
      .flatMap { ["run": State.running, "pause": .paused, "stop": .idle][$0] }
    // The two can disagree when one stops updating (seen on a real washer:
    // the Samsung one frozen for days, the standard one refreshed every
    // night). Then the one updated last wins, and the other's numbers are
    // stale too.
    let useSamsung: Bool
    switch (samsungState, standardState) {
    case let (samsungState?, standardState?) where samsungState != standardState:
      useSamsung = updated(samsung, "operatingState") >= updated(standard, "machineState")
    case (.some, _):
      useSamsung = true
    default:
      useSamsung = false
    }
    let state = (useSamsung ? samsungState : standardState) ?? .unknown
    self.state = state

    let phase = useSamsung ? value(samsung, job)?.string ?? value(standard, job)?.string : value(standard, job)?.string
    self.phase = phase == "none" ? nil : phase

    var end: Date?
    if state == .running || state == .paused {
      if useSamsung, let remaining = value(samsung, "remainingTime")?.number {
        end = now.addingTimeInterval(remaining * Self.seconds(per: attribute(samsung, "remainingTime")?["unit"]?.string))
      } else if let text = value(standard, "completionTime")?.string, let date = Self.date(text), date > now {
        end = date
      }
    }
    estimatedEnd = end

    if state == .running || state == .paused, useSamsung, let percent = value(samsung, "progress")?.number {
      progress = min(max(percent / 100, 0), 1)
    } else {
      progress = nil
    }
    isOn = value("switch", "switch")?.string.map { $0 == "on" }
    remoteControl = value("remoteControlStatus", "remoteControlEnabled")?.bool
    power = value("powerConsumptionReport", "powerConsumption")?["power"]?.number
  }

  /// From the appliance's own OCF resources, read on the LAN: `state` is
  /// `/operational/state/0` (`currentMachineState`, `currentJobState`,
  /// `remainingTime` as "hh:mm:ss", `progressPercentage`), `power` is
  /// `/power/0` (`value`).
  public init(localState state: JSONValue, power: JSONValue? = nil, now: Date = Date()) {
    let machine = state["currentMachineState"]?.string?.lowercased() ?? ""
    let mapped = ["active": State.running, "running": .running, "pause": .paused, "paused": .paused,
                  "idle": .idle][machine] ?? .unknown
    let active = mapped == .running || mapped == .paused
    let job = state["currentJobState"]?.string
    let remaining = state["remainingTime"]?.string.flatMap(Self.clockDuration)
    self.init(state: mapped,
              phase: job == "None" ? nil : job,
              estimatedEnd: active ? remaining.map { now.addingTimeInterval($0) } : nil,
              progress: active ? state["progressPercentage"]?.number.map { min(max($0 / 100, 0), 1) } : nil,
              isOn: power?["value"]?.bool)
  }

  /// The same from Samsung's own `/operational/state/vs/0`, for appliances
  /// without the standard resource.
  public init(samsungState state: JSONValue, power: JSONValue? = nil, now: Date = Date()) {
    let raw = state["x.com.samsung.da.state"]?.string?.lowercased() ?? ""
    let mapped = ["run": State.running, "running": .running, "pause": .paused, "ready": .idle, "stop": .idle,
                  "idle": .idle][raw] ?? .unknown
    let active = mapped == .running || mapped == .paused
    let phase = state["x.com.samsung.da.progress"]?.string
    let remaining = state["x.com.samsung.da.remainingTime"]?.string.flatMap(Self.clockDuration)
    self.init(state: mapped,
              phase: phase == "None" ? nil : phase,
              estimatedEnd: active ? remaining.map { now.addingTimeInterval($0) } : nil,
              progress: active ? state["x.com.samsung.da.progressPercentage"]?.number.map { min(max($0 / 100, 0), 1) } : nil,
              isOn: power?["value"]?.bool)
  }

  /// "01:14:00" → 4440 seconds.
  static func clockDuration(_ text: String) -> TimeInterval? {
    let parts = text.split(separator: ":").compactMap { Double($0) }
    guard parts.count == 3 else { return nil }
    return parts[0] * 3600 + parts[1] * 60 + parts[2]
  }

  static func seconds(per unit: String?) -> Double {
    switch unit?.lowercased() {
    case "s", "sec", "second", "seconds": return 1
    case "h", "hr", "hour", "hours": return 3600
    default: return 60
    }
  }

  static func date(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
  }
}

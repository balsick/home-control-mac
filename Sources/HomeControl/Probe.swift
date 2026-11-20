import Foundation
import HomeCore
import ServiceManagement

/// `home-control --probe`: what the app sees, printed. It saves the raw
/// SmartThings payloads (no credentials) next to the app's data, to check the
/// parsing against real devices.
enum Probe {
  static let dumpFolder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Domotica/probe")

  static func run() async {
    let login = ["notRegistered", "enabled", "requiresApproval", "notFound"]
    let status = SMAppService.mainApp.status.rawValue
    print("Open at login: \(status < login.count ? login[status] : String(status))")
    print("Shelly (Bonjour _shelly._tcp)")
    let hosts = await ShellyDiscovery.discover()
    if hosts.isEmpty { print("  none found") }
    for host in hosts {
      let client = ShellyClient(host: host)
      do {
        let info = try await client.info()
        let config = try await client.config()
        let status = try await client.status()
        print("  \(info.id) at \(host): \(info.app ?? "?") \(info.version ?? "?"), profile \(info.profile ?? "-")"
              + (status.availableUpdate.map { ", update \($0) available" } ?? ""))
        for light in status.lights {
          let name = config.lightNames[light.id] ?? "-"
          print("    light:\(light.id) \(name): \(light.isOn ? "on" : "off"), \(light.brightness)%, "
                + "\(light.power ?? 0) W, \(light.voltage ?? 0) V")
        }
      } catch {
        print("  \(host): \(error.localizedDescription)")
      }
    }

    print("Kasa (UDP 9999 broadcast)")
    let plugs = await KasaDiscovery.discover(timeout: 2.5)
    if plugs.isEmpty { print("  none found") }
    for plug in plugs {
      let tcp: String
      do {
        let info = try await KasaClient(host: plug.host).sysInfo()
        tcp = "TCP ok, \(info.isOn ? "on" : "off")"
      } catch {
        tcp = "TCP failed: \(error.localizedDescription)"
      }
      let next = plug.info.nextAction.flatMap { action -> String? in
        guard action.type != -1, let seconds = action.secondsOfDay else { return nil }
        return "next: \(action.action == 1 ? "on" : "off") at \(seconds / 3600):\(String(format: "%02d", seconds / 60 % 60))"
      }
      print("  \(plug.info.alias) (\(plug.info.model)) at \(plug.host): \(tcp)" + (next.map { ", \($0)" } ?? ""))
    }

    // An appliance takes one local session at a time: run.sh stops the app first.
    print("Samsung appliances on the LAN (OCF: /oic/d over CoAP, state over DTLS)")
    let found = await OCFDiscovery.probe(OCFDiscovery.subnetHosts()).filter { $0.applianceKind != nil }
    if found.isEmpty { print("  none found") }
    for info in found {
      let port = await OCFDiscovery.securePort(of: info.host)
      print("  \(info.applianceKind?.rawValue ?? "?") \(info.model ?? "?") at \(info.host), DTLS port \(port.map(String.init) ?? "?")")
      do {
        let session = OCFSession(host: info.host, port: port ?? 49154, identity: try OCFIdentity.load())
        let started = Date()
        try await session.open()
        let state = try await session.get("/operational/state/0")
        let power = try await session.get("/power/0")
        session.close()
        let stateJSON = try CBOR.decode(state.payload)
        let status = ApplianceStatus(localState: stateJSON, power: try? CBOR.decode(power.payload))
        let left = status.estimatedEnd.map { "\(Int($0.timeIntervalSinceNow / 60)) min left" } ?? "-"
        print("    \(state.codeDescription) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s: "
              + "state \(status.state.rawValue), phase \(status.phase ?? "-"), \(left), "
              + "progress \(status.progress.map { "\(Int($0 * 100))%" } ?? "-"), on \(status.isOn.map(String.init) ?? "-")")
        try? FileManager.default.createDirectory(at: dumpFolder, withIntermediateDirectories: true)
        try? state.payload.write(to: dumpFolder.appendingPathComponent("local-\(info.applianceKind?.rawValue ?? "x")-state.cbor"))
      } catch {
        print("    \(error.localizedDescription)")
      }
    }

    print("SmartThings")
    let client = SmartThingsClient(auth: SmartThingsAuth())
    do {
      let devices = try await client.devices()
      try? FileManager.default.createDirectory(at: dumpFolder, withIntermediateDirectories: true)
      print("  \(devices.count) devices")
      for device in devices {
        print("  \(device.displayName) [\(device.applianceKind?.rawValue ?? "-")] \(device.ocf?.ocfDeviceType ?? "")")
        guard let kind = device.applianceKind else { continue }
        let (json, raw) = try await client.status(of: device.deviceId)
        try? raw.write(to: dumpFolder.appendingPathComponent("\(kind.rawValue)-status.json"))
        let status = ApplianceStatus(parsing: json, kind: kind)
        let end = status.estimatedEnd.map { $0.formatted(date: .omitted, time: .shortened) } ?? "-"
        let progress = status.progress.map { "\(Int($0 * 100))%" } ?? "-"
        print("    state \(status.state.rawValue), phase \(status.phase ?? "-"), end \(end), progress \(progress), "
              + "on \(status.isOn.map(String.init) ?? "-"), remote \(status.remoteControl.map(String.init) ?? "-")")
      }
      print("  raw status saved in \(dumpFolder.path)")
    } catch {
      print("  \(error.localizedDescription)")
    }
  }
}

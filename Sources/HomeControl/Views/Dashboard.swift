import HomeCore
import SwiftUI

enum Placement {
  case popover, panel
}

struct DashboardActions {
  var detach: @MainActor () -> Void = {}
  var reattach: @MainActor () -> Void = {}
  var close: @MainActor () -> Void = {}
  var openSettings: @MainActor () -> Void = {}
  var renewToken: @MainActor () -> Void = {}
  var quit: @MainActor () -> Void = {}
}

/// The same content in the popover and in the floating panel.
struct DashboardView: View {
  let placement: Placement
  let actions: DashboardActions
  @Environment(Home.self) private var home

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      devices
      if home.showsAppliances {
        AppliancesCard(openSettings: actions.openSettings, renewToken: actions.renewToken)
      }
      if let message = home.message {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 10)
    .padding(.bottom, 12)
    .frame(width: 340, alignment: .topLeading)
    .fixedSize(horizontal: false, vertical: true)
    // Our own material in both places: the popover's glass can turn dark
    // over a dark window while the text stays light-mode.
    .background {
      PanelMaterial(cornerRadius: placement == .panel ? 14 : 0)
    }
  }

  private var header: some View {
    HStack(spacing: 2) {
      Text("Casa").font(.headline)
      if home.scanning {
        ProgressView().controlSize(.mini).padding(.leading, 6)
      }
      Spacer()
      IconButton(systemImage: "arrow.clockwise", help: "Aggiorna e cerca i dispositivi") { home.refreshEverything() }
      if placement == .popover {
        IconButton(systemImage: "pin", help: "Stacca in una finestra fluttuante", action: actions.detach)
      } else {
        IconButton(systemImage: "pin.slash", help: "Riaggancia alla barra dei menu", action: actions.reattach)
      }
      Menu {
        Button("Impostazioni…", action: actions.openSettings)
        Divider()
        Button("Esci da Domotica", action: actions.quit)
      } label: {
        Image(systemName: "gearshape")
      }
      .menuStyle(.button)
      .buttonStyle(.borderless)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Impostazioni")
      if placement == .panel {
        IconButton(systemImage: "xmark", help: "Chiudi la finestra", action: actions.close)
      }
    }
    .padding(.leading, 2)
    .frame(height: 26)
    // The borderless panel moves by its header.
    .background {
      if placement == .panel { WindowDragArea() }
    }
  }

  @ViewBuilder private var devices: some View {
    let lights = home.lights.filter { !home.visibleChannels(of: $0).isEmpty || !$0.reachable }
    if lights.isEmpty, home.plugs.isEmpty {
      Card(title: "Dispositivi", systemImage: "wifi") {
        if home.scanning || !home.scannedOnce {
          Text("Cerco luci e prese sulla rete…").font(.callout).foregroundStyle(.secondary)
        } else {
          Text("Nessuna luce o presa trovata. Se macOS ha chiesto l'accesso alla rete locale, consentilo in Impostazioni di Sistema › Privacy e sicurezza › Rete locale.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    ForEach(lights) { device in
      LightsCard(device: device, showName: lights.count > 1)
    }
    if !home.plugs.isEmpty {
      Card(title: "Prese", systemImage: "powerplug.fill") {
        ForEach(home.plugs) { PlugRow(plug: $0) }
      }
    }
  }
}

struct LightsCard: View {
  let device: Home.LightDevice
  let showName: Bool
  @Environment(Home.self) private var home

  var body: some View {
    Card(title: showName ? device.name : "Luci", systemImage: "lightbulb.2.fill", trailing: trailing) {
      if !device.reachable, device.channels.isEmpty {
        Text("Non raggiungibile").font(.callout).foregroundStyle(.secondary)
      }
      ForEach(home.visibleChannels(of: device)) { channel in
        LightRow(deviceID: device.id, channel: channel)
      }
    }
    .disabled(!device.reachable)
    .opacity(device.reachable ? 1 : 0.6)
  }

  private var trailing: String? {
    // With no channels known yet, the card's body already says it.
    guard device.reachable else { return device.channels.isEmpty ? nil : "non raggiungibile" }
    let watts = device.channels.compactMap { $0.isOn ? $0.power : nil }.reduce(0, +)
    return watts >= 0.1 ? Format.watts(watts) : nil
  }
}

struct LightRow: View {
  let deviceID: String
  let channel: Home.LightChannel
  @Environment(Home.self) private var home

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: channel.isOn ? "lightbulb.fill" : "lightbulb")
        .font(.system(size: 15))
        .foregroundStyle(channel.isOn ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.tertiary))
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 1) {
        HStack(alignment: .firstTextBaseline) {
          Text(channel.name).lineLimit(1)
          Spacer(minLength: 4)
          Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        Slider(value: brightness, in: 1...100)
          .controlSize(.mini)
          .help("Luminosità")
      }
      Toggle("", isOn: isOn)
        .toggleStyle(.switch)
        .labelsHidden()
        .controlSize(.mini)
    }
  }

  private var detail: String {
    var parts = ["\(channel.brightness)%"]
    if channel.isOn, let power = channel.power, power >= 0.1 { parts.append(Format.watts(power)) }
    return parts.joined(separator: " · ")
  }

  private var isOn: Binding<Bool> {
    Binding(get: { channel.isOn }, set: { home.setLight(deviceID, channel: channel.id, on: $0) })
  }

  private var brightness: Binding<Double> {
    Binding(get: { Double(channel.brightness) },
            set: { home.setBrightness(deviceID, channel: channel.id, to: Int($0.rounded())) })
  }
}

struct PlugRow: View {
  let plug: Home.Plug
  @Environment(Home.self) private var home

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "powerplug.fill")
        .font(.system(size: 14))
        .foregroundStyle(plug.isOn ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 1) {
        Text(plug.name).lineLimit(1)
        TimelineView(.everyMinute) { context in
          if let detail = detail(now: context.date) {
            Text(detail).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Spacer(minLength: 8)
      Toggle("", isOn: Binding(get: { plug.isOn }, set: { home.setPlug(plug.id, on: $0) }))
        .toggleStyle(.switch)
        .labelsHidden()
        .controlSize(.mini)
        .disabled(!plug.reachable)
    }
  }

  private func detail(now: Date) -> String? {
    guard plug.reachable else { return "Non raggiungibile" }
    var parts: [String] = []
    if plug.isOn, let since = plug.onSince { parts.append("accesa da \(Format.duration(now.timeIntervalSince(since)))") }
    if let next = plug.next {
      parts.append("\(next.turnsOn ? "si accende" : "si spegne") \(Format.dayAndTime(next.at, now: now))")
    }
    guard !parts.isEmpty else { return nil }
    let text = parts.joined(separator: " · ")
    return text.prefix(1).uppercased() + text.dropFirst()
  }
}

struct AppliancesCard: View {
  let openSettings: @MainActor () -> Void
  let renewToken: @MainActor () -> Void
  @Environment(Home.self) private var home

  /// With a personal token, renewing means making a new one on SmartThings'
  /// page; with OAuth, authorizing again in the settings.
  private var renew: @MainActor () -> Void { home.tokenExpiry == nil ? openSettings : renewToken }

  var body: some View {
    Card(title: "Elettrodomestici", systemImage: "washer.fill", trailing: source) {
      if !home.appliances.isEmpty {
        ForEach(home.appliances) { ApplianceRow(appliance: $0) }
        // SmartThings' troubles only matter for what the LAN doesn't give.
        if home.cloudNeeded { cloudFootnote }
      } else if home.localSearching {
        HStack(spacing: 6) {
          ProgressView().controlSize(.mini)
          Text("Cerco lavatrice e asciugatrice sulla rete…").font(.callout).foregroundStyle(.secondary)
        }
      } else {
        cloudOnly
      }
    }
  }

  /// Where the readings come from, when they all come from one place.
  private var source: String? {
    guard !home.appliances.isEmpty else { return nil }
    if home.appliances.allSatisfy({ $0.source == .local }) { return "in locale" }
    if home.appliances.allSatisfy({ $0.source == .cloud }) { return "SmartThings" }
    return nil
  }

  @ViewBuilder private var cloudFootnote: some View {
    switch home.cloud {
    case .failed(let message), .needsToken(let message):
      HStack(alignment: .firstTextBaseline) {
        Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 4)
        Button("Rinnova…", action: renew).controlSize(.small)
      }
    default:
      // The personal token lasts 24 hours: warn in its last 3.
      if let expiry = home.tokenExpiry, expiry.timeIntervalSinceNow < 3 * 3600 {
        HStack(alignment: .firstTextBaseline) {
          Text("Il token SmartThings scade \(Format.dayAndTime(expiry)).")
            .font(.caption)
            .foregroundStyle(.orange)
          Spacer(minLength: 4)
          Button("Rinnova…", action: renew).controlSize(.small)
        }
      }
    }
  }

  /// Nothing on the LAN: what SmartThings says, or how to connect it.
  @ViewBuilder private var cloudOnly: some View {
    switch home.cloud {
    case .notConfigured:
      Text(home.localEnabled ? "Non trovo lavatrice e asciugatrice sulla rete. Puoi vederle anche con SmartThings."
                             : "Collega SmartThings per vedere lavatrice e asciugatrice.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Collega SmartThings…", action: openSettings).controlSize(.small)
    case .loading:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Chiedo a SmartThings…").font(.callout).foregroundStyle(.secondary)
      }
    case .needsToken(let message):
      Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
      Button("Rinnova…", action: renew).controlSize(.small)
    case .failed(let message):
      Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      Button("Impostazioni…", action: openSettings).controlSize(.small)
    case .connected:
      Text("Nessuna lavatrice o asciugatrice trovata.").font(.callout).foregroundStyle(.secondary)
    }
  }
}

struct ApplianceRow: View {
  let appliance: Home.Appliance

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let state = describe(now: context.date)
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: appliance.kind == .washer ? "washer.fill" : "dryer.fill")
          .font(.system(size: 18))
          .foregroundStyle(appliance.status?.isActive == true ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(appliance.name).lineLimit(1)
            Spacer(minLength: 4)
            StateBadge(text: state.badge, color: state.color)
          }
          if let detail = state.detail {
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
          }
          if let progress = appliance.status?.progress {
            ProgressView(value: progress).controlSize(.small)
          }
        }
      }
    }
  }

  private func describe(now: Date) -> (badge: String, color: Color, detail: String?) {
    guard let status = appliance.status else { return ("…", .secondary, nil) }
    switch status.state {
    case .running, .paused:
      var parts: [String] = []
      if let phase = Format.phase(status.phase) { parts.append(phase) }
      if let end = status.estimatedEnd {
        let left = end.timeIntervalSince(now)
        parts.append(left > 30 ? "mancano \(Format.remaining(left))" : "quasi finito")
        if status.state == .running { parts.append("fine \(Format.time(end))") }
      }
      if let power = status.power, power > 0 { parts.append(Format.watts(power)) }
      let running = status.state == .running
      return (running ? "In funzione" : "In pausa", running ? .blue : .orange,
              parts.isEmpty ? nil : parts.joined(separator: " · "))
    case .idle:
      if status.hasFinished { return ("Finito", .green, nil) }
      return (status.isOn == false ? "Spenta" : "Pronta", .secondary, nil)
    case .unknown:
      return ("Sconosciuto", .secondary, nil)
    }
  }
}

import AppKit
import HomeCore
import ServiceManagement
import SwiftUI

/// The settings window, with its panes as toolbar tabs like the system's own
/// settings. (A SwiftUI TabView hosted in an AppKit window draws its tabs
/// over the title bar's edge instead.)
@MainActor
enum SettingsWindow {
  static func make(home: Home) -> NSWindow {
    let tabs = NSTabViewController()
    tabs.tabStyle = .toolbar
    tabs.addTabViewItem(tab("SmartThings", "cloud", SmartThingsSettings(), home: home, height: 600))
    tabs.addTabViewItem(tab("Luci", "lightbulb", LightsSettings(), home: home, height: 300))
    tabs.addTabViewItem(tab("Generale", "gearshape", GeneralSettings(), home: home, height: 620))
    let window = NSWindow(contentViewController: tabs)
    window.styleMask = [.titled, .closable]
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    window.center()
    return window
  }

  /// The window takes the size of the selected pane.
  private static func tab<Content: View>(_ title: String, _ symbol: String, _ view: Content, home: Home,
                                         height: CGFloat) -> NSTabViewItem {
    let controller = NSHostingController(rootView: view.environment(home).frame(width: 540, height: height))
    controller.sizingOptions = .preferredContentSize
    controller.title = title
    let item = NSTabViewItem(viewController: controller)
    item.label = title
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    return item
  }
}

/// A single-line field you can see, with a Paste button: tokens and codes
/// are pasted, not typed.
private struct PasteField: View {
  let prompt: String
  var secure = false
  @Binding var text: String

  var body: some View {
    HStack(spacing: 6) {
      Group {
        if secure {
          SecureField(prompt, text: $text, prompt: Text(prompt))
        } else {
          TextField(prompt, text: $text, prompt: Text(prompt))
        }
      }
      .labelsHidden()
      .textFieldStyle(.roundedBorder)
      PasteButton(payloadType: String.self) { strings in
        let pasted = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Task { @MainActor in
          if !pasted.isEmpty { text = pasted }
        }
      }
      .labelStyle(.iconOnly)
      .help("Incolla")
    }
  }
}

private struct SmartThingsSettings: View {
  @Environment(Home.self) private var home
  @State private var summary = SmartThingsAuth.Summary()
  @State private var token = ""
  @State private var clientID = ""
  @State private var clientSecret = ""
  @State private var code = ""
  @State private var busy = false
  @State private var showOAuth = false
  @State private var feedback: (text: String, isError: Bool)?

  var body: some View {
    Form {
      if !home.cloudNeeded {
        Section {
          Label("Lavatrice e asciugatrice si leggono sulla rete di casa: SmartThings serve solo se quel collegamento smette di funzionare.",
                systemImage: "checkmark.circle")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Section {
        LabeledContent("Stato", value: statusText)
        if home.cloudNeeded, let problem {
          Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
        if summary.mode != .none || summary.clientID != nil {
          Button("Scollega SmartThings", role: .destructive) {
            run { await home.auth.disconnect() }
          }
        }
      }

      Section("Token personale (gratuito)") {
        Text("Crealo su account.smartthings.com/tokens con i permessi Dispositivi (elencare, vedere, controllare) e Luoghi (vedere). Vale 24 ore: quando scade Domotica te lo dice, e ne incolli uno nuovo.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Link("Apri account.smartthings.com/tokens", destination: URL(string: "https://account.smartthings.com/tokens")!)
        HStack {
          PasteField(prompt: "Token personale", secure: true, text: $token)
          Button("Salva") {
            let value = token
            run {
              try await home.auth.savePersonalToken(value)
              token = ""
              feedback = ("Token salvato.", false)
            }
          }
          .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
        }
      }

      Section {
        DisclosureGroup("Collegamento permanente (OAuth, a pagamento)", isExpanded: $showOAuth) {
          oauth
        }
      }

      if let feedback {
        Section {
          Text(feedback.text)
            .foregroundStyle(feedback.isError ? .red : .green)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .formStyle(.grouped)
    .task {
      summary = await home.auth.summary()
      showOAuth = summary.clientID != nil
    }
  }

  @ViewBuilder private var oauth: some View {
    Text("Domotica rinnova l'accesso da sola. Da novembre 2026 SmartThings lo permette solo con il Developer Plan, a pagamento. Con il piano attivo, crea nella SmartThings Console un'app API Access con redirect \(SmartThingsAuth.redirectURI) e permessi \(SmartThingsAuth.scopes.joined(separator: ", ")), poi incolla qui client ID e secret.")
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    Link("Apri la SmartThings Console", destination: URL(string: "https://developer.smartthings.com/console")!)
    if let id = summary.clientID {
      LabeledContent("Client ID") {
        Text(id).font(.callout.monospaced()).textSelection(.enabled)
      }
      Button("1. Autorizza nel browser") {
        run { NSWorkspace.shared.open(try await home.auth.authorizationURL()) }
      }
      Text("Accedi, scegli la casa e consenti. Si apre httpbin.org: copia il valore di \"code\" (o tutto l'indirizzo) e incollalo qui.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        PasteField(prompt: "2. Codice o indirizzo di httpbin", text: $code)
        Button("Collega") {
          let pasted = code
          run {
            try await home.auth.connect(withCode: pasted)
            code = ""
            feedback = ("Collegato: Domotica rinnoverà l'accesso da sola.", false)
          }
        }
        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
      }
      Button("Dimentica l'app OAuth") {
        run { try await home.auth.forgetClient() }
      }
    } else {
      PasteField(prompt: "Client ID", text: $clientID)
      PasteField(prompt: "Client secret", secure: true, text: $clientSecret)
      Button("Salva client ID e secret") {
        let id = clientID, secret = clientSecret
        run {
          try await home.auth.saveClient(id: id, secret: secret)
          clientID = ""
          clientSecret = ""
          feedback = ("Salvati: ora autorizza Domotica nel browser.", false)
        }
      }
      .disabled(clientID.isEmpty || clientSecret.isEmpty || busy)
    }
  }

  private var statusText: String {
    // With the appliances read on the LAN, SmartThings isn't contacted.
    if !home.cloudNeeded, summary.mode != .none {
      guard summary.mode == .personalToken, let saved = summary.personalTokenSavedAt else { return "In riserva" }
      let expiry = saved.addingTimeInterval(86_400)
      return expiry > Date() ? "In riserva · il token scade \(Format.dayAndTime(expiry))" : "In riserva · token scaduto"
    }
    switch (summary.mode, home.cloud) {
    case (.none, _):
      return "Non collegato"
    case (.oauth, .connected):
      return "Collegato, rinnovo automatico"
    case (.personalToken, .connected):
      let expiry = summary.personalTokenSavedAt.map { " (scade \(Format.dayAndTime($0.addingTimeInterval(86_400))))" }
      return "Collegato con token personale" + (expiry ?? "")
    case (_, .needsToken):
      return summary.mode == .oauth ? "Autorizzazione scaduta" : "Token scaduto"
    case (_, .failed):
      return "Errore"
    default:
      return "Collegamento in corso…"
    }
  }

  private var problem: String? {
    switch home.cloud {
    case .failed(let message), .needsToken(let message): return message
    default: return nil
    }
  }

  private func run(_ work: @escaping @MainActor () async throws -> Void) {
    busy = true
    feedback = nil
    Task {
      do {
        try await work()
      } catch {
        feedback = (error.localizedDescription, true)
      }
      summary = await home.auth.summary()
      busy = false
      home.smartThingsChanged()
    }
  }
}

private struct LightsSettings: View {
  @Environment(Home.self) private var home

  var body: some View {
    Form {
      if home.lights.isEmpty {
        Text("Nessuna luce Shelly trovata.").foregroundStyle(.secondary)
      }
      ForEach(home.lights) { device in
        Section("\(device.name) · \(device.host)") {
          ForEach(device.channels) { channel in
            Toggle(channel.name, isOn: Binding(get: { home.isVisible(device.id, channel) },
                                               set: { home.setVisible($0, device.id, channel.id) }))
          }
        }
      }
      Section {
        Text("I canali disattivati qui non compaiono nel pannello. I nomi si cambiano dall'app Shelly.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

private struct GeneralSettings: View {
  @Environment(Home.self) private var home
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var loginError: String?

  var body: some View {
    @Bindable var home = home
    Form {
      Section {
        Toggle("Avvisami quando lavatrice o asciugatrice finiscono", isOn: $home.notifyWhenDone)
        Toggle("Apri Domotica all'accesso", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
        if let loginError {
          Text(loginError).font(.callout).foregroundStyle(.red)
        }
      }
      Section("Lavatrice e asciugatrice") {
        Toggle("Leggile sulla rete di casa", isOn: $home.localEnabled)
        Text("Domotica parla direttamente con gli elettrodomestici Samsung, senza cloud né token, con un'interfaccia che Samsung non documenta e che un aggiornamento potrebbe chiudere. In quel caso torna a SmartThings.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        ForEach(home.localDevices) { device in
          LabeledContent(device.info.applianceKind == .washer ? "Lavatrice" : "Asciugatrice") {
            Text(localStatus(device)).foregroundStyle(device.problem == nil ? .secondary : Color.orange)
          }
        }
      }
      Section("Dispositivi trovati") {
        ForEach(home.lights) { LabeledContent($0.name, value: $0.host) }
        ForEach(home.plugs) { LabeledContent($0.name, value: $0.host) }
        Button("Cerca di nuovo") { home.refreshEverything() }
      }
      Section {
        LabeledContent("Versione", value: Bundle.main.shortVersion)
        Button("Mostra il registro") { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) }
      }
    }
    .formStyle(.grouped)
  }

  private func localStatus(_ device: LocalAppliances.Device) -> String {
    let model = device.info.model.map { "\($0) · " } ?? ""
    if let problem = device.problem { return "\(model)\(device.info.host) · \(problem)" }
    return "\(model)\(device.info.host) · \(device.connected ? "collegata" : "in collegamento…")"
  }

  private func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      loginError = nil
    } catch {
      loginError = error.localizedDescription
      launchAtLogin = SMAppService.mainApp.status == .enabled
    }
  }
}

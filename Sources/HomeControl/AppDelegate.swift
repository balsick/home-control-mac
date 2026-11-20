import AppKit
import HomeCore
import SwiftUI

/// The menu bar item and its windows: a popover under the icon, which can be
/// torn off (dragged away, or with the pin button) into a floating panel; and
/// the settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
  let home = Home()
  private var statusItem: NSStatusItem?
  private let popover = NSPopover()
  private var panel: FloatingPanel?
  private var settingsWindow: NSWindow?
  private var timer: Timer?
  private var terminating = false
  private static let panelOpenKey = "floatingPanelOpen"

  func applicationDidFinishLaunching(_ notification: Notification) {
    Log.info("Domotica \(Bundle.main.shortVersion) started")
    NSApp.mainMenu = Self.makeMainMenu()
    Notifier.setUp()
    Notifier.onOpen = { [weak self] kind in
      switch kind {
      case .token: self?.renewToken()
      case .cycle: self?.showDashboard()
      }
    }
    setUpStatusItem()
    setUpPopover()
    home.onAppliancesChanged = { [weak self] in self?.updateStatusItem() }
    home.start(demo: CommandLine.arguments.contains("--demo"))
    // The remaining time in the menu bar counts down between polls.
    timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateStatusItem() }
    }
    if UserDefaults.standard.bool(forKey: Self.panelOpenKey) { showPanel(near: nil) }
    runSnapshotIfRequested()
  }

  func applicationWillTerminate(_ notification: Notification) {
    terminating = true
  }

  /// A menu bar app shows no menus, but its text fields still only get ⌘V,
  /// ⌘C, ⌘A and ⌘Z through the key equivalents of the main menu.
  private static func makeMainMenu() -> NSMenu {
    let main = NSMenu()
    let app = NSMenu(title: "Domotica")
    app.addItem(withTitle: "Chiudi finestra", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    app.addItem(withTitle: "Esci da Domotica", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let edit = NSMenu(title: "Modifica")
    edit.addItem(withTitle: "Annulla", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Ripeti", action: Selector(("redo:")), keyEquivalent: "z")
      .keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "Taglia", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Incolla", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Seleziona tutto", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    for submenu in [app, edit] {
      let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
      item.submenu = submenu
      main.addItem(item)
    }
    return main
  }

  // MARK: - Status item

  private func setUpStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.image = Self.menuBarImage("house.fill")
      button.imagePosition = .imageLeading
      button.target = self
      button.action = #selector(statusItemClicked)
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      button.toolTip = "Domotica"
    }
    statusItem = item
  }

  static func menuBarImage(_ name: String) -> NSImage? {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: "Domotica")?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
    image?.isTemplate = true
    return image
  }

  @objc private func statusItemClicked() {
    if NSApp.currentEvent?.type == .rightMouseUp {
      showStatusMenu()
    } else if let panel, panel.isVisible {
      panel.orderFrontRegardless()
    } else {
      togglePopover()
    }
  }

  private func showStatusMenu() {
    let menu = NSMenu()
    let panelOpen = panel?.isVisible == true
    menu.addItem(menuItem(panelOpen ? "Riaggancia alla barra dei menu" : "Stacca in una finestra fluttuante",
                          #selector(menuTogglePanel)))
    menu.addItem(menuItem("Aggiorna", #selector(menuRefresh)))
    menu.addItem(.separator())
    menu.addItem(menuItem("Impostazioni…", #selector(menuSettings), key: ","))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Esci da Domotica", action: #selector(NSApplication.terminate(_:)),
                            keyEquivalent: "q"))
    statusItem?.menu = menu
    statusItem?.button?.performClick(nil)
    statusItem?.menu = nil
  }

  private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = self
    return item
  }

  @objc private func menuTogglePanel() {
    if panel?.isVisible == true { reattach() } else { showPanel(near: nil) }
  }

  @objc private func menuRefresh() { home.refreshEverything() }
  @objc private func menuSettings() { openSettings() }

  /// While an appliance runs, the icon becomes the appliance and shows the
  /// time left on the one that ends first.
  private func updateStatusItem() {
    guard let button = statusItem?.button else { return }
    let next = home.appliances
      .compactMap { appliance -> (Home.Appliance, Date)? in
        guard appliance.status?.state == .running, let end = appliance.status?.estimatedEnd else { return nil }
        return (appliance, end)
      }
      .min { $0.1 < $1.1 }
    if let next {
      let left = Format.remaining(next.1.timeIntervalSinceNow)
      button.image = Self.menuBarImage(next.0.kind == .washer ? "washer.fill" : "dryer.fill")
      button.title = " \(left)"
      button.toolTip = "\(next.0.name): mancano \(left)"
    } else {
      button.image = Self.menuBarImage("house.fill")
      button.title = ""
      button.toolTip = "Domotica"
    }
  }

  // MARK: - Popover and floating panel

  private func setUpPopover() {
    popover.behavior = .transient
    popover.animates = true
    popover.delegate = self
    popover.contentViewController = dashboard(.popover)
  }

  private func dashboardActions() -> DashboardActions {
    DashboardActions(
      detach: { [weak self] in self?.detach() },
      reattach: { [weak self] in self?.reattach() },
      close: { [weak self] in self?.panel?.close() },
      openSettings: { [weak self] in self?.openSettings() },
      renewToken: { [weak self] in self?.renewToken() },
      quit: { NSApp.terminate(nil) })
  }

  /// The floating panel if it's open, otherwise the popover.
  private func showDashboard() {
    if let panel, panel.isVisible {
      panel.orderFrontRegardless()
    } else if !popover.isShown {
      togglePopover()
    }
  }

  private func dashboard(_ placement: Placement) -> NSHostingController<AnyView> {
    let controller = NSHostingController(rootView: AnyView(DashboardView(placement: placement,
                                                                         actions: dashboardActions())
      .environment(home)))
    // The popover follows the content's size.
    controller.sizingOptions = .preferredContentSize
    return controller
  }

  func togglePopover() {
    guard let button = statusItem?.button else { return }
    if popover.isShown {
      popover.performClose(nil)
      return
    }
    // Left alone, the popover takes the menu bar's appearance, which follows
    // the wallpaper (dark here), while its content stays light: dark text on
    // dark glass. The system's appearance keeps the two together.
    popover.appearance = NSApp.effectiveAppearance
    NSApp.activate()
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
  }

  func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

  /// Dragging the popover away turns it into the floating panel.
  func detachableWindow(for popover: NSPopover) -> NSWindow? {
    let panel = self.panel ?? makePanel()
    panelDidOpen()
    return panel
  }

  func popoverDidShow(_ notification: Notification) { home.visible = true }
  func popoverDidClose(_ notification: Notification) { home.visible = panel?.isVisible == true }

  private func makePanel() -> FloatingPanel {
    let panel = FloatingPanel()
    panel.setContent(DashboardView(placement: .panel, actions: dashboardActions()).environment(home))
    panel.delegate = self
    self.panel = panel
    return panel
  }

  /// The pin button: the panel opens where the popover was.
  private func detach() {
    let frame = popover.contentViewController?.view.window?.frame
    popover.close()
    showPanel(near: frame)
  }

  func showPanel(near frame: NSRect?) {
    let panel = self.panel ?? makePanel()
    if let frame {
      panel.setFrameTopLeftPoint(NSPoint(x: frame.minX, y: frame.maxY))
    } else if !panel.restoredFrame, let button = statusItem?.button, let window = button.window {
      let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
      panel.setFrameTopLeftPoint(NSPoint(x: anchor.midX - panel.frame.width / 2, y: anchor.minY - 6))
    }
    panel.orderFrontRegardless()
    panelDidOpen()
  }

  private func panelDidOpen() {
    UserDefaults.standard.set(true, forKey: Self.panelOpenKey)
    home.visible = true
  }

  /// Closes the panel and opens the popover again, so it's clear where it went.
  private func reattach() {
    panel?.close()
    togglePopover()
  }

  func windowWillClose(_ notification: Notification) {
    guard !terminating, let window = notification.object as? NSWindow, window === panel else { return }
    UserDefaults.standard.set(false, forKey: Self.panelOpenKey)
    home.visible = popover.isShown
  }

  // MARK: - Settings

  /// `tab`: 0 SmartThings, 1 Luci, 2 Generale.
  func openSettings(tab: Int? = nil) {
    // close(), not performClose(): the latter is ignored when it comes from
    // the gear menu inside the popover itself.
    popover.close()
    home.visible = panel?.isVisible == true
    if settingsWindow == nil { settingsWindow = SettingsWindow.make(home: home) }
    if let tab { (settingsWindow?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = tab }
    NSApp.activate()
    settingsWindow?.makeKeyAndOrderFront(nil)
  }

  /// The daily chore with a personal token: SmartThings' page to make a new
  /// one, and the settings to paste it into.
  func renewToken() {
    openSettings(tab: 0)
    NSWorkspace.shared.open(URL(string: "https://account.smartthings.com/tokens")!)
  }

  // MARK: - Development snapshots

  /// `--snapshot <png> [--target panel|popover|settings|statusitem] [--tab <n>] [--delay <s>]
  /// [--appearance dark]`: opens that window (for settings, on tab n), waits, saves it as a
  /// PNG and quits.
  private func runSnapshotIfRequested() {
    let arguments = CommandLine.arguments
    func value(_ flag: String) -> String? {
      guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
      return arguments[index + 1]
    }
    guard let path = value("--snapshot") else { return }
    if value("--appearance") == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
    let target = value("--target") ?? "panel"
    let delay = value("--delay").flatMap(Double.init) ?? 8
    Task {
      try? await Task.sleep(for: .milliseconds(500))
      switch target {
      case "popover": togglePopover()
      case "settings":
        openSettings(tab: value("--tab").flatMap(Int.init))
      case "statusitem": break
      default: showPanel(near: nil)
      }
      try? await Task.sleep(for: .seconds(delay))
      if target == "statusitem" {
        // The system draws the menu bar: capture that part of the screen.
        if let button = statusItem?.button, let window = button.window {
          let rect = window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: -60, dy: -3)
          let top = (NSScreen.screens.first?.frame.height ?? 0) - rect.maxY
          Self.screencapture(["-R", "\(Int(rect.minX)),\(Int(top)),\(Int(rect.width)),\(Int(rect.height))", path])
        }
      } else {
        let window: NSWindow? = switch target {
        case "popover": popover.contentViewController?.view.window
        case "settings": settingsWindow
        default: panel
        }
        if let window { Self.writePNG(of: window, to: path) }
      }
      NSApp.terminate(nil)
    }
  }

  private static func screencapture(_ arguments: [String]) {
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x"] + arguments
    try? capture.run()
    capture.waitUntilExit()
  }

  /// With screencapture when the screen may be recorded (materials and
  /// shadows as on screen), otherwise by drawing the window's views.
  private static func writePNG(of window: NSWindow, to path: String) {
    try? FileManager.default.removeItem(atPath: path)
    screencapture(["-l", String(window.windowNumber), path])
    if !FileManager.default.fileExists(atPath: path),
       let view = window.contentView?.superview ?? window.contentView,
       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
      view.cacheDisplay(in: view.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    Log.info("snapshot \(path): \(Int(window.frame.width))x\(Int(window.frame.height)), window \(window.windowNumber)")
  }
}

/// The dashboard torn off the menu bar: above other windows, on every Space,
/// and it doesn't take the focus away from the app you're using. Borderless,
/// with the popover's material and its own close button; it moves by its
/// header. Its size follows the SwiftUI content's constraints. (A title bar
/// would make that loop: its safe area changes with the window's size.)
final class FloatingPanel: NSPanel {
  private(set) var restoredFrame = false
  private var resizeObserver: NSObjectProtocol?

  init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 320),
               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    title = "Domotica"
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isMovableByWindowBackground = true
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    restoredFrame = setFrameUsingName("FloatingPanel")
    setFrameAutosaveName("FloatingPanel")
    // The shadow follows the rounded content only when recomputed.
    resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self,
                                                            queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.invalidateShadow() }
    }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  func setContent<Content: View>(_ view: Content) {
    contentView = NSHostingView(rootView: view)
  }
}

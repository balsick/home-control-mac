import AppKit

// `--probe` prints what the app finds on the network and in SmartThings, then
// exits: the same code as the app, without the UI.
if CommandLine.arguments.contains("--probe") {
  Task.detached {
    await Probe.run()
    exit(0)
  }
  dispatchMain()
}

MainActor.assumeIsolated {
  let delegate = AppDelegate()
  let app = NSApplication.shared
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  app.run()
}

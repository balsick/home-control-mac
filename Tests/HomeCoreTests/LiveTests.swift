import XCTest
@testable import HomeCore

/// Against the real devices on the network: they switch a light channel and
/// the plug for a couple of seconds, then put them back as they were.
///
///   HOMECONTROL_LIVE=1 swift test --filter LiveTests
///
/// HOMECONTROL_LIVE_CHANNEL picks the Shelly channel (default 2).
final class LiveTests: XCTestCase {
  override func setUpWithError() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["HOMECONTROL_LIVE"] == "1",
                      "set HOMECONTROL_LIVE=1 to switch real devices")
  }

  func testShellyChannelOnAndBack() async throws {
    let hosts = await ShellyDiscovery.discover()
    let host = try XCTUnwrap(hosts.first, "no Shelly found")
    let client = ShellyClient(host: host)
    let id = Int(ProcessInfo.processInfo.environment["HOMECONTROL_LIVE_CHANNEL"] ?? "") ?? 2
    let before = try await light(id, client)

    try await client.setLight(id: id, on: true, brightness: 30, transition: 0.5)
    try await Task.sleep(for: .seconds(2))
    let during = try await light(id, client)

    try await client.setLight(id: id, on: before.isOn, brightness: before.brightness, transition: 0.5)
    try await Task.sleep(for: .seconds(1.5))
    let after = try await light(id, client)

    XCTAssertTrue(during.isOn)
    XCTAssertEqual(during.brightness, 30)
    XCTAssertEqual(after.isOn, before.isOn)
    XCTAssertEqual(after.brightness, before.brightness)
    print("Shelly light:\(id) at \(host): \(before.isOn ? "on" : "off") \(before.brightness)% → on 30% "
          + "(\(during.power ?? 0) W) → \(after.isOn ? "on" : "off") \(after.brightness)%")
  }

  func testKasaRelayOnAndBack() async throws {
    let plugs = await KasaDiscovery.discover()
    let plug = try XCTUnwrap(plugs.first, "no Kasa plug found")
    let client = KasaClient(host: plug.host)
    let before = try await client.sysInfo()

    try await client.setRelay(on: !before.isOn)
    try await Task.sleep(for: .seconds(2))
    let during = try await client.sysInfo()

    try await client.setRelay(on: before.isOn)
    try await Task.sleep(for: .seconds(1))
    let after = try await client.sysInfo()

    XCTAssertEqual(during.isOn, !before.isOn)
    XCTAssertEqual(after.isOn, before.isOn)
    print("Kasa \(before.alias) at \(plug.host): \(before.isOn ? "on" : "off") → \(during.isOn ? "on" : "off") "
          + "→ \(after.isOn ? "on" : "off")")
  }

  private func light(_ id: Int, _ client: ShellyClient) async throws -> ShellyLight {
    let lights = try await client.status().lights
    return try XCTUnwrap(lights.first { $0.id == id }, "no light:\(id)")
  }
}

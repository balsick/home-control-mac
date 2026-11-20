import XCTest
@testable import HomeCore

final class KasaTests: XCTestCase {
  func testCodecRoundTrip() {
    let plain = Data(#"{"system":{"get_sysinfo":{}}}"#.utf8)
    let cipher = KasaCodec.encrypt(plain)
    XCTAssertNotEqual(cipher, plain)
    XCTAssertEqual(KasaCodec.decrypt(cipher), plain)
    // 171 ^ "{" (0x7B): every Kasa message starts with 0xD0.
    XCTAssertEqual(cipher.first, 0xD0)
  }

  func testFrameHasBigEndianLength() {
    let frame = KasaCodec.frame(Data(repeating: 0x41, count: 300))
    XCTAssertEqual(Array(frame.prefix(4)), [0, 0, 1, 44])
    XCTAssertEqual(frame.count, 304)
  }

  /// The HS100 on the home network, 2026-11-18.
  func testSysInfoReply() throws {
    let reply = #"""
    {"system":{"get_sysinfo":{"sw_ver":"1.5.6 Build 191125 Rel.083657","hw_ver":"2.0","type":"IOT.SMARTPLUGSWITCH",
    "model":"HS100(EU)","mac":"02:00:00:00:00:01","dev_name":"Smart Wi-Fi Plug","alias":"Lucine","relay_state":0,
    "on_time":0,"active_mode":"schedule","feature":"TIM","updating":0,"icon_hash":"","rssi":-55,"led_off":0,
    "longitude_i":0,"latitude_i":0,"hwId":"00000000000000000000000000000000","fwId":"00000000000000000000000000000000",
    "deviceId":"8006000000000000000000000000000000000000","oemId":"00000000000000000000000000000000",
    "next_action":{"type":1,"id":"00000000000000000000000000000001","schd_sec":61020,"action":1},"err_code":0}}}
    """#
    let info = try KasaSysInfo.fromReply(Data(reply.utf8))
    XCTAssertEqual(info.alias, "Lucine")
    XCTAssertEqual(info.model, "HS100(EU)")
    XCTAssertFalse(info.isOn)
    XCTAssertEqual(info.nextAction, .init(type: 1, secondsOfDay: 61020, action: 1))
  }

  func testNoScheduleDecodes() throws {
    let reply = #"{"system":{"get_sysinfo":{"alias":"x","model":"HS100(EU)","mac":"m","deviceId":"d","relay_state":1,"next_action":{"type":-1}}}}"#
    let info = try KasaSysInfo.fromReply(Data(reply.utf8))
    XCTAssertTrue(info.isOn)
    XCTAssertEqual(info.nextAction?.type, -1)
    XCTAssertNil(info.nextAction?.secondsOfDay)
  }
}

final class ShellyTests: XCTestCase {
  /// Trimmed from the Plus RGBW PM on the home network, 2026-11-18.
  let status = #"""
  {"ble":{},"cloud":{"connected":true},"input:0":{"id":0,"state":null},
  "light:0":{"id":0,"source":"SHC","output":false,"brightness":10,"temperature":{"tC":43.4,"tF":110.1},"apower":0.0,"current":0.0,"voltage":24.4},
  "light:1":{"id":1,"source":"SHC","output":false,"brightness":5,"temperature":{"tC":43.4,"tF":110.1},"apower":0.0,"current":0.0,"voltage":24.4},
  "light:2":{"id":2,"source":"SHC","output":true,"brightness":100,"temperature":{"tC":43.4,"tF":110.1},"apower":7.3,"current":0.3,"voltage":24.4},
  "light:3":{"id":3,"source":"SHC","output":false,"brightness":100,"temperature":{"tC":43.4,"tF":110.1},"apower":0.0,"current":0.0,"voltage":24.4},
  "sys":{"mac":"02000000AA01","available_updates":{"stable":{"version":"2.0.3"}}}}
  """#

  let config = #"""
  {"light:0":{"id":0,"name":"Disconnessa","initial_state":"off"},"light:1":{"id":1,"name":"Sullo spazio"},
  "light:2":{"id":2,"name":"Sul divano"},"light:3":{"id":3,"name":"Sui libri"},
  "sys":{"device":{"name":"Shelly","mac":"02000000AA01","profile":"light"}}}
  """#

  func testStatus() throws {
    let decoded = try JSONDecoder().decode(ShellyStatus.self, from: Data(status.utf8))
    XCTAssertEqual(decoded.lights.map(\.id), [0, 1, 2, 3])
    XCTAssertEqual(decoded.lights[1].brightness, 5)
    XCTAssertTrue(decoded.lights[2].isOn)
    XCTAssertEqual(decoded.lights[2].power, 7.3)
    XCTAssertEqual(decoded.availableUpdate, "2.0.3")
  }

  func testConfigNames() throws {
    let decoded = try JSONDecoder().decode(ShellyConfig.self, from: Data(config.utf8))
    XCTAssertEqual(decoded.lightNames, [0: "Disconnessa", 1: "Sullo spazio", 2: "Sul divano", 3: "Sui libri"])
    XCTAssertEqual(decoded.deviceName, "Shelly")
  }

  func testInfo() throws {
    let reply = #"{"name":"Shelly","id":"shellyplusrgbwpm-02000000aa01","mac":"02000000AA01","slot":1,"model":"SNDC-0D4P10WW","gen":2,"fw_id":"20241011-114446/1.4.4-g6d2a586","ver":"1.4.4","app":"PlusRGBWPM","auth_en":false,"auth_domain":null,"profile":"light"}"#
    let info = try JSONDecoder().decode(ShellyInfo.self, from: Data(reply.utf8))
    XCTAssertEqual(info.generation, 2)
    XCTAssertEqual(info.profile, "light")
  }

  func testGen1InfoIsRejected() {
    let reply = #"{"type":"SHRGBW2","mac":"AABBCCDDEEFF","auth":false,"fw":"20230913-112003/v1.14.0-gcb84623"}"#
    XCTAssertThrowsError(try JSONDecoder().decode(ShellyInfo.self, from: Data(reply.utf8)))
  }
}

final class ApplianceTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_794_992_638)

  private func parse(_ json: String, _ kind: ApplianceKind) throws -> ApplianceStatus {
    ApplianceStatus(parsing: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)), kind: kind, now: now)
  }

  func testSamsungWasherRunning() throws {
    let status = try parse(#"""
    {"components":{"main":{
      "switch":{"switch":{"value":"on"}},
      "remoteControlStatus":{"remoteControlEnabled":{"value":"true"}},
      "samsungce.washerOperatingState":{"operatingState":{"value":"running"},"washerJobState":{"value":"rinse"},
        "remainingTime":{"value":42,"unit":"min"},"progress":{"value":63,"unit":"%"}},
      "washerOperatingState":{"machineState":{"value":"run"},"washerJobState":{"value":"rinse"},
        "completionTime":{"value":"2026-11-18T10:45:00Z"}}}}}
    """#, .washer)
    XCTAssertEqual(status.state, .running)
    XCTAssertEqual(status.phase, "rinse")
    XCTAssertEqual(status.estimatedEnd, now.addingTimeInterval(42 * 60))
    XCTAssertEqual(status.progress ?? 0, 0.63, accuracy: 0.001)
    XCTAssertEqual(status.isOn, true)
    XCTAssertEqual(status.remoteControl, true)
  }

  func testStandardDryerOnly() throws {
    let end = "2026-11-18T11:30:00.000Z"
    let status = try parse(#"""
    {"components":{"main":{"dryerOperatingState":{"machineState":{"value":"run"},"dryerJobState":{"value":"drying"},
      "completionTime":{"value":"\#(end)"}}}}}
    """#, .dryer)
    XCTAssertEqual(status.state, .running)
    XCTAssertEqual(status.phase, "drying")
    XCTAssertEqual(status.estimatedEnd, ApplianceStatus.date(end))
    XCTAssertNil(status.progress)
  }

  func testIdleWasherHasNoEnd() throws {
    let status = try parse(#"""
    {"components":{"main":{"switch":{"switch":{"value":"off"}},
      "washerOperatingState":{"machineState":{"value":"stop"},"washerJobState":{"value":"none"},
        "completionTime":{"value":"2026-11-18T08:00:00Z"}}}}}
    """#, .washer)
    XCTAssertEqual(status.state, .idle)
    XCTAssertNil(status.phase)
    XCTAssertNil(status.estimatedEnd)
    XCTAssertEqual(status.isOn, false)
    XCTAssertFalse(status.isActive)
  }

  /// Trimmed from the real washer and dryer, idle, 2026-11-18: the Samsung
  /// capability still holds the cycle of three days before.
  func testRealIdleWasherAndDryer() throws {
    let washer = try parse(#"""
    {"components":{"main":{"samsungce.washerOperatingState":{"washerJobState":{"value":"none","timestamp":"2026-11-15T19:08:19.180Z"},"operatingState":{"value":"ready","timestamp":"2026-11-15T19:08:19.180Z"},"progress":{"value":1,"unit":"%","timestamp":"2026-11-15T19:08:19.180Z"},"operationTime":{"value":163,"unit":"min","timestamp":"2026-11-15T19:08:18.982Z"},"remainingTime":{"value":163,"unit":"min","timestamp":"2026-11-15T19:08:19.180Z"}},"washerOperatingState":{"completionTime":{"value":"2026-11-18T07:23:54Z","timestamp":"2026-11-18T04:40:54.348Z"},"machineState":{"value":"stop","timestamp":"2026-11-18T04:40:54.348Z"},"washerJobState":{"value":"none","timestamp":"2026-11-18T04:40:54.348Z"}},"switch":{"switch":{"value":"off","timestamp":"2026-11-18T04:40:54.347Z"}},"remoteControlStatus":{"remoteControlEnabled":{"value":"false","timestamp":"2026-11-18T04:40:54.349Z"}}}}}
    """#, .washer)
    XCTAssertEqual(washer.state, .idle)
    XCTAssertNil(washer.estimatedEnd)
    XCTAssertNil(washer.progress)
    XCTAssertEqual(washer.isOn, false)
    XCTAssertEqual(washer.remoteControl, false)

    let dryer = try parse(#"""
    {"components":{"main":{"samsungce.dryerOperatingState":{"operatingState":{"value":"ready","timestamp":"2026-11-15T21:44:26.286Z"},"progress":{"value":1,"unit":"%","timestamp":"2026-11-15T21:44:26.286Z"},"dryerJobState":{"value":"none","timestamp":"2026-11-15T21:44:29.492Z"},"remainingTime":{"value":200,"unit":"min","timestamp":"2026-11-15T21:44:26.286Z"}},"dryerOperatingState":{"completionTime":{"value":"2026-11-18T08:00:54Z","timestamp":"2026-11-18T04:40:54.558Z"},"machineState":{"value":"stop","timestamp":"2026-11-18T04:40:54.558Z"},"dryerJobState":{"value":"none","timestamp":"2026-11-18T04:40:54.558Z"}},"switch":{"switch":{"value":"off","timestamp":"2026-11-18T04:40:54.555Z"}}}}}
    """#, .dryer)
    XCTAssertEqual(dryer.state, .idle)
    XCTAssertNil(dryer.estimatedEnd)
  }

  /// A frozen "running" from the Samsung capability must not outlive the
  /// standard one saying the cycle stopped, and its numbers aren't used.
  func testStaleSamsungStateLoses() throws {
    let status = try parse(#"""
    {"components":{"main":{
      "samsungce.washerOperatingState":{"operatingState":{"value":"running","timestamp":"2026-11-15T17:00:00Z"},
        "washerJobState":{"value":"wash","timestamp":"2026-11-15T17:00:00Z"},"remainingTime":{"value":80,"unit":"min","timestamp":"2026-11-15T17:00:00Z"}},
      "washerOperatingState":{"machineState":{"value":"stop","timestamp":"2026-11-18T04:40:54Z"},
        "washerJobState":{"value":"none","timestamp":"2026-11-18T04:40:54Z"}}}}}
    """#, .washer)
    XCTAssertEqual(status.state, .idle)
    XCTAssertNil(status.phase)
    XCTAssertNil(status.estimatedEnd)
  }

  func testFreshStandardRunUsesCompletionTime() throws {
    let status = try parse(#"""
    {"components":{"main":{
      "samsungce.washerOperatingState":{"operatingState":{"value":"ready","timestamp":"2026-11-15T19:08:19Z"},
        "remainingTime":{"value":163,"unit":"min","timestamp":"2026-11-15T19:08:19Z"}},
      "washerOperatingState":{"machineState":{"value":"run","timestamp":"2026-11-18T08:10:00Z"},
        "washerJobState":{"value":"rinse","timestamp":"2026-11-18T08:55:00Z"},
        "completionTime":{"value":"2026-11-18T09:40:00Z","timestamp":"2026-11-18T08:55:00Z"}}}}}
    """#, .washer)
    XCTAssertEqual(status.state, .running)
    XCTAssertEqual(status.phase, "rinse")
    XCTAssertEqual(status.estimatedEnd, ApplianceStatus.date("2026-11-18T09:40:00Z"))
  }

  func testDeviceKind() throws {
    let json = #"""
    {"items":[
      {"deviceId":"1","label":"Lavatrice","components":[{"id":"main","capabilities":[{"id":"washerOperatingState","version":1}]}]},
      {"deviceId":"2","label":"Asciugatrice","ocf":{"ocfDeviceType":"oic.d.dryer"},"components":[]},
      {"deviceId":"3","label":"TV","components":[{"id":"main","capabilities":[{"id":"switch","version":1}]}]}]}
    """#
    struct Page: Decodable { let items: [STDevice] }
    let devices = try JSONDecoder().decode(Page.self, from: Data(json.utf8)).items
    XCTAssertEqual(devices.map(\.applianceKind), [.washer, .dryer, nil])
  }
}

final class AuthTests: XCTestCase {
  func testExtractCode() {
    XCTAssertEqual(SmartThingsAuth.extractCode(" Ab3dE9 "), "Ab3dE9")
    XCTAssertEqual(SmartThingsAuth.extractCode("https://httpbin.org/get?code=Ab3dE9"), "Ab3dE9")
    XCTAssertEqual(SmartThingsAuth.extractCode(#"{"args": {"code": "Ab3dE9"}, "headers": {}}"#), "Ab3dE9")
    XCTAssertNil(SmartThingsAuth.extractCode("not a code at all"))
    XCTAssertNil(SmartThingsAuth.extractCode(""))
  }
}

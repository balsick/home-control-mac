import Security
import XCTest
@testable import HomeCore

final class CBORTests: XCTestCase {
  private func hex(_ text: String) -> Data {
    Data(stride(from: 0, to: text.count, by: 2).map {
      UInt8(text[text.index(text.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
    })
  }

  /// `/oic/d` of the washer (indefinite-length map), its device ID replaced.
  func testDeviceInfo() throws {
    let json = try CBOR.decode(hex("bf62727482686f69632e776b2e646c6f69632e642e776173686572626966826f6f69632e69662e626173656c696e65686f69632e69662e72626469782430303030303030302d313131312d343232322d383333332d343434343434343434343434646d6e6d636e575739304347433034444145455463646d76727265732e312e312e302c73682e312e312e30636963766a636f72652e312e312e30616e705b7761736865725d2053616d73756e67ff"))
    let info = try XCTUnwrap(OCFDeviceInfo(host: "192.0.2.15", json: json))
    XCTAssertEqual(info.deviceID, "00000000-1111-4222-8333-444444444444")
    XCTAssertEqual(info.types, ["oic.wk.d", "oic.d.washer"])
    XCTAssertEqual(info.applianceKind, .washer)
    XCTAssertEqual(info.model, "WW90CGC04DAEET")
    XCTAssertEqual(info.name, "[washer] Samsung")
  }

  /// `/operational/state/0` of the idle washer.
  func testIdleOperationalState() throws {
    let json = try CBOR.decode(hex("bf7363757272656e744d616368696e6553746174656469646c656d6d616368696e6553746174657383657061757365666163746976656469646c65696a6f6253746174657386644e6f6e656d57656967687473656e73696e6764576173686552696e7365645370696e6646696e6973686f63757272656e744a6f625374617465644e6f6e656d72656d61696e696e6754696d656830323a34333a30307270726f677265737350657263656e746167656131ff"))
    XCTAssertEqual(json["currentMachineState"]?.string, "idle")
    XCTAssertEqual(json["jobStates"]?.array?.count, 6)
    let status = ApplianceStatus(localState: json, power: .object(["value": .bool(false)]))
    XCTAssertEqual(status.state, .idle)
    XCTAssertNil(status.phase)
    XCTAssertNil(status.estimatedEnd)  // 02:43 is the next cycle's length, not a countdown
    XCTAssertEqual(status.isOn, false)
  }

  func testScalars() throws {
    XCTAssertEqual(try CBOR.decode(Data([0x18, 0x64])), .number(100))
    XCTAssertEqual(try CBOR.decode(Data([0x38, 0x63])), .number(-100))
    XCTAssertEqual(try CBOR.decode(Data([0xF5])), .bool(true))
    XCTAssertEqual(try CBOR.decode(Data([0xF9, 0x3C, 0x00])), .number(1))  // half-float 1.0
    XCTAssertEqual(try CBOR.decode(Data([0x82, 0x01, 0x62, 0x68, 0x69])), .array([.number(1), .string("hi")]))
    XCTAssertThrowsError(try CBOR.decode(Data([0x82, 0x01])))
  }
}

final class CoAPTests: XCTestCase {
  func testGetEncoding() {
    let message = CoAPMessage.get("/operational/state/0", messageID: 0x1234, token: Data([1, 2, 3, 4]), observe: 0)
    let bytes = [UInt8](message.encoded())
    XCTAssertEqual(Array(bytes.prefix(8)), [0x44, 0x01, 0x12, 0x34, 1, 2, 3, 4])
    // Observe (6) first, empty for 0; then the path, in order.
    XCTAssertEqual(bytes[8], 0x60)
    XCTAssertEqual(bytes[9], 0x5B)  // delta 5 to Uri-Path 11, length 11
    XCTAssertEqual(String(decoding: bytes[10..<21], as: UTF8.self), "operational")
    XCTAssertEqual(CoAPMessage.decode(message.encoded()), message)
  }

  func testBlockAndQueryRoundTrip() {
    let message = CoAPMessage.get("/oic/res", query: ["rt=oic.r.doxm"], messageID: 7, token: Data([9]), block2: 2)
    let decoded = CoAPMessage.decode(message.encoded())
    XCTAssertEqual(decoded?.values(CoAPMessage.OptionNumber.uriPath).map { String(decoding: $0, as: UTF8.self) },
                   ["oic", "res"])
    XCTAssertEqual(decoded?.values(CoAPMessage.OptionNumber.uriQuery).first.map { String(decoding: $0, as: UTF8.self) },
                   "rt=oic.r.doxm")
    XCTAssertEqual(CoAPOption(0, decoded!.values(CoAPMessage.OptionNumber.block2)[0]).uint, 2 << 4 | 6)
  }

  /// A 2.05 as the washer sends it: separate, confirmable, more blocks.
  func testResponseWithBlock2() {
    var response = CoAPMessage(kind: .confirmable, code: 0x45, messageID: 99, token: Data([1, 2, 3, 4]),
                               options: [CoAPOption(12, uint: 60), CoAPOption(23, uint: 0x0E)], payload: Data([0xA0]))
    response = CoAPMessage.decode(response.encoded())!
    XCTAssertEqual(response.codeDescription, "2.05")
    XCTAssertTrue(response.isSuccess)
    XCTAssertEqual(response.block2?.number, 0)
    XCTAssertEqual(response.block2?.more, true)
    XCTAssertEqual(response.payload, Data([0xA0]))
    XCTAssertEqual(CoAPMessage.emptyAck(99).encoded(), Data([0x60, 0x00, 0x00, 0x63]))
  }
}

final class OCFIdentityTests: XCTestCase {
  /// The certificate parses, carries the service UUID, and is signed by its key.
  func testSelfSignedCertificate() throws {
    var error: Unmanaged<CFError>?
    let key = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                                                   kSecAttrKeySizeInBits: 256] as CFDictionary, &error))
    let der = try OCFIdentity.selfSignedCertificate(key: key)
    XCTAssertLessThan(der.count, 800)  // one datagram, with room to spare
    let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
    XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, "urn:uuid:\(OCFIdentity.serviceUUID)")
    let publicKey = try XCTUnwrap(SecCertificateCopyKey(certificate))
    XCTAssertEqual(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
                   SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil) as Data?)
  }
}

final class LocalStateTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_795_000_000)

  private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }

  /// The running washer, 2026-11-20, from `/operational/state/0`.
  func testRunningWasher() throws {
    let status = ApplianceStatus(localState: try json(#"""
      {"currentMachineState": "active", "machineStates": ["pause", "active", "idle"],
       "jobStates": ["None", "Weightsensing", "Wash", "Rinse", "Spin", "Finish"],
       "currentJobState": "Spin", "remainingTime": "00:11:00", "progressPercentage": "82"}
      """#), power: try json(#"{"value": true}"#), now: now)
    XCTAssertEqual(status.state, .running)
    XCTAssertEqual(status.phase, "Spin")
    XCTAssertEqual(status.estimatedEnd, now.addingTimeInterval(11 * 60))
    XCTAssertEqual(status.progress ?? 0, 0.82, accuracy: 0.001)
    XCTAssertEqual(status.isOn, true)
  }

  /// The same moment from Samsung's `/operational/state/vs/0`.
  func testRunningWasherSamsungResource() throws {
    let status = ApplianceStatus(samsungState: try json(#"""
      {"x.com.samsung.da.state": "Run", "x.com.samsung.da.remainingTime": "00:11:00",
       "x.com.samsung.da.progressPercentage": "82", "x.com.samsung.da.progress": "Spin",
       "x.com.samsung.da.delayEndTime": "00:00:00"}
      """#), now: now)
    XCTAssertEqual(status.state, .running)
    XCTAssertEqual(status.phase, "Spin")
    XCTAssertEqual(status.estimatedEnd, now.addingTimeInterval(11 * 60))
  }

  func testFinishedCycle() throws {
    let status = ApplianceStatus(localState: try json(#"""
      {"currentMachineState": "idle", "currentJobState": "Finish", "remainingTime": "00:00:00", "progressPercentage": "100"}
      """#), now: now)
    XCTAssertEqual(status.state, .idle)
    XCTAssertTrue(status.hasFinished)
    XCTAssertNil(status.progress)
  }
}

final class NetworkFingerprintTests: XCTestCase {
  func testMACNormalization() {
    XCTAssertEqual(NetworkFingerprint.normalized("0:1B:63:a:4c:FF"), "00:1b:63:0a:4c:ff")
  }
}

//
//  DigitalControlerTests.swift
//  DigitalControlerTests
//

import XCTest
@testable import DigitalControler

@MainActor
final class DigitalControlerTests: XCTestCase {

    func testMessageRoundTrip() {
        let m = Message(kind: .move, dx: -3.5, dy: 120.25)
        XCTAssertEqual(m.data.count, Message.size)
        XCTAssertEqual(Message(m.data), m)
        for kind in Message.Kind.allCases {
            XCTAssertEqual(Message(Message(kind: kind).data)?.kind, kind)
        }
    }

    func testMessageRejectsGarbage() {
        XCTAssertNil(Message(Data([0, 1, 2])))                                 // wrong size
        XCTAssertNil(Message(Data([99] + [UInt8](repeating: 0, count: 8))))    // unknown kind
        var nan = Message(kind: .move).data
        nan.replaceSubrange(1..<5, with: withUnsafeBytes(of: Float.nan.bitPattern.littleEndian, Array.init))
        XCTAssertNil(Message(nan))                                             // non-finite delta
        XCTAssertNil(Message(Message(kind: .scroll, dx: 1e9).data))            // absurd value
    }

    func testDownstreamFraming() {
        let packet = Downstream.frame.packet(Data([1, 2, 3]))
        let header = Downstream.header(packet.prefix(Downstream.headerSize))
        XCTAssertEqual(header?.kind, .frame)
        XCTAssertEqual(header?.length, 3)
        XCTAssertEqual(packet.dropFirst(Downstream.headerSize), Data([1, 2, 3]))
        let future = Downstream.header(Data([99, 2, 0, 0, 0]))              // kind from a newer Mac helper
        XCTAssertNotNil(future)
        XCTAssertNil(future?.kind)                                          // unknown, so skipped...
        XCTAssertEqual(future?.length, 2)                                   // ...by its length
        XCTAssertNil(Downstream.header(Data([1, 255, 255, 255, 255])))    // absurd length
    }

    func testParameterSetsRoundTrip() {
        let sets = [Data([0x67, 1, 2, 3]), Data([0x68, 9])]
        XCTAssertEqual(ParameterSets.decode(ParameterSets.encode(sets)), sets)
        XCTAssertNil(ParameterSets.decode(Data([2, 5, 0, 1])))   // says 5 bytes, has 1
        XCTAssertNil(ParameterSets.decode(Data()))               // empty
    }

    func testPairingCodeRoundTrip() {
        let code = PairingCode(name: "Jua's MacBook Pro", secret: PairingCode.newSecret(), host: "192.168.1.9")
        XCTAssertEqual(PairingCode(url: code.url), code)
        XCTAssertEqual(code.secret.count, 43)                                                  // 256 bits, base64url
        XCTAssertNotEqual(PairingCode.newSecret(), PairingCode.newSecret())
        XCTAssertNil(PairingCode(url: URL(string: "https://pair?name=Mac&secret=\(code.secret)")!))  // wrong scheme
        XCTAssertNil(PairingCode(url: URL(string: "digitalcontroler://pair?name=Mac&secret=123456")!)) // a PIN is too short
        XCTAssertNil(PairingCode(url: URL(string: "digitalcontroler://pair?secret=\(code.secret)")!))  // no name
    }

    func testPairingSecretsRoundTrip() {
        let mac = "Test Mac \(UUID())"
        XCTAssertNil(PairingSecrets.get(for: mac))
        PairingSecrets.set("first", for: mac)
        PairingSecrets.set("second", for: mac)   // replaces, doesn't duplicate
        XCTAssertEqual(PairingSecrets.get(for: mac), "second")
        UserDefaults.standard.set("legacy", forKey: "secret." + mac + "2")
        XCTAssertEqual(PairingSecrets.get(for: mac + "2"), "legacy")               // migrated from UserDefaults...
        XCTAssertNil(UserDefaults.standard.string(forKey: "secret." + mac + "2")) // ...and removed there
    }

    func testGainGrowsWithSpeedAndIsCapped() {
        XCTAssertLessThan(TouchpadView.gain(speed: 0), TouchpadView.gain(speed: 800))
        XCTAssertEqual(TouchpadView.gain(speed: 1500), TouchpadView.gain(speed: 10_000))
    }
}

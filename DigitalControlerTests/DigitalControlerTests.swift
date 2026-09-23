//
//  DigitalControlerTests.swift
//  DigitalControlerTests
//
//  Created by Jua on 23/09/26.
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
        XCTAssertEqual(header?.0, .frame)
        XCTAssertEqual(header?.1, 3)
        XCTAssertEqual(packet.dropFirst(Downstream.headerSize), Data([1, 2, 3]))
        XCTAssertNil(Downstream.header(Data([9, 0, 0, 0, 0])))            // unknown kind
        XCTAssertNil(Downstream.header(Data([1, 255, 255, 255, 255])))    // absurd length
    }

    func testGainGrowsWithSpeedAndIsCapped() {
        XCTAssertLessThan(TouchpadView.gain(speed: 0), TouchpadView.gain(speed: 800))
        XCTAssertEqual(TouchpadView.gain(speed: 1500), TouchpadView.gain(speed: 10_000))
    }
}

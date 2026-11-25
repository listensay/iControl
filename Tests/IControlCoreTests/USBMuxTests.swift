import TestSupport
import Foundation
@testable import IControlCore

final class USBMuxTests: TestCase {
    func testFragmentedDeviceListExcludesNetworkAndMalformedEntries() throws {
        let server = try FakeMux { request, socket in
            XCTAssertEqual(request["MessageType"] as? String, "ListDevices")
            try FakeMux.reply(["DeviceList": [
                ["DeviceID": 7, "Properties": ["ConnectionType": "USB", "SerialNumber": "test-ipad"]],
                ["DeviceID": 8, "Properties": ["ConnectionType": "Network", "SerialNumber": "wireless-peer"]],
                ["DeviceID": 9, "Properties": ["ConnectionType": "USB"]]
            ]], to: socket, fragmented: true)
        }
        defer { server.stop() }
        XCTAssertEqual(try server.mux.devices(), [USBDevice(deviceID: 7, udid: "test-ipad")])
    }

    func testConnectUsesNetworkPortOrderAndReturnsRawStream() throws {
        let server = try FakeMux { request, socket in
            XCTAssertEqual(request["DeviceID"] as? Int, 7)
            XCTAssertEqual(request["PortNumber"] as? Int, 3351) // htons(5901)
            try FakeMux.reply(["MessageType": "Result", "Number": 0], to: socket, fragmented: true)
            try socket.write(Data("RFB 003.008\n".utf8))
        }
        defer { server.stop() }
        XCTAssertEqual(try server.mux.vncGreeting(device: FakeMux.device), "RFB 003.008")
    }

    func testMalformedLengthAndWrongResponseTagAreRejected() throws {
        let oversized = try FakeMux { _, socket in
            var header = Data(); header.appendLE(8 * 1024 * 1024); header.appendLE(1); header.appendLE(8); header.appendLE(1)
            try socket.write(header)
        }
        defer { oversized.stop() }
        XCTAssertThrowsError(try oversized.mux.devices())
        let wrongTag = try FakeMux { _, socket in try FakeMux.reply(["DeviceList": []], to: socket, tag: 99) }
        defer { wrongTag.stop() }
        XCTAssertThrowsError(try wrongTag.mux.devices())
    }

    func testRefusedServiceAndUnrelatedProtocolDoNotAppearReady() throws {
        let refused = try FakeMux { _, socket in try FakeMux.reply(["Number": 3], to: socket) }
        defer { refused.stop() }
        XCTAssertThrowsError(try refused.mux.vncGreeting(device: FakeMux.device)) { error in
            XCTAssertTrue(error.localizedDescription.contains("尚未开启"))
        }
        let unrelated = try FakeMux { _, socket in
            try FakeMux.reply(["Number": 0], to: socket)
            try socket.write(Data("HTTP/1.1 200".utf8))
        }
        defer { unrelated.stop() }
        XCTAssertThrowsError(try unrelated.mux.vncGreeting(device: FakeMux.device))
    }

    func testLockdownBigEndianFramingReadsDeviceDetails() throws {
        let server = try FakeMux { request, socket in
            let port = request["PortNumber"] as! Int
            XCTAssertEqual(port, Int((UInt16(62078) >> 8) | ((UInt16(62078) & 255) << 8)))
            try FakeMux.reply(["Number": 0], to: socket)
            let size = Int(try socket.read(count: 4).uint32BE(at: 0))
            let body = try socket.read(count: size)
            let value = try PropertyListSerialization.propertyList(from: body, options: [], format: nil) as! [String: Any]
            XCTAssertEqual(value["Request"] as? String, "GetValue")
            let data = try PropertyListSerialization.data(fromPropertyList: ["Value": ["DeviceName": "明明的iPad", "ProductType": "iPad7,3", "ProductVersion": "17.7.11"]], format: .binary, options: 0)
            var response = Data(); response.appendBE(UInt32(data.count)); response.append(data)
            try socket.write(response)
        }
        defer { server.stop() }
        let details = try server.mux.details(for: FakeMux.device)
        XCTAssertEqual(details.name, "明明的iPad")
        XCTAssertEqual(details.version, "17.7.11")
        XCTAssertTrue(details.isIPad)
    }

    func testSSHTricklingBannerHasTotalDeadlineAndFallsBackToPort44() throws {
        let server = try FakeMux { request, socket in
            try FakeMux.reply(["Number": 0], to: socket)
            if request["PortNumber"] as? Int == 22 << 8 {
                for _ in 0..<60 { try socket.write(Data([65])); usleep(80000) }
            } else {
                try socket.write(Data("Server notice\r\nSSH-2.0-OpenSSH_9.9\r\n".utf8))
            }
        }
        defer { server.stop() }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(try server.mux.sshPort(device: FakeMux.device), 44)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3.5)
    }
}

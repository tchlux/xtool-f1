import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import xToolF1Core

final class GeometryDiscoveryTests: XCTestCase {
    func testCanvasSnapperSnapsAndReleasesCenterGuide() {
        let near = CanvasSnapper.snap(PrintPlacement(xMM: 36, yMM: 10, widthMM: 40, heightMM: 20), to: [])
        let far = CanvasSnapper.snap(PrintPlacement(xMM: 32, yMM: 10, widthMM: 40, heightMM: 20), to: [])

        XCTAssertEqual(near.placement.xMM, 37.5)
        XCTAssertEqual(near.verticalGuidesMM, [57.5])
        XCTAssertEqual(far.placement.xMM, 32)
        XCTAssertEqual(far.verticalGuidesMM, [])
    }

    func testCanvasSnapperSnapsToOtherAssetEdgesAndCenters() {
        let other = PrintPlacement(xMM: 10, yMM: 10, widthMM: 20, heightMM: 20)
        let result = CanvasSnapper.snap(PrintPlacement(xMM: 31, yMM: 21, widthMM: 10, heightMM: 10), to: [other])

        XCTAssertEqual(result.placement.xMM, 30)
        XCTAssertEqual(result.placement.yMM, 20)
        XCTAssertEqual(result.verticalGuidesMM, [30])
        XCTAssertEqual(result.horizontalGuidesMM, [30])
    }

    func testCanvasSnapperPreservesRotation() {
        let result = CanvasSnapper.snap(PrintPlacement(xMM: 36, yMM: 10, widthMM: 40, heightMM: 20, rotationDegrees: 23), to: [])

        XCTAssertEqual(result.placement.xMM, 37.5)
        XCTAssertEqual(result.placement.rotationDegrees, 23)
    }

    func testDiscoveryGeneratesSubnetCandidates() {
        let hosts = F1Discovery.candidateHosts(address: 0xC0A80105, netmask: 0xFFFFFF00)

        XCTAssertEqual(hosts.first, "192.168.1.1")
        XCTAssertEqual(hosts.last, "192.168.1.254")
        XCTAssertFalse(hosts.contains("192.168.1.5"))
        XCTAssertEqual(hosts.count, 253)
    }

    func testDiscoveryOrdersPreferredHostsBeforeSubnetScan() {
        let hosts = F1Discovery.orderedHosts(preferredHosts: ["192.168.1.199", "192.168.1.199", "192.168.1.5"], address: 0xC0A80105, netmask: 0xFFFFFF00)

        XCTAssertEqual(Array(hosts.prefix(2)), ["192.168.1.199", "192.168.1.4"])
        XCTAssertEqual(hosts.filter { $0 == "192.168.1.199" }.count, 1)
        XCTAssertFalse(hosts.contains("192.168.1.5"))
    }

    func testDotDurationRoundTripsWithSpeedAndDPI() {
        for dpi in [125.0, 250.0, 500.0] {
            let duration = RasterSettings.dotDurationMicroseconds(speedMMPerSecond: 200, dpi: dpi)
            let speed = RasterSettings.speedMMPerSecond(dotDurationMicroseconds: duration, dpi: dpi)

            XCTAssertEqual(speed, 200, accuracy: 0.001)
        }
    }

    func testRasterSettingsClampDPIToXCSRange() {
        var settings = RasterSettings(dpi: RasterSettings.maximumDPI + 1)
        XCTAssertEqual(settings.dpi, RasterSettings.maximumDPI)

        settings.dpi = 0
        XCTAssertEqual(settings.dpi, RasterSettings.minimumDPI)
    }

    func testRasterGenerationClampsAboveXCSDPI() {
        let raster = RasterGenerator.makeRaster(
            from: [[0]],
            settings: RasterSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 1, heightMM: 1), dpi: RasterSettings.maximumDPI + 1)
        )

        XCTAssertEqual(raster.widthPixels, 50)
        XCTAssertEqual(raster.heightPixels, 50)
    }

    func testDiscoveryParsesF1MachineInfo() throws {
        let json = """
        {
          "deviceName": "xTool F1",
          "deviceCode": "MF1",
          "sn": "serial",
          "firmware": { "package_version": "40.51.013.2020.01.ht5" }
        }
        """

        let endpoint = try XCTUnwrap(F1Discovery.machineEndpoint(from: Data(json.utf8), host: "192.168.1.20", port: 8080))
        XCTAssertEqual(endpoint.host, "192.168.1.20")
        XCTAssertEqual(endpoint.httpPort, 8080)
        XCTAssertEqual(endpoint.tcpPort, 8780)
        XCTAssertEqual(endpoint.deviceName, "xTool F1")
        XCTAssertEqual(endpoint.serial, "serial")
        XCTAssertEqual(endpoint.firmwareVersion, "40.51.013.2020.01.ht5")
    }

    func testDiscoveryParsesWrappedF1MachineInfo() throws {
        let json = """
        {"code":0,"data":{"deviceName":"LuXTool","firmware":{"package_version":"40.51.013.2020.01.ht5","version":{"master_h3_laserservice":"40.51.013.2020.01.ht5"}},"laserPower":[10,2],"laserType":["RED","BLUE"],"machineSubType":"LG4","machineType":"S1","sn":"serial","workSize":{"x":119.97999572753906,"y":119.97999572753906}},"msg":"Success"}
        """

        let endpoint = try XCTUnwrap(F1Discovery.machineEndpoint(from: Data(json.utf8), host: "192.168.1.199", port: 8080))
        XCTAssertEqual(endpoint.host, "192.168.1.199")
        XCTAssertEqual(endpoint.deviceName, "LuXTool")
        XCTAssertEqual(endpoint.serial, "serial")
        XCTAssertEqual(endpoint.firmwareVersion, "40.51.013.2020.01.ht5")
    }

    func testDiscoveryRejectsNonF1MachineInfo() {
        let json = """
        { "deviceName": "Other Device", "deviceCode": "OTHER" }
        """

        XCTAssertNil(F1Discovery.machineEndpoint(from: Data(json.utf8), host: "192.168.1.30", port: 8080))
    }

    func testVectorOutlineUsesTransparencyAndOffset() throws {
        var pixels = [UInt8](repeating: 255, count: 30 * 30 * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i + 3] = 0
        }
        for y in 10..<20 {
            for x in 10..<20 {
                pixels[(y * 30 + x) * 4 + 3] = 255
            }
        }
        let bitmap = PhotoBitmap(width: 30, height: 30, pixels: pixels)
        let settings = RasterSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 30, heightMM: 30), dpi: 25.4, maxPowerPercent: 0, dropPowerThresholdPercent: 100)
        let outline = try XCTUnwrap(VectorOutlineGenerator.outline(bitmap: bitmap, settings: settings, offsetMM: 2, includeInterior: false))

        XCTAssertEqual(outline.paths.count, 1)
        XCTAssertEqual(outline.placement.xMM, 8, accuracy: 0.01)
        XCTAssertEqual(outline.placement.yMM, 8, accuracy: 0.01)
        XCTAssertEqual(outline.placement.widthMM, 14, accuracy: 0.01)
        XCTAssertEqual(outline.placement.heightMM, 14, accuracy: 0.01)
    }

    func testVectorOutlineInteriorTracingToggle() throws {
        var pixels = [UInt8](repeating: 0, count: 5 * 5 * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i + 3] = 255
        }
        let center = (2 * 5 + 2) * 4
        pixels[center] = 0
        pixels[center + 1] = 0
        pixels[center + 2] = 0
        pixels[center + 3] = 0
        let bitmap = PhotoBitmap(width: 5, height: 5, pixels: pixels)
        let settings = RasterSettings(placement: PrintPlacement(xMM: 0, yMM: 0, widthMM: 5, heightMM: 5), dpi: 25.4, maxPowerPercent: 100, dropPowerThresholdPercent: 1)
        let exterior = try XCTUnwrap(VectorOutlineGenerator.outline(bitmap: bitmap, settings: settings, offsetMM: 0, includeInterior: false))
        let full = try XCTUnwrap(VectorOutlineGenerator.outline(bitmap: bitmap, settings: settings, offsetMM: 0, includeInterior: true))

        XCTAssertEqual(exterior.paths.count, 1)
        XCTAssertGreaterThan(full.paths.count, exterior.paths.count)
    }

    func testVectorObjectCodableDefaultsAndPersistence() throws {
        let path = LaserPath(closed: true, points: [Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 1, y: 1)])
        let photo = ProjectPhoto(mode: .vector, settingsName: "Cut", settings: RasterSettings(), vectorSettings: VectorSettings(speedMMPerSecond: 55, powerPercent: 12), vectorPaths: [path], isEnabled: false)
        let decoded = try JSONDecoder().decode(ProjectPhoto.self, from: JSONEncoder().encode(photo))

        XCTAssertEqual(decoded.vectorPaths, [path])
        XCTAssertEqual(decoded.vectorSettings?.speedMMPerSecond, 55)
        XCTAssertEqual(decoded.vectorSettings?.powerPercent, 12)
        XCTAssertFalse(decoded.isEnabled)

        let old = try JSONDecoder().decode(ProjectPhoto.self, from: Data("""
        {"id":"00000000-0000-0000-0000-000000000001","name":"Old Shape","mode":"vector","settingsName":"Shape","settings":{}}
        """.utf8))
        XCTAssertEqual(old.vectorPaths, [])
        XCTAssertNil(old.vectorSettings)
        XCTAssertTrue(old.isEnabled)
    }

    func testStorePersistsStickyVectorSettings() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = try FileAppStore(root: root)
        try store.saveVectorSettings(VectorSettings(laser: .infrared, speedMMPerSecond: 33, powerPercent: 7))

        let loaded = try FileAppStore(root: root)
        XCTAssertEqual(loaded.data.lastVectorSettings?.laser, .infrared)
        XCTAssertEqual(loaded.data.lastVectorSettings?.speedMMPerSecond, 33)
        XCTAssertEqual(loaded.data.lastVectorSettings?.powerPercent, 7)
    }

}

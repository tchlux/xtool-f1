import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import xToolF1Core

extension XCTestCase {
    struct PathBounds {
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double
        var height: Double { maxY - minY }
    }

    func bounds(_ paths: [LaserPath]) throws -> PathBounds {
        let points = paths.flatMap(\.points)
        return PathBounds(
            minX: try XCTUnwrap(points.map(\.x).min()),
            minY: try XCTUnwrap(points.map(\.y).min()),
            maxX: try XCTUnwrap(points.map(\.x).max()),
            maxY: try XCTUnwrap(points.map(\.y).max())
        )
    }

    func distance(_ a: Point, _ b: Point) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    func dot(_ a: Point, _ b: Point) -> Double {
        let length = max(0.000001, hypot(a.x, a.y) * hypot(b.x, b.y))
        return (a.x * b.x + a.y * b.y) / length
    }

    func png(red: UInt8, green: UInt8, blue: UInt8) -> Data {
        png(width: 1, height: 1, rgba: [red, green, blue, 255])
    }

    func frameRectangle(x: Double, y: Double, width: Double, height: Double) -> ProjectPhoto {
        ProjectPhoto(
            name: "Rectangle",
            mode: .vector,
            settings: RasterSettings(),
            vectorSettings: VectorSettings(placement: PrintPlacement(xMM: x, yMM: y, widthMM: width, heightMM: height)),
            vectorPaths: [LaserPath(closed: true, points: [Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 1, y: 1), Point(x: 0, y: 1)])]
        )
    }

    func png(width: Int, height: Int, rgba: [UInt8]) -> Data {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    func jpeg(width: Int, height: Int, orientation: Int) -> Data {
        let rgba = [UInt8](repeating: 255, count: width * height * 4)
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

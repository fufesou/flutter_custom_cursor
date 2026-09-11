import Cocoa
import FlutterMacOS

enum CursorTestError: Error { case missingValue }
func require<T>(_ value: T?) throws -> T {
    guard let value = value else { throw CursorTestError.missingValue }
    return value
}

final class CursorImageTests {
    private func arguments(ratio: Double?) throws -> [String: Any] {
        let bitmap = try require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 14, pixelsHigh: 38, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: 28, height: 76)
        let bytes = try require(bitmap.bitmapData)
        bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let bottom = bitmap.bytesPerRow * 37
        for (index, value) in [UInt8(32), 64, 16, 128].enumerated() {
            bytes[bottom + index] = value
        }
        let png = try require(bitmap.representation(using: .png, properties: [:]))
        var args: [String: Any] = ["name": "edit", "width": 14, "height": 38,
            "hotX": 6.0, "hotY": 34.0, "buffer": FlutterStandardTypedData(bytes: png)]
        if let ratio = ratio { args["imagePixelRatio"] = ratio }
        return args
    }

    private func create(_ args: [String: Any]) throws -> NSCursor {
        let plugin = FlutterCustomCursorPlugin()
        var response: Any?
        plugin.handle(FlutterMethodCall(methodName: "createCustomCursor", arguments: args)) {
            response = $0
        }
        precondition(response as? String == "edit")
        let stored = Mirror(reflecting: plugin).children.first { $0.label == "caches" }
        let cache = try require(stored?.value as? [String: NSCursor])
        return try require(cache["edit"])
    }

    func testPixelRatioOverridesPngDensity() throws {
        for ratio in [1.0, 1.25, 2.0] {
            let cursor = try create(arguments(ratio: ratio))
            precondition(abs(cursor.image.size.width - 14 / ratio) < 0.0001, "cursor.image.size.width ratio \(ratio)")
            precondition(abs(cursor.image.size.height - 38 / ratio) < 0.0001, "cursor.image.size.height ratio \(ratio)")
            precondition(abs(cursor.hotSpot.x - 6 / ratio) < 0.0001, "cursor.hotSpot.x ratio \(ratio)")
            precondition(abs(cursor.hotSpot.y - 34 / ratio) < 0.0001, "cursor.hotSpot.y ratio \(ratio)")
            let bitmap = try require(cursor.image.representations.first as? NSBitmapImageRep)
            precondition(bitmap.pixelsWide == 14)
            precondition(bitmap.pixelsHigh == 38)
            var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
            bitmap.getPixel(&pixel, atX: 0, y: 37)
            let alpha = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : bitmap.samplesPerPixel - 1
            precondition(abs(pixel[alpha] - 128) <= 1)
        }
    }

    func testLegacyBufferKeepsItsUnits() throws {
        let args = try arguments(ratio: nil)
        let data = try require(args["buffer"] as? FlutterStandardTypedData)
        let expected = try require(NSImage(data: data.data))
        let cursor = try create(args)
        precondition(cursor.image.size == expected.size)
        precondition(cursor.hotSpot == NSPoint(x: 6, y: 34))
    }

    func testInvalidRatioReturnsAnError() throws {
        for ratio in [0.0, -1.0, Double.infinity, Double.nan] {
            let plugin = FlutterCustomCursorPlugin()
            let args = try arguments(ratio: ratio)
            var response: Any?
            plugin.handle(FlutterMethodCall(methodName: "createCustomCursor", arguments: args)) {
                response = $0
            }
            precondition(response is FlutterError)
        }
    }
}

let tests = CursorImageTests()
try tests.testLegacyBufferKeepsItsUnits()
try tests.testPixelRatioOverridesPngDensity()
try tests.testInvalidRatioReturnsAnError()
print("macOS cursor image tests passed")

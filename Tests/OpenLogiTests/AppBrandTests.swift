import Foundation
import XCTest
@testable import OpenLogi

final class AppBrandTests: XCTestCase {
    func testFindsFontInPackagedResources() throws {
        try withAppBundle { bundle in
            let directory = try XCTUnwrap(bundle.resourceURL)
            let font = try createFont(in: directory)
            XCTAssertEqual(AppBrand.fontResourceURL(in: bundle)?.standardizedFileURL, font.standardizedFileURL)
        }
    }

    func testFindsFontBesideExecutable() throws {
        try withAppBundle { bundle in
            let directory = try XCTUnwrap(bundle.executableURL).deletingLastPathComponent()
            let font = try createFont(in: directory)
            XCTAssertEqual(AppBrand.fontResourceURL(in: bundle)?.standardizedFileURL, font.standardizedFileURL)
        }
    }

    func testMissingResourceBundleReturnsNil() throws {
        try withAppBundle { bundle in
            XCTAssertNil(AppBrand.fontResourceURL(in: bundle))
        }
    }

    func testMissingFontReturnsNil() throws {
        try withAppBundle { bundle in
            let directory = try XCTUnwrap(bundle.resourceURL)
                .appendingPathComponent("OpenLogi_OpenLogi.bundle")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            XCTAssertNil(AppBrand.fontResourceURL(in: bundle))
        }
    }

    private func createFont(in directory: URL) throws -> URL {
        let resources = directory.appendingPathComponent("OpenLogi_OpenLogi.bundle")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let font = resources.appendingPathComponent("DMSans-Variable.ttf")
        // These tests exercise resource discovery, not CoreText font validation.
        try Data().write(to: font)
        return font
    }

    private func withAppBundle(_ test: (Bundle) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("OpenLogi.app")
        let contents = app.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/OpenLogi")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: executable)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": "OpenLogi", "CFBundlePackageType": "APPL"],
            format: .xml, options: 0
        )
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        try test(XCTUnwrap(Bundle(url: app)))
    }
}

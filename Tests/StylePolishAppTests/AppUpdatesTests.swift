import Foundation
import XCTest
@testable import StylePolishApp

final class AppUpdatesTests: XCTestCase {
    func testDownloadedCopyCannotInstallAnUpdate() {
        let download = URL(fileURLWithPath: "/Users/example/Downloads/StylePolish.app")
        XCTAssertEqual(UpdateAvailability.forBundle(at: download, configured: true), .moveToApplications)
    }

    func testConfiguredAppInApplicationsCanCheckForUpdates() {
        let installed = URL(fileURLWithPath: "/Applications/StylePolish.app")
        XCTAssertEqual(UpdateAvailability.forBundle(at: installed, configured: true), .available)
        XCTAssertEqual(UpdateAvailability.forBundle(at: installed, configured: false), .unconfigured)
    }
}

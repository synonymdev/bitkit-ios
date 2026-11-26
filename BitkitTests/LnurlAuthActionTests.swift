@testable import Bitkit
import XCTest

final class LnurlAuthActionTests: XCTestCase {
    private let base = "https://site.example/auth?tag=login&k1=abc"

    func testActionPicksTheMatchingWording() {
        XCTAssertEqual(LnurlAuthAction(uri: "\(base)&action=login"), .login)
        XCTAssertEqual(LnurlAuthAction(uri: "\(base)&action=register"), .register)
        XCTAssertEqual(LnurlAuthAction(uri: "\(base)&action=link"), .link)
        XCTAssertEqual(LnurlAuthAction(uri: "\(base)&action=auth"), .auth)
    }

    func testUppercaseAndEncodedActionsMatch() {
        XCTAssertEqual(LnurlAuthAction(uri: "\(base)&action=REGISTER"), .register)
        XCTAssertEqual(LnurlAuthAction(uri: "\(base)&action=%72egister"), .register)
        XCTAssertEqual(LnurlAuthAction(uri: "\(base)&%61ction=login"), .login)
    }

    func testMissingOrUnknownActionFallsBackToAuthenticate() {
        XCTAssertEqual(LnurlAuthAction(uri: base), .auth)
        XCTAssertEqual(LnurlAuthAction(uri: "\(base)&action=unknown"), .auth)
        XCTAssertEqual(LnurlAuthAction(uri: "not a uri"), .auth)
    }

    func testKeys() {
        XCTAssertEqual(LnurlAuthAction.register.titleKey, "other__lnurl_auth_register_title")
        XCTAssertEqual(LnurlAuthAction.link.promptKey, "other__lnurl_auth_link_prompt")
        XCTAssertEqual(LnurlAuthAction.login.buttonKey, "other__lnurl_auth_login_button")
        XCTAssertEqual(LnurlAuthAction.auth.buttonKey, "other__lnurl_auth_auth_title")
    }
}

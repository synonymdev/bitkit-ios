@testable import Bitkit
import Paykit
import XCTest

@MainActor
final class AppViewModelToastTests: XCTestCase {
    func testPaykitErrorToastDoesNotExposeSdkDetails() {
        let error = PaykitError.Transport(
            code: "transport_error",
            context: "Pubky write lock lost; operation outcome is uncertain (lease expired or clock unavailable)"
        )

        let description = AppViewModel.toastDescription(for: error)

        XCTAssertEqual(description, t("other__try_again"))
        XCTAssertFalse(description.contains("PaykitError"))
    }

    func testWrappedPaykitErrorToastDoesNotExposeSdkDetails() {
        let error = Bitkit.AppError(error: PaykitError.Transport(code: "transport_error", context: "write lock lost"))

        XCTAssertEqual(AppViewModel.toastDescription(for: error), t("other__try_again"))
    }

    func testOtherErrorsKeepTheirDescription() {
        let error = Bitkit.AppError(message: "Node not ready", debugMessage: nil)

        XCTAssertEqual(AppViewModel.toastDescription(for: error), error.localizedDescription)
    }
}

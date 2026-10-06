import MetalPetal
import MetalPetalThrowingPromise
import XCTest

/// The render graph must never let a C++ exception escape.
///
/// Every caller of this library is Swift, and a C++ exception unwinding
/// through Swift frames is undefined behaviour — the process terminates
/// rather than surfacing an error, which is how a `std::out_of_range`
/// on a departed promise reached the field as a fatal crash.
///
/// Without the guard this test does not fail; it CRASHES the test
/// process, which is the point.
final class RenderGraphExceptionGuardTests: XCTestCase {

    func testAThrowingPromiseBecomesAnErrorRatherThanACrash() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let context = try? MTIContext(device: device) else {
            throw XCTSkip("no Metal device")
        }

        let image = MTIImage(promise: MTIThrowingTestPromise())

        XCTAssertThrowsError(
            try context.startTask(toRender: image, completion: nil)
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, MTIErrorDomain)
            XCTAssertEqual(
                nsError.code, MTIError.renderGraphException.rawValue,
                "a C++ throw from inside resolution must surface as "
                    + "MTIErrorRenderGraphException, not terminate the process"
            )
            XCTAssertTrue(
                nsError.localizedDescription.contains("deliberate throw"),
                "the error should carry what() so the cause is still identifiable — got "
                    + nsError.localizedDescription
            )
        }
    }
}

import MetalPetal
import MetalPetalObjectiveC.Extension
import MetalPetalThrowingPromise
import XCTest

/// The render graph must never let a C++ exception escape.
///
/// Every caller of this library is Swift, and a C++ exception unwinding
/// through Swift frames is undefined behaviour — the process terminates
/// rather than surfacing an error, which is how a `std::out_of_range`
/// on a departed promise reached the field as a fatal crash.
final class RenderGraphExceptionGuardTests: XCTestCase {

    private func makeContext() throws -> MTIContext {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        // NOT `try?`: a real context-construction failure should surface
        // as a failure, not collapse into a skip.
        return try MTIContext(device: device)
    }

    private func assertReportsRenderGraphException(
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, MTIErrorDomain, file: file, line: line)
            XCTAssertEqual(
                nsError.code, MTIError.Code.renderGraphException.rawValue,
                "a C++ throw from inside resolution must surface as "
                    + "MTIErrorRenderGraphException, not terminate the process",
                file: file, line: line
            )
            XCTAssertTrue(
                nsError.localizedDescription.contains("deliberate throw"),
                "the error must carry what() so the cause is still identifiable — got "
                    + nsError.localizedDescription,
                file: file, line: line
            )
        }
    }

    /// The shallow case: the root promise throws immediately.
    func testAThrowingRootPromiseBecomesAnErrorRatherThanACrash() throws {
        let context = try makeContext()
        let image = MTIImage(promise: MTIThrowingTestPromise())
        assertReportsRenderGraphException {
            _ = try context.startTask(toRender: image, completion: nil)
        }
    }

    /// The case the field crash actually had: the throw happens AFTER a
    /// dependency has resolved, so it unwinds through a partially-built
    /// graph — past a resolved render target and the ObjC kernel frames
    /// in between. The shallow test above cannot reach any of that.
    func testAThrowDeepInTheGraphStillReportsItsCause() throws {
        let context = try makeContext()
        let dependency = MTIImage(
            color: MTIColor(red: 1, green: 0, blue: 0, alpha: 1),
            sRGB: false,
            size: CGSize(width: 16, height: 16)
        )
        let image = MTIImage(promise: MTIThrowingTestPromise(dependencies: [dependency]))
        assertReportsRenderGraphException {
            _ = try context.startTask(toRender: image, completion: nil)
        }
    }

    /// NSException is a C++ exception on the 64-bit ObjC runtime, so a
    /// bare `catch (...)` would swallow this library's own deliberate
    /// programmer-error traps. A nil image must still raise.
    func testNilImageStillRaisesRatherThanBecomingAnError() throws {
        let context = try makeContext()
        // Raised, not returned: proving it is NOT converted into an
        // MTIErrorRenderGraphException is the point.
        XCTAssertThrowsError(try context.startTask(toRender: MTIImage(promise: MTIThrowingTestPromise()), completion: nil))
    }
}

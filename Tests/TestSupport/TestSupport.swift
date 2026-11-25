import Foundation

/// A small, standalone assertion runner for Apple's Command Line Tools, which
/// do not include XCTest.framework. This target is never linked into the app.
public enum TestRunner {
    private static let lock = NSLock()
    private static var failures: [String] = []
    private static var test = ""
    public static func record(_ message: String, file: StaticString, line: UInt) {
        lock.lock(); defer { lock.unlock() }
        let entry = "\(test): \(message.prefix(600)) [\(file):\(line)]"
        failures.append(entry)
        print("  FAIL \(entry)")
    }
    public static func run(_ cases: [(String, () throws -> Void)]) -> Bool {
        for (name, operation) in cases {
            lock.lock(); test = name; let before = failures.count; lock.unlock()
            let start = ProcessInfo.processInfo.systemUptime
            do { try operation() } catch { record(error.localizedDescription, file: #filePath, line: #line) }
            lock.lock(); let passed = before == failures.count; lock.unlock()
            print("\(passed ? "PASS" : "FAIL") \(name) (\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start))s)")
        }
        lock.lock(); let failed = failures.count; lock.unlock()
        print("\n\(cases.count) checks completed; \(failed) failures.")
        return failed == 0
    }
}

public final class AsyncExpectation: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    public let description: String
    private let lock = NSLock()
    private var fulfilled = false
    init(_ description: String) { self.description = description }
    public func fulfill() {
        lock.lock(); defer { lock.unlock() }
        if !fulfilled { fulfilled = true; semaphore.signal() }
    }
    fileprivate func wait(until: DispatchTime) -> Bool { semaphore.wait(timeout: until) == .success }
}

open class TestCase {
    public init() {}
    public func expectation(description: String) -> AsyncExpectation { AsyncExpectation(description) }
    public func wait(for expectations: [AsyncExpectation], timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = DispatchTime.now() + timeout
        for expectation in expectations where !expectation.wait(until: deadline) {
            TestRunner.record("Timed out: \(expectation.description)", file: file, line: line)
        }
    }
}

public func XCTFail(_ message: String = "Failure", file: StaticString = #filePath, line: UInt = #line) {
    TestRunner.record(message, file: file, line: line)
}
public func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "Expected true", file: StaticString = #filePath, line: UInt = #line) {
    do { if try !value() { TestRunner.record(message(), file: file, line: line) } } catch { TestRunner.record(error.localizedDescription, file: file, line: line) }
}
public func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "Expected false", file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() { TestRunner.record(message(), file: file, line: line) } } catch { TestRunner.record(error.localizedDescription, file: file, line: line) }
}
public func XCTAssertEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "Values differ", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let lhs = try left(), rhs = try right()
        if lhs != rhs { TestRunner.record("\(message()): \(lhs) != \(rhs)", file: file, line: line) }
    } catch { TestRunner.record(error.localizedDescription, file: file, line: line) }
}
public func XCTAssertNotEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { if try left() == right() { TestRunner.record("Expected different values", file: file, line: line) } } catch { TestRunner.record(error.localizedDescription, file: file, line: line) }
}
public func XCTAssertLessThan<T: Comparable>(_ left: T, _ right: T, file: StaticString = #filePath, line: UInt = #line) {
    if !(left < right) { TestRunner.record("\(left) is not less than \(right)", file: file, line: line) }
}
public func XCTAssertGreaterThanOrEqual<T: Comparable>(_ left: T, _ right: T, file: StaticString = #filePath, line: UInt = #line) {
    if !(left >= right) { TestRunner.record("\(left) is less than \(right)", file: file, line: line) }
}
public func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line, _ handler: (Error) -> Void = { _ in }) {
    do { _ = try expression(); TestRunner.record("Expected an error", file: file, line: line) } catch { handler(error) }
}
public func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { TestRunner.record("Missing value", file: file, line: line); throw NSError(domain: "iControlValidation", code: 1) }
    return value
}

import Foundation

struct TestRunner {
    private(set) var failures: [String] = []

    mutating func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard !condition() else { return }
        failures.append("\(file):\(line): \(message)")
    }
}

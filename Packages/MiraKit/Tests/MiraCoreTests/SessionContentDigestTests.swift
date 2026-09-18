import Foundation
import XCTest
@testable import MiraCore

final class SessionContentDigestTests: XCTestCase {
    func testSHA256KnownAnswersAndBlockBoundary() {
        let vectors = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
        ]
        for (text, expected) in vectors {
            XCTAssertEqual(SessionContent(kind: .effectIntent, bytes: Data(text.utf8)).digest, expected)
        }
    }
}

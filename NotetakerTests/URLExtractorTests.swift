import XCTest
@testable import nox

final class URLExtractorTests: XCTestCase {
    func test_plainHTTPURL() {
        XCTAssertEqual(
            URLExtractor.firstHTTPURL(in: "https://github.com")?.absoluteString,
            "https://github.com"
        )
    }

    func test_httpURL() {
        XCTAssertEqual(
            URLExtractor.firstHTTPURL(in: "http://example.org")?.scheme,
            "http"
        )
    }

    func test_urlInsideText() {
        XCTAssertEqual(
            URLExtractor.firstHTTPURL(in: "see https://example.com please")?.host,
            "example.com"
        )
    }

    func test_noURL() {
        XCTAssertNil(URLExtractor.firstHTTPURL(in: "no link here"))
    }

    func test_multipleURLs_returnsFirst() {
        XCTAssertEqual(
            URLExtractor.firstHTTPURL(in: "https://a.com and https://b.com")?.host,
            "a.com"
        )
    }

    func test_fileURL_ignored() {
        XCTAssertNil(URLExtractor.firstHTTPURL(in: "file:///tmp/x.txt"))
    }

    func test_mailto_ignored() {
        XCTAssertNil(URLExtractor.firstHTTPURL(in: "mailto:foo@bar.com"))
    }

    func test_emptyString() {
        XCTAssertNil(URLExtractor.firstHTTPURL(in: ""))
    }

    func test_whitespaceOnly() {
        XCTAssertNil(URLExtractor.firstHTTPURL(in: "   \n\t   "))
    }
}

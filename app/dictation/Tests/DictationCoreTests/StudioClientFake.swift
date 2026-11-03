import Foundation
@testable import DictationCore

/// The StudioClient transport double every client test shares (the voiceover,
/// voice-library, produce-chunk and later client tests): it records the request
/// and answers with a canned status and body.
enum StudioClientFake {
    static func fake(status: Int = 200, body: String = "{}") -> (StudioClient, () -> URLRequest?) {
        var seen: URLRequest?
        let client = StudioClient(send: { request in
            seen = request
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        })
        return (client, { seen })
    }
}

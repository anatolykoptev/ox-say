import Foundation
@testable import DictationCore

/// A StudioClient whose transport answers with `body`/`status` and records the
/// request it was given; `seen()` returns the last request sent. Shared by the
/// client's own tests and the chunk-client tests.
func studioClientFake(status: Int = 200, body: String = "{}") -> (StudioClient, () -> URLRequest?) {
    var seen: URLRequest?
    let client = StudioClient(send: { request in
        seen = request
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    })
    return (client, { seen })
}

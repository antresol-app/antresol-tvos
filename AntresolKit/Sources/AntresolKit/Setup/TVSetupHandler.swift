import Foundation

/// Answers the TV setup endpoint: `GET /setup?n=` (the page for a phone's camera) and
/// `POST /setup` (that page's form, or JSON from the Antresol app). Checks the client's
/// address, the rate limit and the nonce; the actual setup (check the server, save it,
/// start QR sign-in) is `perform`, which the app supplies.
///
/// The nonce is single use: a setup that succeeded uses it up; one that failed (a typo
/// in the address) leaves it for another try. While a setup runs, others are refused.
public actor TVSetupHandler {
    /// Checks and saves `server` (already normalised), verifies `serverId` when given,
    /// starts QR sign-in and returns its code. Throws `TVSetupFailure` (other errors are
    /// classified with `TVSetupFailure.classify`).
    public typealias Perform = @Sendable (_ server: URL, _ serverId: String?) async throws -> TVSetupAnswer

    private var nonce: TVSetupNonce
    private var used = false
    private var busy = false
    private var limiter: TVSetupRateLimiter
    private let now: @Sendable () -> Date
    private let perform: Perform
    /// Called once after a successful setup (the listener can close then).
    private let finished: (@Sendable () async -> Void)?

    public init(
        nonce: TVSetupNonce,
        limiter: TVSetupRateLimiter = TVSetupRateLimiter(),
        now: @escaping @Sendable () -> Date = { Date() },
        perform: @escaping Perform,
        finished: (@Sendable () async -> Void)? = nil
    ) {
        self.nonce = nonce
        self.limiter = limiter
        self.now = now
        self.perform = perform
        self.finished = finished
    }

    /// Replaces the nonce (the old QR code stops working).
    public func renew(_ fresh: TVSetupNonce) {
        nonce = fresh
        used = false
    }

    public var currentNonce: TVSetupNonce { nonce }

    /// Whether `value` is the live nonce: not used, not expired.
    func accepts(_ value: String?) -> Bool {
        guard let value, !used, !nonce.isExpired(at: now()) else { return false }
        return constantTimeEqual(value, nonce.value)
    }

    /// The response to `request` from a client at `remoteAddress` (an IP, as text).
    public func respond(to request: HTTPRequest, from remoteAddress: String) async -> HTTPResponse {
        guard LocalAddress.isPrivate(remoteAddress) else { return .plain(403) }
        let ru = request.prefersRussian
        let wantsJSON = request.method == "POST" && (request.header("content-type") ?? "").lowercased().hasPrefix("application/json")
        // Only /setup counts towards the limit (a browser's favicon request does not).
        guard request.path == TVSetupLink.path || request.path == TVSetupLink.path + "/" else { return .plain(404) }
        guard limiter.allow(at: now()) else {
            return failure(.rateLimited(retryAfter: limiter.retryAfter(at: now())), json: wantsJSON, russian: ru, nonce: nil)
        }
        switch request.method {
        case "GET":
            guard accepts(request.query["n"]) else {
                return .html(404, TVSetupPage.expired(russian: ru))
            }
            return .html(200, TVSetupPage.form(nonce: nonce.value, error: nil, russian: ru))
        case "POST":
            return await submit(request, russian: ru, wantsJSON: wantsJSON)
        default:
            return HTTPResponse(status: 405, headers: [("Allow", "GET, POST")])
        }
    }

    private func submit(_ request: HTTPRequest, russian ru: Bool, wantsJSON: Bool) async -> HTTPResponse {
        guard let submission = TVSetupSubmission.parse(contentType: request.header("content-type"), body: request.body) else {
            return failure(.badRequest, json: wantsJSON, russian: ru, nonce: nil)
        }
        let json = submission.kind == .json
        guard accepts(submission.nonce) else {
            return failure(.expiredNonce, json: json, russian: ru, nonce: nil)
        }
        guard !busy else {
            return failure(.rateLimited(retryAfter: 5), json: json, russian: ru, nonce: nonce.value)
        }
        guard let server = ServerAddress.normalize(submission.server) else {
            return failure(.badRequest, json: json, russian: ru, nonce: nonce.value)
        }
        busy = true
        let answer: TVSetupAnswer
        do {
            answer = try await perform(server, submission.serverId)
        } catch {
            busy = false
            return failure(TVSetupFailure.classify(error), json: json, russian: ru, nonce: nonce.value)
        }
        busy = false
        used = true
        await finished?()
        if json {
            return .json(200, answer)
        }
        return HTTPResponse(status: 303, headers: [("Location", Self.approvalPage(answer))])
    }

    /// The server's web approval page for `answer`: `<server>/pair?code=…&sid=…`.
    static func approvalPage(_ answer: TVSetupAnswer) -> String {
        var base = answer.server
        while base.hasSuffix("/") { base.removeLast() }
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "code", value: answer.code), URLQueryItem(name: "sid", value: answer.sid)]
        return base + "/pair" + (components.url?.absoluteString ?? "")
    }

    private func failure(_ failure: TVSetupFailure, json: Bool, russian: Bool, nonce: String?) -> HTTPResponse {
        var headers: [(String, String)] = []
        if case .rateLimited(let wait) = failure { headers.append(("Retry-After", String(wait))) }
        if json {
            return .json(failure.status, ErrorBody(error: failure.code), headers: headers)
        }
        let page: String
        if failure == .expiredNonce {
            page = TVSetupPage.expired(russian: russian)
        } else if let nonce, !used {
            page = TVSetupPage.form(nonce: nonce, error: failure.message(russian: russian), russian: russian)
        } else {
            page = TVSetupPage.message(failure.message(russian: russian), russian: russian)
        }
        return .html(failure.status, page, headers: headers)
    }

    private struct ErrorBody: Encodable {
        var error: String
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

/// The setup page a phone's browser shows: self-contained HTML, Antresol's dark colours.
public enum TVSetupPage {
    public static func form(nonce: String, error: String?, russian ru: Bool) -> String {
        let title = ru ? "Настройка телевизора" : "Set up the TV"
        let label = ru ? "Адрес сервера Antresol" : "Antresol server address"
        let hint = ru
            ? "Адрес компьютера, на котором работает Antresol. Порт по умолчанию — 8420."
            : "The address of the computer running Antresol. The port defaults to 8420."
        let button = ru ? "Продолжить" : "Continue"
        let errorLine = error.map { #"<p class="error" role="alert">\#(escape($0))</p>"# } ?? ""
        let body = """
        <h1>\(escape(title))</h1>
        <form method="post" action="/setup">
        <input type="hidden" name="n" value="\(escape(nonce))">
        <label for="server">\(escape(label))</label>
        <input id="server" name="server" type="text" inputmode="url" autocomplete="url" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="192.168.1.10:8420" required autofocus>
        <p class="hint">\(escape(hint))</p>
        \(errorLine)
        <button type="submit">\(escape(button))</button>
        </form>
        """
        return document(title: title, body: body, russian: ru)
    }

    public static func expired(russian ru: Bool) -> String {
        message(TVSetupFailure.expiredNonce.message(russian: ru), russian: ru)
    }

    public static func message(_ text: String, russian ru: Bool) -> String {
        let title = ru ? "Настройка телевизора" : "Set up the TV"
        return document(title: title, body: "<h1>\(escape(title))</h1>\n<p>\(escape(text))</p>", russian: ru)
    }

    static func document(title: String, body: String, russian: Bool) -> String {
        """
        <!doctype html>
        <html lang="\(russian ? "ru" : "en")">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="dark">
        <title>Antresol · \(escape(title))</title>
        <style>
        :root{--bg:#000;--raised:#1c1c1e;--label:#f5f5f7;--label2:rgba(235,235,245,.7);--label3:rgba(235,235,245,.45);--accent:#0a84ff;--red:#ff453a}
        *{box-sizing:border-box}
        body{margin:0;min-height:100vh;background:var(--bg);color:var(--label);font:17px/1.4 -apple-system,system-ui,"Segoe UI",Roboto,sans-serif;display:flex;justify-content:center}
        main{width:100%;max-width:440px;padding:48px 16px}
        .brand{font-weight:700;letter-spacing:.02em;color:var(--label2);margin:0 0 24px}
        h1{font-size:28px;line-height:1.2;margin:0 0 24px}
        p{color:var(--label2);margin:0 0 16px}
        label{display:block;font-size:15px;font-weight:600;color:var(--label2);margin:0 0 8px}
        input[type=text]{width:100%;font:inherit;color:var(--label);background:var(--raised);border:1px solid rgba(235,235,245,.16);border-radius:12px;padding:14px 16px;margin:0 0 8px}
        input[type=text]:focus{outline:2px solid var(--accent);outline-offset:1px}
        .hint{font-size:15px;color:var(--label3)}
        .error{color:var(--red)}
        button{width:100%;font:inherit;font-weight:600;color:#fff;background:var(--accent);border:0;border-radius:12px;padding:14px 16px;margin-top:8px}
        </style>
        </head>
        <body>
        <main>
        <p class="brand">Antresol</p>
        \(body)
        </main>
        </body>
        </html>
        """
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }
}

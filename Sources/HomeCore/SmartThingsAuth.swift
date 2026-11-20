import Foundation

/// SmartThings credentials, kept in one keychain item.
///
/// Two ways in:
/// - a personal access token from account.smartthings.com/tokens: free, but
///   SmartThings makes new ones expire after 24 hours;
/// - OAuth through an "API Access" (API_ONLY) app on the user's account: the
///   access token lasts 24 hours and is renewed with the refresh token, which
///   SmartThings replaces on every renewal (the old one stops working at once).
///   Since 4 November 2026 creating that app takes SmartThings' paid
///   Developer Plan; free accounts get 403. The user creates it in the
///   SmartThings Console and pastes its client ID and secret.
///
/// The app's redirect URI is httpbin.org, which shows the authorization code
/// so the user can paste it back: a native app has no web page to land on.
public actor SmartThingsAuth {
  public static let authorizeURL = URL(string: "https://api.smartthings.com/v1/oauth/authorize")!
  public static let tokenURL = URL(string: "https://api.smartthings.com/v1/oauth/token")!
  public static let redirectURI = "https://httpbin.org/get"
  public static let scopes = ["r:devices:*", "x:devices:*", "r:locations:*"]

  public struct Summary: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case none, personalToken, oauth }

    public var mode: Mode = .none
    public var hasPersonalToken = false
    public var personalTokenSavedAt: Date?
    public var clientID: String?
    public var accessTokenExpiresAt: Date?

    public init() {}
  }

  struct Stored: Codable {
    var personalToken: String?
    var personalTokenSavedAt: Date?
    var clientID: String?
    var clientSecret: String?
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?
  }

  private let keychain: Keychain
  private let account = "smartthings"
  private var cached: Stored?
  private var refreshing: Task<String, Error>?

  public init(keychain: Keychain = Keychain(service: "dev.balsamo.home-control")) {
    self.keychain = keychain
  }

  public func summary() -> Summary {
    let stored = load()
    var summary = Summary()
    summary.hasPersonalToken = stored.personalToken != nil
    summary.personalTokenSavedAt = stored.personalTokenSavedAt
    summary.clientID = stored.clientID
    summary.accessTokenExpiresAt = stored.expiresAt
    if stored.refreshToken != nil {
      summary.mode = .oauth
    } else if stored.personalToken != nil {
      summary.mode = .personalToken
    }
    return summary
  }

  /// A token for the API: the OAuth one when authorized (renewed when it is
  /// about to expire), otherwise the personal one.
  public func accessToken() async throws -> String {
    let stored = load()
    if stored.refreshToken != nil, let access = stored.accessToken {
      if let expiry = stored.expiresAt, expiry.timeIntervalSinceNow > 300 { return access }
      return try await refresh()
    }
    if let personal = stored.personalToken { return personal }
    throw SmartThingsError.notConfigured
  }

  /// After a 401 for `rejected`: renews the OAuth token once, or gives up.
  public func tokenAfterUnauthorized(_ rejected: String) async throws -> String {
    let stored = load()
    guard stored.refreshToken != nil else { throw SmartThingsError.tokenRejected }
    if let access = stored.accessToken, access != rejected { return access }
    return try await refresh()
  }

  public func savePersonalToken(_ token: String) throws {
    var stored = load()
    stored.personalToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    stored.personalTokenSavedAt = Date()
    try save(stored)
  }

  public func saveClient(id: String, secret: String) throws {
    var stored = load()
    stored.clientID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    stored.clientSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    stored.accessToken = nil
    stored.refreshToken = nil
    stored.expiresAt = nil
    try save(stored)
  }

  /// Forgets the OAuth app and its tokens, keeping the personal token.
  public func forgetClient() throws {
    var stored = load()
    stored.clientID = nil
    stored.clientSecret = nil
    stored.accessToken = nil
    stored.refreshToken = nil
    stored.expiresAt = nil
    try save(stored)
  }

  public func disconnect() {
    keychain.remove(account: account)
    cached = Stored()
  }

  /// The page where the user lets the app in. It ends on httpbin.org with
  /// the code in the address.
  public func authorizationURL() throws -> URL {
    guard let clientID = load().clientID else { throw SmartThingsError.notConfigured }
    var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
      URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
    ]
    return components.url!
  }

  /// Trades the authorization code for tokens. `pasted` may be the code, the
  /// httpbin address or the JSON page httpbin shows.
  public func connect(withCode pasted: String) async throws {
    guard let code = Self.extractCode(pasted) else { throw SmartThingsError.badCode }
    let stored = load()
    guard let id = stored.clientID, let secret = stored.clientSecret else { throw SmartThingsError.notConfigured }
    let tokens = try await tokenRequest(clientID: id, secret: secret, form: [
      "grant_type": "authorization_code", "code": code, "client_id": id, "redirect_uri": Self.redirectURI,
    ])
    try store(tokens)
  }

  public static func extractCode(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let regex = try! NSRegularExpression(pattern: #"code"?\s*[:=]\s*"?([A-Za-z0-9_-]+)"#)
    if let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
       let range = Range(match.range(at: 1), in: trimmed) {
      return String(trimmed[range])
    }
    return trimmed.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil ? trimmed : nil
  }

  // MARK: - Internals

  /// One renewal at a time: a refresh token works once, so two parallel
  /// renewals would lose the session.
  private func refresh() async throws -> String {
    if let refreshing { return try await refreshing.value }
    let task = Task { try await self.performRefresh() }
    refreshing = task
    defer { refreshing = nil }
    return try await task.value
  }

  private func performRefresh() async throws -> String {
    let stored = load()
    guard let id = stored.clientID, let secret = stored.clientSecret, let refreshToken = stored.refreshToken else {
      throw SmartThingsError.reauthorizationNeeded
    }
    do {
      let tokens = try await tokenRequest(clientID: id, secret: secret, form: [
        "grant_type": "refresh_token", "client_id": id, "refresh_token": refreshToken,
      ])
      try store(tokens)
      Log.info("SmartThings token renewed, valid for \(Int(tokens.expiresIn / 3600)) h")
      return tokens.accessToken
    } catch SmartThingsError.http(let code, let message) where code == 400 || code == 401 {
      Log.info("SmartThings refresh refused: \(code) \(message ?? "")")
      throw SmartThingsError.reauthorizationNeeded
    }
  }

  private struct Tokens: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Double

    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case expiresIn = "expires_in"
    }
  }

  private func tokenRequest(clientID: String, secret: String, form: [String: String]) async throws -> Tokens {
    var request = URLRequest(url: Self.tokenURL)
    request.httpMethod = "POST"
    request.setValue("Basic \(Data("\(clientID):\(secret)".utf8).base64EncodedString())",
                     forHTTPHeaderField: "Authorization")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    request.httpBody = Data(form.map { key, value in
      "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
    }.joined(separator: "&").utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else { throw SmartThingsError.http(code, SmartThingsClient.message(in: data)) }
    return try JSONDecoder().decode(Tokens.self, from: data)
  }

  private func store(_ tokens: Tokens) throws {
    var stored = load()
    stored.accessToken = tokens.accessToken
    stored.refreshToken = tokens.refreshToken
    stored.expiresAt = Date().addingTimeInterval(tokens.expiresIn)
    try save(stored)
  }

  private func load() -> Stored {
    if let cached { return cached }
    let stored = keychain.read(Stored.self, account: account) ?? Stored()
    cached = stored
    return stored
  }

  private func save(_ stored: Stored) throws {
    try keychain.write(stored, account: account)
    cached = stored
  }
}

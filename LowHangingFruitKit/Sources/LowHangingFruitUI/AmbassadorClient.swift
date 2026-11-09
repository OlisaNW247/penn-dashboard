import Foundation
import LowHangingFruitKit

/// The ambassador server: the same Cloudflare Worker that counts poster
/// scans (`smooth-ambassadors/` in the repository), on the domain the printed
/// QR codes encode. It is not the Supabase backend and shares nothing with it:
/// no anonymous user, no class data, no JWT. The only credential is the
/// ambassador's own code, which travels in the path exactly as it does when
/// they open their page in Safari.
///
/// What leaves the phone through this client, and only when the student has
/// signed in to ambassador mode: the code; the anonymous app they picked and
/// the phone's UTC offset (so "today" is their today); and what they tap:
/// "posted", a checklist tick, a pause, the feedback they type. Nothing about
/// their classes, their Canvas, or their name beyond what the founder already
/// typed into the roster. `docs/PRIVACY.md` → "Ambassador mode" says the same.
protocol AmbassadorService: Sendable {
    func plan(code: String, anonApp: AmbassadorAnonApp, tzOffsetMinutes: Int) async throws -> AmbassadorPlan
    /// `POST /a/{code}/{action}` with a JSON body; the server answers JSON.
    func send(code: String, action: String, body: [String: String]) async throws
}

enum AmbassadorClientError: Error, Equatable {
    /// The server does not know the code (404). The one error the page puts
    /// into words for the student.
    case unknownCode
    case badResponse(Int)
    case network
}

struct AmbassadorClient: AmbassadorService {
    /// The live origin. The printed QR codes encode this domain, so it is the
    /// one domain the ambassador system can live on for now (see the
    /// `smooth-ambassadors/docs/deploy.md` constraint).
    static let defaultBaseURL = URL(string: "https://smooth-poster-scans.jazzysmile20.chatgpt.site")!

    var baseURL: URL = AmbassadorClient.defaultBaseURL
    var session: URLSession = .shared

    func plan(code: String, anonApp: AmbassadorAnonApp, tzOffsetMinutes: Int) async throws -> AmbassadorPlan {
        var components = URLComponents(url: baseURL.appendingPathComponent("a/\(code)/plan.json"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "anon", value: anonApp.rawValue),
            URLQueryItem(name: "tz", value: String(tzOffsetMinutes)),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw AmbassadorClientError.network }
        switch http.statusCode {
        case 200: return try AmbassadorPlan.decode(data)
        case 404: throw AmbassadorClientError.unknownCode
        default: throw AmbassadorClientError.badResponse(http.statusCode)
        }
    }

    func send(code: String, action: String, body: [String: String]) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("a/\(code)/\(action)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw AmbassadorClientError.network }
        switch http.statusCode {
        case 200...299: return
        case 404: throw AmbassadorClientError.unknownCode
        default: throw AmbassadorClientError.badResponse(http.statusCode)
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw AmbassadorClientError.network
        }
    }

    /// The phone's offset the server expects: minutes to subtract from UTC,
    /// so New York in November is 300. Pure, for the test.
    nonisolated static func tzOffsetMinutes(for zone: TimeZone, at date: Date = Date()) -> Int {
        -zone.secondsFromGMT(for: date) / 60
    }
}

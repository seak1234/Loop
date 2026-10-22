import Foundation
import CoreFoundation
import CryptoKit

/// Read-only history for the journal. Credentials never enter journal state or AI context.
struct CycleNightscoutConfiguration: Equatable {
    let siteURL: URL
    let apiSecret: String
    var sourceID: String {
        SHA256.hash(data: Data(siteURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct CycleNightscoutAmount {
    var date: Date
    var amount: Double
}

struct CycleNightscoutBatch {
    var glucose: [CycleGlucoseReading]?
    var boluses: [CycleNightscoutAmount]?
    var carbs: [CycleNightscoutAmount]?
    var complete: Bool { glucose != nil && boluses != nil && carbs != nil }

    func summaries(start: Date, end: Date, now: Date, range: (Date) -> (Double, Double)?, calendar: Calendar = .current,
                   includingEmptyDays: Set<String> = []) -> [CycleDailySummary] {
        var day = calendar.startOfDay(for: start)
        var result: [CycleDailySummary] = []
        while day < end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let readings = (glucose ?? []).filter { $0.date >= day && $0.date < min(next, now) }
            let insulin = (boluses ?? []).filter { $0.date >= day && $0.date < min(next, now) }
            let meals = (carbs ?? []).filter { $0.date >= day && $0.date < min(next, now) }
            let completeCarbs = carbs != nil && day >= start
            if !readings.isEmpty || !insulin.isEmpty || !meals.isEmpty || (completeCarbs && includingEmptyDays.contains(CycleDay.key(day, calendar: calendar))) {
                var summary = CycleDailySummary.make(start: day, end: next, now: now, readings: readings, range: range,
                    insulin: insulin.isEmpty ? nil : insulin.map(\.amount).reduce(0, +), insulinRecords: insulin.count,
                    carbs: meals.isEmpty ? nil : meals.map(\.amount).reduce(0, +), carbEntries: meals.count, calendar: calendar,
                    carbHistoryIsComplete: completeCarbs)
                summary.glucoseSource = readings.isEmpty ? nil : "Nightscout"
                summary.insulinSource = insulin.isEmpty ? nil : "Nightscout"
                summary.carbSource = carbs == nil ? nil : "Nightscout"
                // Nightscout treatments do not establish complete basal delivery.
                summary.insulinIsPartial = !insulin.isEmpty
                result.append(summary)
            }
            day = next
        }
        return result
    }
}

struct CycleNightscoutHistory {
    enum ReadError: Error { case invalidConfiguration, unavailable, invalidResponse, tooDense }
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    let configuration: CycleNightscoutConfiguration
    var transport: Transport = Self.load
    static let pageSize = 1000

    func request(endpoint: String, start: Date, end: Date) throws -> URLRequest {
        guard ["entries", "treatments"].contains(endpoint), start < end,
              var components = URLComponents(url: configuration.siteURL, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""), components.host != nil,
              !configuration.apiSecret.isEmpty else { throw ReadError.invalidConfiguration }
        let existingToken = components.queryItems?.filter { $0.name == "token" } ?? []
        components.query = nil; components.fragment = nil
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([basePath, "api/v1", endpoint + ".json"].filter { !$0.isEmpty }.joined(separator: "/"))
        var query = [URLQueryItem(name: "count", value: String(Self.pageSize))]
        if endpoint == "entries" {
            query += [URLQueryItem(name: "find[type]", value: "sgv"),
                      URLQueryItem(name: "find[date][$gte]", value: String(Int64((start.timeIntervalSince1970 * 1000).rounded()))),
                      URLQueryItem(name: "find[date][$lt]", value: String(Int64((end.timeIntervalSince1970 * 1000).rounded())))]
        } else {
            let formatter = ISO8601DateFormatter()
            query += [URLQueryItem(name: "find[created_at][$gte]", value: formatter.string(from: start)),
                      URLQueryItem(name: "find[created_at][$lt]", value: formatter.string(from: end))]
        }
        components.queryItems = query + existingToken
        guard let url = components.url else { throw ReadError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Match the authentication used by the existing Nightscout service.
        let hash = Insecure.SHA1.hash(data: Data(configuration.apiSecret.utf8)).map { String(format: "%02x", $0) }.joined()
        request.setValue(hash, forHTTPHeaderField: "api-secret")
        return request
    }

    func fetch(start: Date, end: Date, includeGlucose: Bool = true, includeTreatments: Bool = true) async throws -> CycleNightscoutBatch {
        async let glucoseRecords = optionalRecords(endpoint: "entries", start: start, end: end, enabled: includeGlucose)
        async let treatmentRecords = optionalRecords(endpoint: "treatments", start: start, end: end, enabled: includeTreatments)
        let (entries, treatments) = await (glucoseRecords, treatmentRecords)
        try Task.checkCancellation()
        let glucose = entries.map { Self.glucose($0, start: start, end: end) }
        let amounts = treatments.map { Self.amounts($0, start: start, end: end) }
        return CycleNightscoutBatch(glucose: glucose, boluses: amounts?.boluses, carbs: amounts?.carbs)
    }

    private func optionalRecords(endpoint: String, start: Date, end: Date, enabled: Bool) async -> [[String: Any]]? {
        guard enabled else { return nil }
        do { return try await records(endpoint: endpoint, start: start, end: end) }
        catch { return nil } // Never surface a URL, credential, server body, or underlying network error.
    }

    /// Split saturated time windows rather than assuming every server implements skip.
    /// Count raw records before filtering: full pages of invalid/other records still split.
    private func records(endpoint: String, start: Date, end: Date, depth: Int = 0) async throws -> [[String: Any]] {
        try Task.checkCancellation()
        let (data, response) = try await transport(request(endpoint: endpoint, start: start, end: end))
        guard response.statusCode == 200, data.count <= 8_000_000,
              let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ReadError.invalidResponse }
        guard records.count < Self.pageSize else {
            guard depth < 16, end.timeIntervalSince(start) > 2 else { throw ReadError.tooDense }
            let middle = Date(timeIntervalSince1970: floor((start.timeIntervalSince1970 + end.timeIntervalSince1970) / 2))
            let first = try await self.records(endpoint: endpoint, start: start, end: middle, depth: depth + 1)
            let second = try await self.records(endpoint: endpoint, start: middle, end: end, depth: depth + 1)
            return first + second
        }
        return records
    }

    static func glucose(_ records: [[String: Any]], start: Date, end: Date) -> [CycleGlucoseReading] {
        var readings: [Int64: CycleGlucoseReading] = [:]
        for record in records {
            guard record["type"] as? String == "sgv", record["isDeleted"] as? Bool != true, let value = number(record["sgv"]), value >= 39,
                  let date = timestamp(record), date >= start, date < end else { continue }
            let key = Int64((date.timeIntervalSince1970 * 1000).rounded())
            if readings[key] == nil { readings[key] = CycleGlucoseReading(date: date, mgdl: value) }
        }
        return readings.values.sorted { $0.date < $1.date }
    }

    static func amounts(_ records: [[String: Any]], start: Date, end: Date) -> (boluses: [CycleNightscoutAmount], carbs: [CycleNightscoutAmount]) {
        var boluses: [CycleNightscoutAmount] = [], carbs: [CycleNightscoutAmount] = []
        var seen = Set<String>()
        for record in records {
            guard let date = timestamp(record), date >= start, date < end,
                  record["isDeleted"] as? Bool != true else { continue }
            let fallback = "\(date.timeIntervalSince1970):\(record["eventType"] ?? ""):\(record["insulin"] ?? ""):\(record["carbs"] ?? "")"
            let id = (record["syncIdentifier"] as? String) ?? (record["_id"] as? String) ?? fallback
            guard seen.insert(id).inserted else { continue }
            if let grams = number(record["carbs"]), grams > 0 { carbs.append(.init(date: date, amount: grams)) }
            let event = record["eventType"] as? String ?? ""
            if ["Correction Bolus", "Meal Bolus", "Snack Bolus", "Bolus", "Combo Bolus"].contains(event),
               let units = number(record["insulin"]), units >= 0 {
                boluses.append(.init(date: date, amount: units))
            }
        }
        return (boluses, carbs)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite { return value.doubleValue }
        if let value = value as? String, let number = Double(value), number.isFinite { return number }
        return nil
    }

    private static func timestamp(_ record: [String: Any]) -> Date? {
        if let milliseconds = number(record["date"]), milliseconds > 0 { return Date(timeIntervalSince1970: milliseconds / 1000) }
        let formatter = ISO8601DateFormatter()
        for key in ["created_at", "dateString", "timestamp"] {
            guard let text = record[key] as? String else { continue }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    static func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let options = URLSessionConfiguration.ephemeral
        options.urlCache = nil; options.httpCookieStorage = nil; options.urlCredentialStorage = nil
        options.timeoutIntervalForResource = 30
        let session = URLSession(configuration: options, delegate: CycleNightscoutRedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ReadError.unavailable }
        return (data, response)
    }
}

/// Do not forward the Nightscout authentication header to another origin.
private final class CycleNightscoutRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let destination = request.url,
              original.scheme == destination.scheme, original.host == destination.host, original.port == destination.port else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

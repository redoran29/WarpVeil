import Foundation

@Observable
final class LocationService {
    var ip = "..."
    var location = "..."
    var flag = ""
    var isLoading = false

    private struct IPInfo: Codable {
        let query: String
        let country: String
        let countryCode: String
        let city: String
        let isp: String
    }

    func detect() async {
        isLoading = true
        defer { isLoading = false }

        guard let url = URL(string: "http://ip-api.com/json/") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let info = try JSONDecoder().decode(IPInfo.self, from: data)
            ip = info.query
            flag = Self.flag(from: info.countryCode)
            location = "\(flag) \(info.city), \(info.country) — \(info.isp)"
        } catch {
            ip = "Error"
            flag = ""
            location = "Detection failed"
        }
    }

    /// Convert "US" → "🇺🇸", "DE" → "🇩🇪", etc.
    private static func flag(from code: String) -> String {
        let base: UInt32 = 0x1F1E6 - 65 // regional indicator A
        return code.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(base + $0.value)
        }.map(String.init).joined()
    }
}

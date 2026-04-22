import Foundation

@Observable
final class LocationService {
    var ip = "..."
    var location = "..."
    var flag = ""
    var isLoading = false

    private struct IPInfo: Codable {
        let ip: String
        let country: String
        let countryCode: String
        let city: String
        let connection: Connection?

        struct Connection: Codable {
            let isp: String?
            let org: String?
        }

        enum CodingKeys: String, CodingKey {
            case ip, country, city, connection
            case countryCode = "country_code"
        }
    }

    func detect() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        guard let url = URL(string: "https://ipwho.is/") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let info = try JSONDecoder().decode(IPInfo.self, from: data)
            ip = info.ip
            flag = Self.flag(from: info.countryCode)
            let isp = info.connection?.isp ?? info.connection?.org ?? ""
            location = isp.isEmpty
                ? "\(flag) \(info.city), \(info.country)"
                : "\(flag) \(info.city), \(info.country) — \(isp)"
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

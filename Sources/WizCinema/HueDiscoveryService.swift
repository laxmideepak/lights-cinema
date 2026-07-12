import Foundation

final class HueDiscoveryService: @unchecked Sendable {
    private struct DiscoveryResult: Decodable {
        let id: String
        let internalipaddress: String
    }

    func discover() async -> [HueBridge] {
        guard let url = URL(string: "https://discovery.meethue.com/") else { return [] }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            return try JSONDecoder().decode([DiscoveryResult].self, from: data).map {
                HueBridge(id: $0.id, ipAddress: $0.internalipaddress)
            }
        } catch {
            return []
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum ModelPricing {
    static func download() async throws -> [ModelPrice] {
        let url = URL(string: "https://models.dev/api.json")!
        let data = try await MonitorHTTP.shared.data(URLRequest(url: url), maximumBytes: 16 * 1_024 * 1_024)
        return try await Task.detached(priority: .utility) {
            let root = try JSONSerialization.jsonObject(with: data)
            var prices: [ModelPrice] = []
            let version = "models.dev / " + ISO8601DateFormatter().string(from: Date())
            // Only canonical vendor prices: an aggregator's same-named model may have different prices.
            for provider in ["openai", "anthropic", "google"] {
                let models = JSONField.value(root, at: provider + ".models") as? [String: Any] ?? [:]
                for name in models.keys.sorted() {
                    guard let model = models[name], let input = JSONField.number(model, "cost.input"), let output = JSONField.number(model, "cost.output"),
                          input >= 0, output >= 0, input > 0 || output > 0 else { continue }
                    prices.append(ModelPrice(model: JSONField.text(model, "id") ?? name, inputPerMillion: input, outputPerMillion: output,
                        cacheReadPerMillion: JSONField.number(model, "cost.cache_read"), cacheWritePerMillion: JSONField.number(model, "cost.cache_write"), version: version))
                }
            }
            guard !prices.isEmpty else { throw MonitorError.message(L("The price catalog returned no usable data. Set prices manually")) }
            var seen = Set<String>()
            return prices.filter { seen.insert($0.model).inserted }
        }.value
    }
}

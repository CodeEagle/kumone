import Foundation
import KumoneCore

// Preserve the existing view models; Chart has no track previews or track count.
private struct ChartPayload: Encodable {
    let id: Int
    let name: String
    let coverImgUrl: String?
    let updateFrequency: String?
    let playCount: Int
}

func decodeChart<T: Decodable>(_ chart: Chart, as type: T.Type) throws -> T {
    guard let id = Int(chart.id.sourceID) else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: [], debugDescription: "Chart ID is not an integer: \(chart.id.sourceID)"))
    }
    let payload = ChartPayload(
        id: id, name: chart.name, coverImgUrl: chart.coverURL?.absoluteString,
        updateFrequency: chart.updateFrequency, playCount: chart.playCount)
    return try JSONDecoder().decode(type, from: JSONEncoder().encode(payload))
}

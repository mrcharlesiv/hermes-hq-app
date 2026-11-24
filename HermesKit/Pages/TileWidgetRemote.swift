// [tiles-v2] Server/add-on pre-rendered widget snapshot fetcher (docs/spec/1x-pages.md §5.8 rule 10).
// In the background iOS WKWebView will not paint off-screen, so Home Screen widgets stayed frozen until the app next
// opened. When a gateway add-on serves pre-rendered JPEGs at `/api/tiles/widget-snapshot`, `WidgetRefresh` /
// `TileWidgetWriter` can download them directly in the background with zero WebKit work. Gateways without the route
// return 404/501, which short-circuits immediately as `.unsupported` so no extra requests are sent.

import CoreGraphics
import Foundation
import ImageIO

nonisolated enum TileWidgetRemote {
    static let endpoint = "/api/tiles/widget-snapshot"

    enum Outcome: Equatable, Sendable {
        case picture(Data, width: Int, height: Int)
        case unsupported
        case unavailable
    }

    /// Builds the query items for a pre-rendered widget snapshot request.
    static func query(path: String, profile: String, width: Int, height: Int, dark: Bool, scale: Int) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "width", value: "\(max(60, width))"),
            URLQueryItem(name: "height", value: "\(max(60, height))"),
            URLQueryItem(name: "theme", value: dark ? "dark" : "light"),
            URLQueryItem(name: "scale", value: "\(max(1, min(3, scale)))"),
        ]
        if !profile.isEmpty, profile != "default" {
            items.append(URLQueryItem(name: "profile", value: profile))
        }
        return items
    }

    /// Validates that `data` is a JPEG under `maxBytes` and returns its pixel dimensions.
    static func validateJPEG(_ data: Data, maxBytes: Int) -> (width: Int, height: Int)? {
        guard data.count > 4, data.count <= maxBytes else { return nil }
        // JPEG SOI marker: FF D8 FF
        guard data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// Fetches one pre-rendered widget JPEG from the gateway.
    static func fetch(client: any GatewayClient, path: String, profile: String, width: Int, height: Int,
                      dark: Bool, scale: Int, maxBytes: Int) async -> Outcome {
        do {
            let data = try await client.rest("GET", endpoint,
                                             query: query(path: path, profile: profile, width: width, height: height, dark: dark, scale: scale),
                                             body: nil)
            guard let dims = validateJPEG(data, maxBytes: maxBytes) else { return .unavailable }
            return .picture(data, width: dims.width, height: dims.height)
        } catch let error as HTTPError {
            if error.status == 404 || error.status == 501 || error.status == 405 {
                return .unsupported
            }
            return .unavailable
        } catch {
            return .unavailable
        }
    }
}

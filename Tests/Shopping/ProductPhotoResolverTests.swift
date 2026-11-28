// [shopping] ProductPhotoParsing, ProductPhotoResolver and RemoteImageFetcher MIME acceptance tests.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

private final class StubLinkFetcher: LinkFetching, Sendable {
    let pages: [String: Result<LinkFetchResult, Error>]
    private let requested = Mutex<[String]>([])

    init(pages: [String: Result<LinkFetchResult, Error>]) {
        self.pages = pages
    }

    var fetchedURLs: [String] {
        requested.withLock { $0 }
    }

    func page(_ url: URL) async throws -> LinkFetchResult {
        requested.withLock { $0.append(url.absoluteString) }
        guard let result = pages[url.absoluteString] else {
            throw LinkFetchRefused(reason: "not found")
        }
        return try result.get()
    }

    func image(_ url: URL) async throws -> LinkFetchResult {
        throw LinkFetchRefused(reason: "unused")
    }
}

@Suite("Shopping & Travel: fallback photo discovery and CDN MIME checks")
struct ProductPhotoResolverTests {
    @Test func badPhotoURLFiltersOutNonProductImages() throws {
        let page = try #require(URL(string: "https://store.example.com/p/drink-1"))
        #expect(ProductPhotoParsing.isBadPhotoURL(try #require(URL(string: "https://store.example.com/p/drink-1/")), pageURL: page))
        #expect(ProductPhotoParsing.isBadPhotoURL(try #require(URL(string: "https://cdn.example.com/icon.svg"))))
        #expect(ProductPhotoParsing.isBadPhotoURL(try #require(URL(string: "https://cdn.example.com/img?format=svg"))))
        #expect(ProductPhotoParsing.isBadPhotoURL(try #require(URL(string: "https://store.example.com/favicon.png"))))
        #expect(ProductPhotoParsing.isBadPhotoURL(try #require(URL(string: "https://cdn.example.com/assets/Instacart_Share_Banner_3.jpg"))))
        #expect(ProductPhotoParsing.isBadPhotoURL(try #require(URL(string: "https://cdn.example.com/site-logo.png"))))
        #expect(ProductPhotoParsing.isBadPhotoURL(try #require(URL(string: "https://cdn.example.com/brand_logo_dark.webp"))))
        #expect(!ProductPhotoParsing.isBadPhotoURL(try #require(URL(string: "https://cdn.example.com/products/logo-tshirt-navy.jpg")), pageURL: page))
        #expect(!ProductPhotoParsing.isBadPhotoURL(try #require(URL(string: "https://cdn.example.com/products/drink.jpg")), pageURL: page))
        #expect(!ProductPhotoParsing.isBadPhotoURL(try #require(URL(string: "https://scene.example.com/is/image/Store/GUEST_1234")), pageURL: page))
    }

    @Test func photoCandidatesPreferJSONLDThenOGAndSkipBanners() {
        let html = """
        <html><head>
          <meta property="og:image" content="https://cdn.example.com/assets/Instacart_Share_Banner_3.jpg">
          <meta property="twitter:image" content="/images/fallback.webp">
          <script type="application/ld+json">
          {"@context":"https://schema.org","@type":"Product","name":"Bottle","image":["https://cdn.example.com/prod-main.jpg"]}
          </script>
        </head></html>
        """
        let got = ProductPhotoParsing.photoCandidates(fromHTML: html, pageURL: "https://store.example.com/p/bottle")
        #expect(got.map(\.absoluteString) == [
            "https://cdn.example.com/prod-main.jpg",
            "https://store.example.com/images/fallback.webp",
        ])
    }

    @Test func photoCandidatesHandleHotelJSONLDAndImageObject() {
        let html = """
        <html><head>
          <script type="application/ld+json">
          {"@graph":[{"@type":"Hotel","name":"Harbor House","image":{"@type":"ImageObject","contentUrl":"https://cdn.example.com/hotel-hero.jpg"}}]}
          </script>
          <meta property="og:image:secure_url" content="https://cdn.example.com/hotel-og.jpg">
        </head></html>
        """
        let got = ProductPhotoParsing.photoCandidates(fromHTML: html, pageURL: "https://stay.example.com/harbor")
        #expect(got.map(\.absoluteString) == [
            "https://cdn.example.com/hotel-hero.jpg",
            "https://cdn.example.com/hotel-og.jpg",
        ])
    }

    @Test func resolverFallsThroughToOfferPageAndCachesResult() async throws {
        let primary = try #require(URL(string: "https://shop1.example.com/p/drink"))
        let offer = try #require(URL(string: "https://shop2.example.com/p/drink"))
        let fetcher = StubLinkFetcher(pages: [
            primary.absoluteString: .success(LinkFetchResult(
                url: primary,
                type: "text/html",
                data: Data(#"<meta property="og:image" content="https://cdn.example.com/Instacart_Share_Banner_3.jpg">"#.utf8)
            )),
            offer.absoluteString: .success(LinkFetchResult(
                url: offer,
                type: "text/html",
                data: Data(#"<meta property="og:image" content="https://cdn.example.com/drinks/real.jpg">"#.utf8)
            )),
        ])
        let resolver = ProductPhotoResolver(fetcher: fetcher)
        let first = await resolver.candidates(for: [primary, offer])
        #expect(first.map(\.absoluteString) == ["https://cdn.example.com/drinks/real.jpg"])
        // Second call hits the in-memory cache without re-fetching.
        let second = await resolver.candidates(for: [primary, offer])
        #expect(second == first)
        #expect(fetcher.fetchedURLs.count == 2)
    }

    @Test func remoteImageFetcherAcceptsRasterAndOctetStreamButRejectsHTMLAndSVG() {
        #expect(RemoteImageFetcher.isAcceptableMIME("image/jpeg"))
        #expect(RemoteImageFetcher.isAcceptableMIME("image/webp"))
        #expect(RemoteImageFetcher.isAcceptableMIME("image/png"))
        #expect(RemoteImageFetcher.isAcceptableMIME("application/octet-stream"))
        #expect(RemoteImageFetcher.isAcceptableMIME("binary/octet-stream"))
        #expect(RemoteImageFetcher.isAcceptableMIME(nil))
        #expect(!RemoteImageFetcher.isAcceptableMIME("image/svg+xml"))
        #expect(!RemoteImageFetcher.isAcceptableMIME("text/html"))
        #expect(!RemoteImageFetcher.isAcceptableMIME("application/json"))
    }
}

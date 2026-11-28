// [travel] Hotel detail sheet + interactive MapKit view (Zoom in / Zoom out / Recenter + drag) + Copy address
// + full-screen HotelPhotoGalleryController with hotel name, photo counter, thumbnails, and zoom/paging.

import MapKit
import SwiftUI
import UIKit

enum HotelDetailSheet {
    @discardableResult
    static func present(_ hotel: TravelCards.Hotel,
                        asks: Set<TravelCards.Ask>,
                        bookingLocked: Bool,
                        from vc: UIViewController,
                        onAsk: @escaping (TravelCards.Ask) -> Void) -> UIViewController {
        let box = WeakPresenterBox(vc: nil)
        let host = UIHostingController(rootView: HQScaledRoot(HotelDetailView(
            hotel: hotel,
            asks: asks,
            bookingLocked: bookingLocked,
            onOpenPhotos: { index in
                guard let hostVC = box.vc else { return }
                HotelPhotoGalleryController.present(hotelName: hotel.name, urls: hotel.images, index: index, from: hostVC)
            },
            onAsk: { ask in
                vc.dismiss(animated: true) { onAsk(ask) }
            },
            onOpenSite: {
                LinkOpener.open(hotel.url, from: box.vc ?? vc)
            }
        )))
        box.vc = host
        let sheet = ChatSheet.wrap(host, title: hotel.name, detents: [.medium(), .large()])
        ChatSheet.wrapTitle(host)
        #if targetEnvironment(macCatalyst)
        SheetStyle.macPage(sheet, width: 660, from: vc)
        #else
        SheetStyle.widen(sheet, to: 660, from: vc)
        #endif
        vc.present(sheet, animated: true)
        return sheet
    }

    private final class WeakPresenterBox {
        weak var vc: UIViewController?
        init(vc: UIViewController?) { self.vc = vc }
    }
}

private struct HotelDetailView: View {
    let hotel: TravelCards.Hotel
    let asks: Set<TravelCards.Ask>
    let bookingLocked: Bool
    let onOpenPhotos: (Int) -> Void
    let onAsk: (TravelCards.Ask) -> Void
    let onOpenSite: () -> Void
    @State private var copiedAddress = false
    @State private var mapCommand: HotelMapCommand?
    @State private var submitted = false

    private func submit(_ ask: TravelCards.Ask) {
        guard !submitted else { return }
        submitted = true
        onAsk(ask)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !hotel.images.isEmpty { photosStrip }
                summaryCard
                if hotel.hasCoordinates { mapCard }
                if !hotel.address.isEmpty { addressCard }
                if !hotel.amenities.isEmpty { amenitiesCard }
                if !hotel.why.isEmpty || !hotel.caution.isEmpty { notesCard }
                actionsSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: HQPalette.sheetPage))
        .accessibilityIdentifier("travel.hotel.sheet")
    }

    private var photosStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(hotel.images.enumerated()), id: \.offset) { idx, url in
                    Button {
                        Haptics.play(.selection)
                        onOpenPhotos(idx)
                    } label: {
                        // The photo is a UIKit view: without a shape of its own the button takes no tap on it
                        // (only the "1 / 3" badge did), so the whole picture is the button.
                        HotelRemotePhoto(url: url)
                            .allowsHitTesting(false)
                            // One photo spans the sheet's card width (owner 2026-11-27: a 320 pt photo stopped short
                            // of the cards under it); several keep the 240 pt peeking strip.
                            .containerRelativeFrame(.horizontal) { width, _ in
                                hotel.images.count == 1 ? width : 240
                            }
                            .frame(height: 168)
                            .clipShape(.rect(cornerRadius: HQShape.radius(14, .card)))
                            .contentShape(.rect)
                            .overlay(alignment: .bottomTrailing) {
                                if idx == 0 && hotel.images.count > 1 {
                                    Text("1 / \(hotel.images.count)")
                                        .font(Font.hq(.caption2).weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Color.black.opacity(0.6), in: .capsule)
                                        .padding(8)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View photo \(idx + 1) of \(hotel.images.count)")
                    .accessibilityIdentifier("travel.hotel.photo.\(idx)")
                }
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(hotel.name)
                        .font(Font.hq(.title3).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                    let subParts: [String] = [
                        hotel.stars.map { String(repeating: "★", count: $0) },
                        hotel.rating.map { String(format: "%.1f", $0) + (hotel.reviews.map { " (\($0))" } ?? "") },
                        hotel.neighborhood.isEmpty ? nil : hotel.neighborhood,
                        hotel.distance.isEmpty ? nil : hotel.distance,
                    ].compactMap { $0 }
                    if !subParts.isEmpty {
                        Text(subParts.joined(separator: " · "))
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if let nightly = hotel.pricePerNight {
                        Text("\(ShoppingCards.price(nightly, currency: hotel.currency))/nt")
                            .font(Font.hq(.headline).weight(.bold))
                            .foregroundStyle(Color.hqLabel)
                    }
                    if let total = hotel.totalPrice {
                        Text("\(ShoppingCards.price(total, currency: hotel.currency)) total")
                            .font(Font.hq(.caption))
                            .foregroundStyle(Color.hqLabel2)
                    }
                    if let was = hotel.was {
                        Text(ShoppingCards.price(was, currency: hotel.currency))
                            .font(Font.hq(.caption))
                            .strikethrough()
                            .foregroundStyle(Color.hqLabel2)
                    }
                }
            }
            if !hotel.cancellation.isEmpty || !hotel.breakfast.isEmpty || !hotel.badge.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if !hotel.badge.isEmpty { pill(hotel.badge, tint: true) }
                        if !hotel.cancellation.isEmpty { pill(hotel.cancellation, tint: false) }
                        if !hotel.breakfast.isEmpty { pill(hotel.breakfast, tint: false) }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: HQPalette.sheetCard), in: .rect(cornerRadius: HQShape.radius(16, .card)))
    }

    private func pill(_ text: String, tint: Bool) -> some View {
        Text(text)
            .font(Font.hq(.caption).weight(.medium))
            .foregroundStyle(tint ? Color.hqTint : Color.hqLabel2)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint ? Color.hqTint.opacity(0.14) : Color.hqFill3, in: .capsule)
            .lineLimit(1)
    }

    @ViewBuilder
    private var mapCard: some View {
        if let lat = hotel.latitude, let lng = hotel.longitude {
            VStack(alignment: .leading, spacing: 8) {
                Text("LOCATION")
                    .font(Font.hq(.caption).weight(.semibold))
                    .foregroundStyle(Color.hqLabel2)
                ZStack(alignment: .topTrailing) {
                    HotelMapRepresentable(
                        coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                        title: hotel.name,
                        command: $mapCommand
                    )
                    .frame(height: 190)
                    .clipShape(.rect(cornerRadius: HQShape.radius(14, .card)))
                    .accessibilityIdentifier("travel.hotel.map")

                    VStack(spacing: 6) {
                        mapControlButton(symbol: "plus", label: "Zoom in", id: "travel.hotel.map.zoomIn") {
                            mapCommand = .zoomIn(UUID())
                        }
                        mapControlButton(symbol: "minus", label: "Zoom out", id: "travel.hotel.map.zoomOut") {
                            mapCommand = .zoomOut(UUID())
                        }
                        mapControlButton(symbol: "location.fill", label: "Recenter", id: "travel.hotel.map.recenter") {
                            mapCommand = .recenter(UUID())
                        }
                    }
                    .padding(8)
                }
            }
            .padding(14)
            .background(Color(uiColor: HQPalette.sheetCard), in: .rect(cornerRadius: HQShape.radius(16, .card)))
        }
    }

    private func mapControlButton(symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            Haptics.play(.selection)
            action()
        }) {
            Image(systemName: symbol)
                .font(Font.hq(.footnote).weight(.semibold))
                .foregroundStyle(Color.hqLabel)
                .frame(width: 34, height: 34)
                .hqGlassEffect(in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private var addressCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .font(Font.hq(.body))
                .foregroundStyle(Color.hqTint)
            Text(hotel.address)
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                UIPasteboard.general.string = hotel.address
                Haptics.play(.success)
                HQAnnounce.say("Address copied")
                copiedAddress = true
                Task {
                    try? await Task.sleep(for: .seconds(1.8))
                    copiedAddress = false
                }
            } label: {
                Label(copiedAddress ? "Copied" : "Copy address", systemImage: copiedAddress ? "checkmark" : "doc.on.doc")
                    .font(Font.hq(.footnote).weight(.semibold))
            }
            .hqBorderedButtonStyle()
            .accessibilityIdentifier("travel.hotel.copyAddress")
        }
        .padding(14)
        .background(Color(uiColor: HQPalette.sheetCard), in: .rect(cornerRadius: HQShape.radius(16, .card)))
    }

    private var amenitiesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AMENITIES")
                .font(Font.hq(.caption).weight(.semibold))
                .foregroundStyle(Color.hqLabel2)
            Text(hotel.amenities.joined(separator: " · "))
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: HQPalette.sheetCard), in: .rect(cornerRadius: HQShape.radius(16, .card)))
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !hotel.why.isEmpty {
                Text("WHY IT FITS").font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqLabel2)
                ForEach(hotel.why, id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle.fill")
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel)
                }
            }
            if !hotel.caution.isEmpty {
                Text("THINGS TO NOTE").font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqOrange)
                ForEach(hotel.caution, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle.fill")
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: HQPalette.sheetCard), in: .rect(cornerRadius: HQShape.radius(16, .card)))
    }

    private var actionsSection: some View {
        VStack(spacing: 10) {
            if asks.contains(.book) {
                Label("Booking requested", systemImage: "checkmark.circle.fill")
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .foregroundStyle(Color.hqLabel2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: HQPalette.sheetCard), in: .capsule)
                    .accessibilityIdentifier("travel.hotel.booked")
            } else if !bookingLocked {
                Button {
                    submit(.book)
                } label: {
                    let rate = hotel.pricePerNight.map { " · \(ShoppingCards.price($0, currency: hotel.currency))/nt" } ?? ""
                    Text("Book Hotel\(rate)")
                        .font(Font.hq(.body).weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .hqProminentButtonStyle()
                .disabled(submitted)
                .accessibilityIdentifier("travel.hotel.book")
            }
            HStack(spacing: 10) {
                if asks.contains(.watchPrice) {
                    Label("Watching rate", systemImage: "bell.fill")
                        .font(Font.hq(.footnote).weight(.semibold))
                        .foregroundStyle(Color.hqLabel2)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color(uiColor: HQPalette.sheetCard), in: .capsule)
                } else {
                    Button {
                        submit(.watchPrice)
                    } label: {
                        Label("Watch Rate", systemImage: "bell")
                            .font(Font.hq(.subheadline).weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .hqBorderedButtonStyle()
                    .disabled(submitted)
                    .accessibilityIdentifier("travel.hotel.watch")
                }
                Button {
                    onOpenSite()
                } label: {
                    Label("Open Site", systemImage: "safari")
                        .font(Font.hq(.subheadline).weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .hqBorderedButtonStyle()
                .accessibilityIdentifier("travel.hotel.site")
            }
        }
    }
}

// MARK: - MapKit Wrapper with Zoom In / Zoom Out / Recenter + Drag

private enum HotelMapCommand: Equatable {
    case zoomIn(UUID)
    case zoomOut(UUID)
    case recenter(UUID)
}

private struct HotelMapRepresentable: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    let title: String
    @Binding var command: HotelMapCommand?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.isScrollEnabled = true
        map.isZoomEnabled = true
        map.isRotateEnabled = false
        map.showsCompass = false
        let pin = MKPointAnnotation()
        pin.coordinate = coordinate
        pin.title = title
        map.addAnnotation(pin)
        let region = MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012))
        map.setRegion(region, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        guard let cmd = command, cmd != context.coordinator.lastCommand else { return }
        context.coordinator.lastCommand = cmd
        let animated = !HQMotion.reduced
        switch cmd {
        case .zoomIn:
            var region = map.region
            region.span.latitudeDelta = max(0.001, region.span.latitudeDelta * 0.5)
            region.span.longitudeDelta = max(0.001, region.span.longitudeDelta * 0.5)
            map.setRegion(region, animated: animated)
        case .zoomOut:
            var region = map.region
            region.span.latitudeDelta = min(60, region.span.latitudeDelta * 2.0)
            region.span.longitudeDelta = min(60, region.span.longitudeDelta * 2.0)
            map.setRegion(region, animated: animated)
        case .recenter:
            let region = MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012))
            map.setRegion(region, animated: animated)
        }
    }

    final class Coordinator {
        var lastCommand: HotelMapCommand?
    }
}

private struct HotelRemotePhoto: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> ShoppingPhotoView {
        let view = ShoppingPhotoView()
        view.set(url, maxPoints: 340)
        return view
    }
    func updateUIView(_ uiView: ShoppingPhotoView, context: Context) {
        uiView.set(url, maxPoints: 340)
    }
}

// MARK: - Full-Screen Hotel Photo Gallery Viewer (Name, Counter, Thumbnails, Zoom, Navigation)

final class HotelPhotoGalleryController: UIViewController, UIScrollViewDelegate {
    private let hotelName: String
    private let urls: [URL]
    private(set) var index: Int
    private let scroll = UIScrollView()
    private let imageView = ShoppingPhotoView()
    private let thumbScroll = UIScrollView()
    private var thumbButtons: [UIButton] = []
    private var arrows: PhotoPagerArrows?

    init(hotelName: String, urls: [URL], index: Int) {
        self.hotelName = hotelName
        self.urls = urls
        self.index = min(max(0, index), max(0, urls.count - 1))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @discardableResult
    static func present(hotelName: String, urls: [URL], index: Int, from vc: UIViewController) -> HotelPhotoGalleryController? {
        guard !urls.isEmpty else { return nil }
        let gallery = HotelPhotoGalleryController(hotelName: hotelName, urls: urls, index: index)
        let nav = UINavigationController(rootViewController: gallery)
        nav.modalPresentationStyle = .fullScreen
        nav.overrideUserInterfaceStyle = .dark
        vc.present(nav, animated: true)
        return gallery
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        view.accessibilityIdentifier = "travel.hotel.gallery"

        let close = PhotoViewerChrome.close(action: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        close.accessibilityLabel = "Close"
        close.accessibilityIdentifier = "travel.hotel.gallery.close"
        navigationItem.hqPlaceClose(close)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        view.addSubview(scroll)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.fits = true   // the whole photo, on black; pinch zooms in
        imageView.backgroundColor = .black
        scroll.addSubview(imageView)

        thumbScroll.translatesAutoresizingMaskIntoConstraints = false
        thumbScroll.showsHorizontalScrollIndicator = false
        thumbScroll.accessibilityIdentifier = "travel.hotel.gallery.thumbnails"
        view.addSubview(thumbScroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: thumbScroll.topAnchor, constant: -10),

            imageView.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.frameLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.frameLayoutGuide.bottomAnchor),

            thumbScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            thumbScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            thumbScroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            thumbScroll.heightAnchor.constraint(equalToConstant: urls.count > 1 ? 64 : 0),
        ])

        buildThumbnails()
        if urls.count > 1 {
            arrows = PhotoPagerArrows(in: view, identifier: "travel.hotel.gallery") { [weak self] forward in
                self?.step(forward: forward)
            }
            let leftSwipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedLeft))
            leftSwipe.direction = .left
            view.addGestureRecognizer(leftSwipe)
            let rightSwipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedRight))
            rightSwipe.direction = .right
            view.addGestureRecognizer(rightSwipe)
        }
        showCurrent()
    }

    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }
    override var keyCommands: [UIKeyCommand]? { urls.count > 1 ? UIKeyCommand.photoPaging(#selector(pageKey(_:))) : [] }

    @objc private func pageKey(_ command: UIKeyCommand) { step(forward: command.pagesForward) }
    @objc private func swipedLeft() { step(forward: true) }
    @objc private func swipedRight() { step(forward: false) }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    private func buildThumbnails() {
        guard urls.count > 1 else { return }
        var x: CGFloat = 0
        for (i, url) in urls.enumerated() {
            let btn = UIButton(type: .custom)
            btn.frame = CGRect(x: x, y: 4, width: 56, height: 56)
            btn.layer.cornerRadius = 8
            btn.layer.cornerCurve = .continuous
            btn.clipsToBounds = true
            btn.accessibilityLabel = "Photo \(i + 1) of \(urls.count)"
            btn.accessibilityIdentifier = "travel.hotel.gallery.thumb.\(i)"
            let thumb = ShoppingPhotoView()
            thumb.frame = btn.bounds
            thumb.isUserInteractionEnabled = false
            thumb.set(url, maxPoints: 64)
            btn.addSubview(thumb)
            btn.addAction(UIAction { [weak self] _ in
                self?.select(index: i)
            }, for: .primaryActionTriggered)
            thumbScroll.addSubview(btn)
            thumbButtons.append(btn)
            x += 64
        }
        thumbScroll.contentSize = CGSize(width: max(0, x - 8), height: 64)
    }

    private func step(forward: Bool) {
        guard let next = PhotoPaging.step(from: index, count: urls.count, forward: forward) else { return }
        select(index: next)
    }

    func select(index newIndex: Int) {
        guard urls.indices.contains(newIndex) else { return }
        index = newIndex
        scroll.setZoomScale(1, animated: false)
        showCurrent()
    }

    private func showCurrent() {
        title = hotelName
        navigationItem.subtitle = "\(index + 1) of \(urls.count)"
        imageView.set(urls[index], maxPoints: 800)
        arrows?.update(index: index, count: urls.count, hidden: false)
        for (i, btn) in thumbButtons.enumerated() {
            btn.layer.borderWidth = i == index ? 2.5 : 0
            btn.layer.borderColor = UIColor.white.cgColor
            btn.alpha = i == index ? 1.0 : 0.6
        }
    }
}

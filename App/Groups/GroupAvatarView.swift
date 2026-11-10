// [groups] A room's avatar (docs/spec/3x-groups.md §7.1; `S/ui-kit/bot-avatar.tsx:68-87`): the room photo when it has
// one, one face for one member, else two or three faces at the web's placements (fractions of the avatar's side).

import UIKit

nonisolated enum GroupAvatarLayout {
    /// (scale, x, y) per face, as fractions of the side.
    static func placements(_ count: Int) -> [(scale: CGFloat, x: CGFloat, y: CGFloat)] {
        switch count {
        case ..<1: return []
        case 1: return [(1, 0, 0)]
        case 2: return [(0.64, 0, 0), (0.64, 0.36, 0.36)]
        default: return [(0.54, 0.23, 0), (0.46, 0, 0.5), (0.42, 0.56, 0.54)]
        }
    }

    /// A `data:image/…;base64,` URL's bytes.
    static func imageData(_ dataURL: String?) -> Data? {
        guard let dataURL, dataURL.hasPrefix("data:image/"), let comma = dataURL.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]), options: .ignoreUnknownCharacters)
    }
}

final class GroupAvatarView: UIView {
    private let photo = UIImageView()
    private var heads: [HeadView] = []
    private let empty = UIImageView()
    private var faces: [GroupRowModel.Face] = []
    private var imageKey: String?
    var side: CGFloat { didSet { if side != oldValue { invalidateIntrinsicContentSize(); setNeedsLayout() } } }

    init(side: CGFloat) {
        self.side = side
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        isUserInteractionEnabled = false
        photo.contentMode = .scaleAspectFill
        photo.clipsToBounds = true
        photo.isHidden = true
        addSubview(photo)
        empty.image = UIImage(systemName: "person.2.fill")
        empty.tintColor = HQPalette.label3
        empty.contentMode = .scaleAspectFit
        empty.isHidden = true
        addSubview(empty)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: side, height: side) }

    func configure(image: String?, faces: [GroupRowModel.Face]) {
        if image != imageKey {
            imageKey = image
            photo.image = GroupAvatarLayout.imageData(image).flatMap { UIImage(data: $0) }
        }
        let hasPhoto = photo.image != nil
        photo.isHidden = !hasPhoto
        let shown = hasPhoto ? [] : Array(faces.prefix(3))
        if shown != self.faces || heads.count != shown.count {
            self.faces = shown
            while heads.count > shown.count { heads.removeLast().removeFromSuperview() }
            while heads.count < shown.count {
                let head = HeadView(side: side)
                heads.append(head)
                addSubview(head)
            }
            for (head, face) in zip(heads, shown) { head.configure(raw: face.head, profile: face.profile) }
        }
        empty.isHidden = hasPhoto || !shown.isEmpty
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = min(bounds.width, bounds.height)
        let origin = CGPoint(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2)
        photo.frame = CGRect(origin: origin, size: CGSize(width: s, height: s))
        photo.layer.cornerRadius = s / 2
        empty.frame = photo.frame.insetBy(dx: s * 0.2, dy: s * 0.2)
        for (head, place) in zip(heads, GroupAvatarLayout.placements(heads.count)) {
            let side = (s * place.scale).rounded()
            head.frame = CGRect(x: origin.x + (s * place.x).rounded(), y: origin.y + (s * place.y).rounded(), width: side, height: side)
        }
    }
}

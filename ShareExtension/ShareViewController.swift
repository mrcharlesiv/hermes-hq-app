// [share] The Share extension's principal class (Info.plist NSExtensionPrincipalClass): hosts the SwiftUI sheet and
// hands the share back to the system when it is sent or cancelled (docs/spec/3x-share.md §4.1, D15).
// Port of build 240's ShareExtension/ShareViewController.swift.

import SwiftUI
import UIKit

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        #if targetEnvironment(macCatalyst)
        ShareFailure.device = "Mac"
        #else
        ShareFailure.device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
        let inputs = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let model = ShareModel(inputs: inputs) { [weak self] sent in
            guard let context = self?.extensionContext else { return }
            if sent { context.completeRequest(returningItems: nil) }
            else { context.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
        }
        // While a share is going out the sheet cannot be swiped away (a remote sheet honours the UIKit flag).
        model.onBusyChange = { [weak self] busy in self?.isModalInPresentation = busy }
        self.model = model
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    /// A sheet that goes away any other way than Cancel or Send (swiped down while idle, ended by the system) stops
    /// reading and sending, and removes its copies.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model?.abandon()
    }
}

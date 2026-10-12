import EluviumCore
import LumiKitUI
import UIKit

extension UIViewController {
    /// Pushes the item browser for one of `parent`'s collections: the
    /// card's collection tap, the "Load episodes" chain, and a seeded list's
    /// entries all land here, so the three screens that present records
    /// navigate identically.
    func pushItems(of parent: ELVRecord, collection name: String) {
        navigationController?.pushViewController(
            FeedItemsViewController(parent: parent, collectionName: name, items: parent.collections[name] ?? []),
            animated: LMKAnimation.shouldAnimate
        )
    }
}

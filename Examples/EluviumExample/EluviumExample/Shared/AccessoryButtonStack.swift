import LumiKitUI
import SnapKit
import UIKit

/// The frame-laid-out host for `LMKButton`s riding as a cell's
/// `accessoryView`. The app's theme floors every button at the 44pt touch
/// target with a height constraint on the button itself, and a constraint
/// on a view turns off its autoresizing translation: a bare button as the
/// accessory then loses the frame the cell sets, drifts to the cell's
/// top-left, and the cell's frame layout and the button's constraints
/// re-dirty each other on every pass. The stack keeps its own translation
/// on, so the cell's frame holds, and sizes itself once from the buttons'
/// constraints (the theme's height floor plus a matching width floor)
/// instead of a hardcoded frame. LumiKit's next release carries the floor
/// on a layout guide (CHANGELOG `[Unreleased]`), after which a bare button
/// works as the accessory again; this host stays while the app resolves
/// 1.0.0.
final class AccessoryButtonStack: UIStackView {
    /// The hosted buttons, leading to trailing.
    let buttons: [LMKButton]

    init(buttons: [LMKButton]) {
        self.buttons = buttons
        super.init(frame: .zero)
        axis = .horizontal
        spacing = LMKSpacing.small
        for button in buttons {
            addArrangedSubview(button)
            button.snp.makeConstraints { $0.width.greaterThanOrEqualTo(LMKLayout.minimumTouchTarget) }
        }
        frame = CGRect(origin: .zero, size: systemLayoutSizeFitting(UIView.layoutFittingCompressedSize))
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

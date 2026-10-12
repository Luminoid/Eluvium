import LumiKitUI
import SnapKit
import UIKit

/// The header stacks the list screens show above their rows. A list screen
/// hangs its header in the table (`makeTableHeader` + `setFittedHeaderView`)
/// so it scrolls with the rows: a fixed block over the table outgrows the
/// screen at accessibility text sizes, in iPhone landscape, and in Slide
/// Over. A screen whose body is not a table (the feed reader) pins its
/// header with `install(header:in:below:)` instead.
///
/// Horizontal insets come from LumiKit's `lmk_readableWidthGuide`, which
/// measures from the safe area: content clears the landscape sensor housing
/// and a floating sidebar, caps at the readable width on iPad and Mac, and
/// holds still during the iOS 26 interactive swipe back (a root view's
/// `readableContentGuide` stretches ~20pt there).
@MainActor
enum ListHeaderScaffold {
    /// A vertical header stack; only the vertical breathing room lives in its
    /// margins (horizontal insets come from the readable-width pinning).
    static func makeHeaderStack(_ views: [UIView], spacing: CGFloat, bottomMargin: CGFloat = LMKSpacing.medium, alignment: UIStackView.Alignment = .fill) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.alignment = alignment
        stack.spacing = spacing
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: LMKSpacing.medium, left: 0, bottom: bottomMargin, right: 0)
        return stack
    }

    /// Wraps a header stack in a frame-sized container for `tableHeaderView`.
    /// The bottom pin sits just below required: UIKit sizes a table header
    /// by its frame, and a required pin would fight that frame on every pass
    /// between a content change and the next `setFittedHeaderView`.
    static func makeTableHeader(_ stack: UIStackView) -> UIView {
        let container = UIView()
        container.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.bottom.equalToSuperview().priority(999)
            make.leading.trailing.equalTo(container.lmk_readableWidthGuide)
        }
        return container
    }

    /// Pins a header stack under `navigationBar` along the readable-width
    /// guide. The caller pins whatever sits below it to the header's bottom.
    static func install(header: UIStackView, in view: UIView, below navigationBar: LMKNavigationBar) {
        view.addSubview(header)
        header.snp.makeConstraints { make in
            make.top.equalTo(navigationBar.snp.bottom)
            make.leading.trailing.equalTo(view.lmk_readableWidthGuide)
        }
    }
}

extension UITableView {
    /// Installs `view` as the table header, sized to the table's width at its
    /// fitted height, or removes the header for `nil`. A table reads a
    /// header's height only when it is assigned, so hosts call this again
    /// whenever the content or the text size changes and from
    /// `viewDidLayoutSubviews` (a width change); it reinstalls only when the
    /// frame changed and does nothing before the table has a width.
    func setFittedHeaderView(_ view: UIView?) {
        fit(view, installed: tableHeaderView) { tableHeaderView = $0 }
    }

    /// `setFittedHeaderView` for `tableFooterView`.
    func setFittedFooterView(_ view: UIView?) {
        fit(view, installed: tableFooterView) { tableFooterView = $0 }
    }

    private func fit(_ view: UIView?, installed: UIView?, install: (UIView?) -> Void) {
        guard let view else {
            if installed != nil { install(nil) }
            return
        }
        let width = bounds.width
        guard width > 0 else { return }
        let frame = CGRect(x: 0, y: 0, width: width, height: fittedHeight(of: view, width: width))
        guard installed !== view || view.frame != frame else { return }
        view.frame = frame
        install(view)
        // A detached view fits without the table's side safe area (iPhone
        // landscape); laid out in the window it has it, so fit once more.
        guard window != nil else { return }
        layoutIfNeeded()
        let settled = CGRect(x: 0, y: 0, width: width, height: fittedHeight(of: view, width: width))
        if settled != view.frame {
            view.frame = settled
            install(view)
        }
    }

    private func fittedHeight(of view: UIView, width: CGFloat) -> CGFloat {
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        return view.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height.rounded(.up)
    }
}

extension UITableView {
    /// The reuse identifier for rows with nothing to select. Kept apart from
    /// `LMKListTable.cellReuseIdentifier`: `lmk_installRowPointerInteraction`
    /// installs once and stays on the cell, so a selectable row's pointer
    /// hover would ride a recycled cell into a static row.
    static let staticRowReuseIdentifier = "StaticListRow"

    /// Registers the plain cell behind `staticRowReuseIdentifier`.
    func registerStaticRows() {
        register(UITableViewCell.self, forCellReuseIdentifier: Self.staticRowReuseIdentifier)
    }
}

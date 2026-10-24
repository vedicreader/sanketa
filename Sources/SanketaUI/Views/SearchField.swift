import AppKit
import SwiftUI

/// The panel's one text field; `onClick` fires when the user clicks into it.
/// (Not `becomeFirstResponder`: AppKit also makes it first responder when the panel is re-ordered front.)
public final class SearchTextField: NSSearchField {
    var onClick: () -> Void = {}

    public override func mouseDown(with e: NSEvent) {
        onClick()
        super.mouseDown(with: e)
    }
}

/// Hosts the controller-owned field so the controller can focus it directly.
struct SearchField: NSViewRepresentable {
    let field: SearchTextField
    func makeNSView(context: Context) -> SearchTextField { field }
    func updateNSView(_ v: SearchTextField, context: Context) {}
}

import AppKit
import ConfigCore
import SwiftUI

// An action on the selected rows of a table, shown in its context menu; disabled ones say why in their tooltip.

struct BulkAction: Identifiable {
    let title: String
    var icon = ""
    var check = BulkCheck.ok
    let run: () -> Void
    var id: String { title }
}

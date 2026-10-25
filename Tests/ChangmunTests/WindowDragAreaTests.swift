import Testing
@testable import Changmun

struct WindowDragAreaTests {
    @Test func doubleClickFollowsTheSystemSetting() {
        typealias D = WindowDragArea.DoubleClick
        #expect(D.from(action: "Maximize", minimizeFlag: false) == .zoom)
        #expect(D.from(action: "Fill", minimizeFlag: false) == .zoom)
        #expect(D.from(action: "Minimize", minimizeFlag: false) == .minimize)
        #expect(D.from(action: "None", minimizeFlag: true) == .nothing)
        #expect(D.from(action: nil, minimizeFlag: false) == .zoom)
        #expect(D.from(action: nil, minimizeFlag: true) == .minimize)
    }
}

import XCTest
@testable import WorkScribe
import WorkScribeCore

/// Pairing Zoom's Accessibility caption elements (an 18 pt name label above each paragraph).
final class ZoomCaptionsTests: XCTestCase {
    private func text(_ value: String, y: Double, h: Double) -> ZoomCaptions.TextElement {
        .init(role: "AXStaticText", value: value, x: 0, y: y, width: 600, height: h)
    }

    func testLabelsPairWithTheParagraphBelow() {
        let looks = ZoomCaptions.blocks(from: [
            text("Andrew Sulistio", y: 1468, h: 18), text("Let's lock the beta plan.", y: 1486, h: 170),
            text("Dana Kim", y: 1666, h: 18), text("Fine, November 4th.", y: 1684, h: 26),
        ])
        XCTAssertEqual(looks, [.init(speaker: "Andrew Sulistio", text: "Let's lock the beta plan."),
                               .init(speaker: "Dana Kim", text: "Fine, November 4th.")])
    }

    /// Mid-scroll, Accessibility reported a label six points below its own paragraph (seen live).
    /// The label is still that paragraph's speaker and is never written out as speech.
    func testLabelReportedBelowItsParagraphWhileScrolling() {
        let looks = ZoomCaptions.blocks(from: [
            text("I'm going to ignore those. Let's lock the beta plan.", y: 1414, h: 170),
            text("Andrew Sulistio", y: 1420, h: 18),
            text("Andrew Sulistio", y: 1594, h: 18),
            text("Let's lock the beta plan. The beta opens to 40 accounts.", y: 1612, h: 146),
        ])
        XCTAssertEqual(looks, [.init(speaker: "Andrew Sulistio", text: "I'm going to ignore those. Let's lock the beta plan."),
                               .init(speaker: "Andrew Sulistio", text: "Let's lock the beta plan. The beta opens to 40 accounts.")])
    }

    /// A label whose paragraph hasn't appeared yet is not speech.
    func testLoneLabelIsNotSpeech() {
        XCTAssertEqual(ZoomCaptions.blocks(from: [text("Andrew Sulistio", y: 1594, h: 18)]), [])
    }
}

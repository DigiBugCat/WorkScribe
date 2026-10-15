import XCTest
@testable import WorkScribeCore

final class FactualRewriteTests: XCTestCase {
    func testPreservesEquivalentClauseWhileAddingNewFact() {
        let old="Priya will tell Halvorsen on Friday."
        let result=FactualRewrite.preserve(previous:old,proposed:"Priya tells Halvorsen on Friday. The rollout follows the migration review.")
        XCTAssertTrue(result.kept)
        XCTAssertEqual(result.text,"Priya will tell Halvorsen on Friday. The rollout follows the migration review.")
        XCTAssertEqual(FactualRewrite.preserve(previous:old,proposed:"Priya tells Halvorsen on Friday.").text,old)
    }
    func testFactsNegationModalityAndRolesAreNotCollapsed() {
        for proposed in ["Priya tells Halvorsen on Monday.","Marcus tells Halvorsen on Friday.","Halvorsen tells Priya on Friday.","Priya will not tell Halvorsen on Friday.","Priya may tell Halvorsen on Friday.","Priya tells Halvorsen on Friday at 4."] {
            let result=FactualRewrite.preserve(previous:"Priya will tell Halvorsen on Friday.",proposed:proposed)
            XCTAssertFalse(result.kept,proposed);XCTAssertEqual(result.text,proposed)
        }
        XCTAssertFalse(FactualRewrite.preserve(previous:"Ship 40 accounts.",proposed:"Ship 41 accounts.").kept)
        XCTAssertFalse(FactualRewrite.preserve(previous:"Will tells Priya.",proposed:"Tells Priya.").kept)
    }
    func testKeptDecisionIsRecordedWithoutIncrementingLineRevision() throws {
        var m=Meeting(title:"Rewrite")
        var note=Note(text:"Priya tell Halvorsen",createdAt:5)
        note.enhanced="**Update:** Priya will tell Halvorsen on Friday."
        note.enhancedFrom=note.text;note.revision=1
        m.notes=[note];m.segments=[Segment(source:"system",speaker:"system:speaker-1",start:4,end:8,text:"Priya tells Halvorsen on Friday.")]
        var plan=try NotePlanner.plan(m,incremental:false,missedTopics:false)
        plan.targets[0].previous=note.enhanced
        let result=NoteEnhancement.apply("* **Update:** Priya tells Halvorsen on Friday.",plan:plan,to:[note]).notes[0]
        XCTAssertEqual(result.enhanced,note.enhanced);XCTAssertEqual(result.revision,1)
        XCTAssertTrue(result.trace?.steps.contains{$0.title=="Kept: no new facts"} == true)
    }
}

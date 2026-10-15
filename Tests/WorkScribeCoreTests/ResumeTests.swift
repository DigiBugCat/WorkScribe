import XCTest
@testable import WorkScribeCore

final class ResumeTests: XCTestCase {
    func testResumePreservesEvidenceAndUsesDistinctFilesAndClock() throws {
        let start = Date(timeIntervalSince1970: 1000)
        var m = Meeting(title: "Same note"); m.startedAt = start; m.endedAt = start.addingTimeInterval(60); m.status = "complete"
        let segment = Segment(source: "microphone", speaker: "microphone:speaker-1", start: 5, end: 9, text: "First capture")
        m.segments = [segment]; m.sourceOffsets = ["microphone": 2]
        m.speakerAssignments = [segment.speaker: SpeakerAssignment(name: "Priya")]
        m.notes = [Note(text: "release", createdAt: 5)]
        m.screen = ScreenCaptureInfo(file: "screen.mov", offset: 1, state: "complete", momentCount: 2)
        m.purgeAt = start.addingTimeInterval(86460)
        let id = m.id, notes = m.notes
        try m.resume(at: start.addingTimeInterval(90))
        XCTAssertEqual(m.id,id); XCTAssertEqual(m.notes,notes); XCTAssertEqual(m.segments.first?.id,segment.id)
        XCTAssertEqual(m.speakerName(for: segment),"Priya")
        XCTAssertNil(m.endedAt); XCTAssertNil(m.purgeAt); XCTAssertEqual(m.retention,"live")
        XCTAssertEqual(m.recordingSessions?.count,2)
        XCTAssertEqual(m.recordingSessions?.first?.screen?.file,"screen.mov")
        XCTAssertEqual(m.recordingSessions?.last?.start,90)
        XCTAssertNotEqual(m.recordingSessions?.first?.audioFile("microphone"),m.recordingSessions?.last?.audioFile("microphone"))
        XCTAssertEqual(m.audioLocation(for: segment)?.file,"microphone.wav")
        m.recordingSessions?[1].sourceOffsets["microphone"] = 91
        let new = Segment(source: "microphone",speaker:"new:microphone:speaker-1",start:95,end:99,text:"Second capture")
        XCTAssertEqual(m.audioLocation(for:new)?.offset,91)
        XCTAssertEqual(m.audioLocation(for:new)?.file,m.recordingSessions?.last?.audioFile("microphone"))
        XCTAssertEqual(m.speakerName(for:new),"Speaker 1")
        let encoded = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self,from:encoded).recordingSessions,m.recordingSessions)
    }
    func testDeadlineAndPurgedRecordingsCannotResume() throws {
        var m = Meeting(title:"Boundary");m.status="complete";m.endedAt=Date(timeIntervalSince1970:1000)
        XCTAssertTrue(m.canResume(at:Date(timeIntervalSince1970:1599)))
        XCTAssertFalse(m.canResume(at:Date(timeIntervalSince1970:1600)))
        XCTAssertThrowsError(try m.resume(at:Date(timeIntervalSince1970:1600)))
        m.retention="purged"
        XCTAssertFalse(m.canResume(at:Date(timeIntervalSince1970:1001)))
    }
    func testDeleteScreenCaptureRemovesEverySessionMovieButPreservesAudio() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=MeetingStore(root:root)
        var m=Meeting(title:"Parts");m.status="complete";m.endedAt=Date()
        m.screen=ScreenCaptureInfo(file:"screen.mov",state:"complete")
        try m.resume()
        let resumedVideo=m.recordingSessions![1].videoFile
        m.recordingSessions?[1].screen=ScreenCaptureInfo(file:resumedVideo,state:"complete")
        try store.save(m)
        let folder=try store.directory(m.id)
        for file in ["screen.mov",m.recordingSessions![1].videoFile,m.recordingSessions![1].audioFile("microphone")] {
            let url=folder.appendingPathComponent(file);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data("sentinel".utf8).write(to:url)
        }
        let result=try store.deleteScreenCapture(m.id,trash:false)
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.appendingPathComponent("screen.mov").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.appendingPathComponent(m.recordingSessions![1].videoFile).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:folder.appendingPathComponent(m.recordingSessions![1].audioFile("microphone")).path))
        XCTAssertTrue(result.recordingSessions!.allSatisfy{$0.screen == nil})
    }
}

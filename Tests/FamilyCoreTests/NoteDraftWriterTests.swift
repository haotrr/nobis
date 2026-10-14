import Foundation
import Testing
import FamilyDomain
import FamilyCore
@testable import NobisUI

@Suite("笔记草稿后台写入") @MainActor struct NoteDraftWriterTests {
    private func draft(_ text: String, space: UUID) -> DocumentDraft {
        var body = RecordBody(kind: .document, title: "草稿")
        body.notes = text
        return DocumentDraft(body: body, spaceID: space, recordID: UUID(), expected: [UUID()])
    }

    @Test func burstWritesOnlyLatestSnapshotAndReportsAfterDiskWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentDraftStore(directory: directory), writer = NoteDraftWriter()
        let key = UUID(), space = UUID()
        let latest = draft("中文👨‍👩‍👧 " + String(repeating: "正文", count: 10_000), space: space)
        var completions = 0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            for index in 0..<100 {
                writer.schedule(store: store, draft: index == 99 ? latest : draft("输入\(index)", space: space), key: key, allowed: { true }) { result in
                    completions += 1
                    do { try result.get(); #expect(try store.read(key) == latest) }
                    catch { Issue.record(error) }
                    done.resume()
                }
            }
            #expect((try? store.read(key)) == nil)
        }
        #expect(completions == 1)
    }

    @Test func cancellationFlushAndPermissionLossDoNotResurrectDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentDraftStore(directory: directory), writer = NoteDraftWriter()
        let key = UUID(), space = UUID(), value = draft("保留正文", space: UUID())
        writer.schedule(store: store, draft: value, key: key, allowed: { true }) { _ in Issue.record("取消的写入不能回调") }
        writer.cancel()
        try store.save(value, key: key) // Close/scene flush finishes without waiting for the timer.
        #expect(try store.read(key) == value)
        try store.remove(key)
        var allowed = true
        writer.schedule(store: store, draft: draft("撤权前", space: space), key: key, allowed: { allowed }) { _ in Issue.record("撤权后不能写入") }
        allowed = false
        try store.remove(spaceID: space)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try store.read(key) == nil)
    }

    @Test func submittedWritesDrainBeforeRemovalAndRunOffMainThread() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentDraftStore(directory: directory), key = UUID(), space = UUID()
        let value = draft("已排队", space: space)
        let offMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            store.saveInBackground(value, key: key) { result in
                do { try result.get() } catch { Issue.record(error) }
                done.resume(returning: !Thread.isMainThread)
            }
            // This call must serialize behind the background write, even before its callback runs.
            do { try store.remove(spaceID: space) } catch { Issue.record(error) }
        }
        #expect(offMain)
        #expect(try store.read(key) == nil)
    }

    @Test func failedWriteIsReportedWithoutClaimingSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = NoteDraftWriter(), store = DocumentDraftStore(directory: directory)
        let failed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            writer.schedule(store: store, draft: draft("仍在编辑", space: UUID()), key: UUID(), allowed: { true }) { result in
                if case .failure = result { done.resume(returning: true) }
                else { done.resume(returning: false) }
            }
        }
        #expect(failed)
    }
}

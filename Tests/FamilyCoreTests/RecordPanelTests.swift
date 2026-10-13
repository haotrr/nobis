import Foundation
import Testing
import FamilyDomain
import NobisUI

@Suite("记录侧栏编辑状态") @MainActor struct RecordPanelTests {
    func record() -> Record {
        Record.project([Revision(spaceID: UUID(), actorID: UUID(), body: RecordBody(kind: .task, title: "任务"))])[0]
    }
    @Test func switchingPreservesDraftUntilExplicitDiscard() {
        let panel = RecordPanelState(), first = record(), second = record()
        panel.open(first.id); panel.edit(first); panel.updateChanges(true, recordID: first.id); panel.open(second.id)
        #expect(panel.recordID == first.id)
        #expect(panel.editingRecord?.id == first.id)
        #expect(panel.needsDiscardConfirmation)
        panel.keepEditing()
        #expect(panel.recordID == first.id)
        panel.open(second.id); panel.discardAndContinue()
        #expect(panel.recordID == second.id); #expect(panel.editingRecord == nil)
    }
    @Test func closeAndSaveReturnToCorrectState() {
        let panel = RecordPanelState(), value = record()
        panel.open(value.id); panel.edit(value); panel.updateChanges(true, recordID: value.id); panel.close()
        #expect(panel.recordID == value.id); #expect(panel.needsDiscardConfirmation)
        panel.keepEditing(); panel.finishEditing()
        #expect(panel.recordID == value.id); #expect(panel.editingRecord == nil)
        panel.close(); #expect(panel.recordID == nil)
    }
    @Test func unchangedEditsAndRevertedChangesDoNotPrompt() {
        let panel = RecordPanelState(), first = record(), second = record()
        panel.open(first.id); panel.edit(first); panel.open(second.id)
        #expect(panel.recordID == second.id); #expect(!panel.needsDiscardConfirmation)
        panel.edit(second); panel.updateChanges(true, recordID: second.id)
        panel.updateChanges(false, recordID: second.id); panel.cancelEditing()
        #expect(panel.editingRecord == nil); #expect(panel.recordID == second.id)
    }
    @Test func cancelPreservesDraftUntilDiscardThenReturnsToDetails() {
        let panel = RecordPanelState(), value = record()
        panel.open(value.id); panel.edit(value); panel.updateChanges(true, recordID: value.id)
        panel.cancelEditing(); panel.dismissDiscardPrompt(); panel.discardAndContinue()
        #expect(panel.recordID == value.id); #expect(panel.editingRecord == nil)
        #expect(!panel.hasChanges)
        panel.updateChanges(true, recordID: value.id); #expect(!panel.hasChanges)
    }
    @Test func accessResetDropsCapturedPrivatePayload() {
        let panel = RecordPanelState(), value = record()
        panel.open(value.id); panel.edit(value); panel.updateChanges(true, recordID: value.id); panel.close(); panel.reset()
        #expect(panel.recordID == nil); #expect(panel.editingRecord == nil)
        #expect(!panel.needsDiscardConfirmation)
        panel.discardAndContinue(); #expect(panel.recordID == nil)
    }
}

import CryptoKit
import Foundation
import GRDB
import MiraCore

/// Archive validation for the task domain.  The archive contains the complete
/// task history, while its journal references are checked against retained
/// metadata rather than payload bytes (payloads may have been purged).
extension SQLiteTaskStore {
    public static func archiveModule() throws -> SQLiteArchiveModule {
        try SQLiteArchiveModule(
            identity: .init(name: "tasks", revision: 1),
            schemaStatements: archiveSchemaStatements,
            restoration: .prepare(
                apply: { db, _ in try pauseRestoredReminders(in: db) },
                verify: { db in
                    try SQLiteArchiveValidation.rows(in: db, table: "mira_tasks") { row in
                        let task = try taskRecord(row)
                        if task.draft.reminderAt != nil, !task.status.isTerminal {
                            guard task.deliveryState == .paused, task.deliveryRevision == nil, task.deliveryError == nil
                            else { throw LibraryArchiveIO.invalid }
                        }
                    }
                }
            )
        ) { db, snapshot in
            try validateTaskArchive(in: db, snapshot: snapshot)
            return []
        }
    }

    private static func validateTaskArchive(in db: Database, snapshot: FileSessionSnapshot) throws {
        guard try Int.fetchOne(db, sql: "SELECT version FROM task_schema WHERE id = 1") == 1,
            try Int.fetchOne(db, sql: "SELECT count(*) FROM task_schema") == 1
        else {
            throw LibraryArchiveIO.invalid
        }
        let journal = try SQLiteArchiveSessions(snapshot)
        var tasks: [String: MiraTask] = [:]
        try SQLiteArchiveValidation.rows(in: db, table: "mira_tasks", maximumBytes: ["task_json": 131_072]) { row in
            guard tasks.count < LibraryArchiveLimits.maximumDomainRows else { throw LibraryArchiveIO.invalid }
            let task = try taskRecord(row)
            let key = id(task.id)
            guard tasks[key] == nil else { throw LibraryArchiveIO.invalid }
            if let evidence = task.evidence {
                try validateEvidence(evidence, workspaceID: task.workspaceID, journal: journal)
            }
            tasks[key] = task
        }

        var revisions: [String: Set<Int>] = [:]
        try SQLiteArchiveValidation.rows(in: db, table: "task_revisions", maximumBytes: ["revision_json": 131_072]) {
            row in
            let revision = try revisionRecord(row)
            let taskKey = id(revision.task.id)
            guard tasks[taskKey] != nil,
                revisions[taskKey, default: []].insert(revision.task.revision).inserted
            else {
                throw LibraryArchiveIO.invalid
            }
            if let evidence = revision.task.evidence {
                try validateEvidence(evidence, workspaceID: revision.task.workspaceID, journal: journal)
            }
        }
        for (key, task) in tasks {
            guard revisions[key]?.contains(task.revision) == true else { throw LibraryArchiveIO.invalid }
            guard
                let json = try String.fetchOne(
                    db, sql: "SELECT revision_json FROM task_revisions WHERE task_id = ? AND revision = ?",
                    arguments: [key, task.revision]),
                json.utf8.count <= 131_072
            else { throw LibraryArchiveIO.invalid }
            let revision: TaskRevision = try decode(json)
            guard revision.task.id == task.id,
                revision.task.workspaceID == task.workspaceID,
                revision.task.draft == task.draft,
                revision.task.status == task.status,
                revision.task.revision == task.revision,
                revision.task.createdAt == task.createdAt,
                revision.task.updatedAt == task.updatedAt,
                revision.task.completedAt == task.completedAt,
                revision.task.evidence == task.evidence
            else { throw LibraryArchiveIO.invalid }
        }

        var proposalCount = 0
        try SQLiteArchiveValidation.rows(in: db, table: "task_proposals", maximumBytes: ["proposal_json": 131_072]) {
            row in
            guard proposalCount < LibraryArchiveLimits.maximumDomainRows else { throw LibraryArchiveIO.invalid }
            proposalCount += 1
            let proposal = try proposalRecord(row)
            try validateEvidence(proposal.evidence, workspaceID: proposal.workspaceID, journal: journal)
            if let taskID = proposal.taskID {
                guard tasks[id(taskID)] != nil else { throw LibraryArchiveIO.invalid }
            }
        }

        var operationCount = 0
        try SQLiteArchiveValidation.rows(
            in: db, table: "task_operations", maximumBytes: ["request_json": 131_072, "receipt_json": 131_072]
        ) { row in
            guard operationCount < LibraryArchiveLimits.maximumDomainRows else { throw LibraryArchiveIO.invalid }
            operationCount += 1
            _ = try validateTaskOperation(row, in: db)
        }
    }

    private static func validateEvidence(
        _ evidence: TaskEvidence, workspaceID: WorkspaceID?, journal: SQLiteArchiveSessions
    ) throws {
        try evidence.validate()
        let user = try journal.validate(evidence.source, workspaceID: workspaceID)
        guard user.admittedAt == evidence.sentAt, user.timeZoneIdentifier == evidence.timeZoneID,
            SHA256.hash(data: Data(evidence.quote.utf8)).map({ String(format: "%02x", $0) }).joined()
                == user.digest
        else {
            throw LibraryArchiveIO.invalid
        }
    }
}

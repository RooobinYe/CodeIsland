import Foundation

extension SessionSnapshot {
    /// Apply the model fields of a live transcript tail delta.
    ///
    /// Returns true when anything changed. Deliberately leaves `lastActivity`
    /// alone: a model label is not agent activity, so it must not reorder
    /// cards or postpone idle cleanup.
    public mutating func applyTranscriptMetadata(from delta: ConversationTailDelta) -> Bool {
        applyTranscriptMetadata(
            modelObservation: delta.modelObservation,
            longContextSwitch: delta.configuredLongContext,
            isBackfill: false
        )
    }

    /// Attach-time backfill from a scan of the transcript's tail. It is *not*
    /// authoritative for a model a hook reported after the scanned lines were
    /// written (see ``applyBackfilledModelObservation(_:)``).
    public mutating func applyTranscriptBackfill(_ scan: JSONLTailer.ScanResult.Delta) -> Bool {
        applyTranscriptMetadata(
            modelObservation: scan.modelObservation,
            longContextSwitch: scan.configuredLongContext,
            isBackfill: true
        )
    }

    /// A model/effort read from transcript history (not a live line): it
    /// yields to a model a hook reported after that line was written —
    /// `claude --resume --model X` over a transcript that ran on Y keeps X,
    /// and takes the line's effort only when the line was on X too.
    public mutating func applyBackfilledModelObservation(_ observation: ModelObservation) -> Bool {
        applyModelObservation(observation, isBackfill: true)
    }

    private mutating func applyTranscriptMetadata(
        modelObservation: ModelObservation?,
        longContextSwitch: Bool?,
        isBackfill: Bool
    ) -> Bool {
        var changed = false
        // A `/model` switch to or from the 1M variant. From history, only while
        // no hook has reported the model since: that report is newer.
        if let longContextSwitch, !(isBackfill && modelReportedAt != nil) {
            configuredLongContext = longContextSwitch
            if let current = model {
                let switched = ModelLabel.withLongContext(current, longContextSwitch)
                if switched != current {
                    model = switched
                    changed = true
                }
            }
        }

        if let modelObservation, applyModelObservation(modelObservation, isBackfill: isBackfill) {
            changed = true
        }
        return changed
    }

    private mutating func applyModelObservation(_ observation: ModelObservation, isBackfill: Bool) -> Bool {
        if isBackfill, let reportedAt = modelReportedAt,
           (observation.observedAt ?? .distantPast) < reportedAt {
            guard ModelLabel.isSameModel(current: model, observed: observation.model),
                  observation.effort != reasoningEffort else { return false }
            reasoningEffort = observation.effort
            return true
        }
        var changed = false
        // Transcript lines carry the bare API id; after a `/model` switch its
        // word on the 1M variant decides the decoration, otherwise a
        // hook-reported `[1m]` id of the same model survives.
        let mergedModel = configuredLongContext.map { ModelLabel.withLongContext(observation.model, $0) }
            ?? ModelLabel.mergedModelId(current: model, observed: observation.model)
        if mergedModel != model {
            model = mergedModel
            changed = true
        }
        if observation.effort != reasoningEffort {
            reasoningEffort = observation.effort
            changed = true
        }
        return changed
    }

    /// "Opus 5.5 · xhigh" for the card's model tag.
    public var modelLabel: String? {
        ModelLabel.label(model: model, effort: reasoningEffort)
    }
}

extension SubagentState {
    /// A Claude subagent's own transcript, derived from the parent's:
    /// `<project>/<session>.jsonl` → `<project>/<session>/subagents/agent-<id>.jsonl`.
    /// Claude Code hooks never say which model a subagent runs, so this file is
    /// the only place its model (which may differ from the parent's) is recorded.
    public static func claudeTranscriptPath(parentTranscriptPath: String, agentId: String) -> String? {
        let suffix = ".jsonl"
        guard parentTranscriptPath.hasSuffix(suffix),
              !agentId.isEmpty, !agentId.contains("/"), !agentId.contains("..") else { return nil }
        let sessionDir = String(parentTranscriptPath.dropLast(suffix.count))
        return "\(sessionDir)/subagents/agent-\(agentId).jsonl"
    }

    /// Label for the subagent's own model, never the parent's.
    public var modelLabel: String? {
        ModelLabel.label(model: model, effort: reasoningEffort)
    }
}

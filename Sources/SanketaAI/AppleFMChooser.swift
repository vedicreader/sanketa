import Foundation
import FoundationModels
import SanketaCore

/// Apple Foundation Models (`.default` use case) as a chooser; it runs on this Mac only.
public struct AppleFMChooser: Choosing {
    public let name = "Apple Intelligence"
    public let isRemote = false
    let model: SystemLanguageModel
    let availability: @Sendable () -> SystemLanguageModel.Availability

    public init(model: SystemLanguageModel = .default) {
        self.init(model: model, availability: { model.availability })
    }

    init(model: SystemLanguageModel = .default, availability: @escaping @Sendable () -> SystemLanguageModel.Availability) {
        self.model = model; self.availability = availability
    }

    public func status() -> ModelStatus {
        switch availability() {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .unavailable("this Mac cannot run Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable("Apple Intelligence is off")
        case .unavailable(.modelNotReady): return .unavailable("Apple Intelligence model not ready")
        @unknown default: return .unavailable("Apple Intelligence unavailable")
        }
    }

    /// `{picks: [one of refs]}` with at most `maxPicks` items.
    public static func schema(refs: [String], maxPicks: Int) throws -> GenerationSchema {
        try GenerationSchema(root: DynamicGenerationSchema(name: "Choice", properties: [
            .init(name: "picks", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(name: "Ref", anyOf: refs),
                                                                 minimumElements: 0, maximumElements: maxPicks)),
        ]), dependencies: [])
    }

    public func choose(_ prompt: ChoicePrompt) async throws -> [String] {
        guard !prompt.refs.isEmpty else { return [] }
        try Task.checkCancellation()
        let session = LanguageModelSession(model: model, instructions: prompt.instructions)
        // the schema in the prompt makes the model answer with an empty list; the prompt already gives the format
        do {
            let r = try await session.respond(to: prompt.userText, schema: Self.schema(refs: prompt.refs, maxPicks: prompt.maxPicks),
                                              includeSchemaInPrompt: false,
                                              options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 64))
            try Task.checkCancellation()
            return try r.content.value([String].self, forProperty: "picks")
        } catch {
            throw Self.mapped(error)
        }
    }

    /// A too-long prompt gives `.contextExceeded`, so the router retries with fewer entries; a guardrail or a refusal
    /// gives `.notAllowed` ("refused the request"). Other errors stay as they are.
    static func mapped(_ e: Error) -> Error {
        switch e as? LanguageModelSession.GenerationError {
        case .exceededContextWindowSize: return ChoiceError.contextExceeded
        case .guardrailViolation, .refusal: return ChoiceError.notAllowed
        default: return e
        }
    }

    /// Loads the model ahead of the first request; the first call in a process is about 3 s without it.
    public func prewarm() {
        guard status() == .available else { return }
        let p = ChoicePrompt(task: .search(""), refs: [], lines: [], maxPicks: SmartSearch.maxPicks)
        LanguageModelSession(model: model, instructions: p.instructions).prewarm(promptPrefix: Prompt("Request: "))
    }
}

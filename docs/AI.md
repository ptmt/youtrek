# AI Integration Plan (FoundationModels SystemLanguageModel)

## Goals
- Provide AI assistance during issue creation (title, summary, acceptance criteria, labels, priority, assignee suggestions).
- Keep all AI processing on-device, private, and offline-capable.
- Ensure AI is always optional and never auto-submits without explicit user review.

## Why FoundationModels + SystemLanguageModel
- FoundationModels gives on-device access to Apple's system language model.
- It runs on-device, is offline, and does not increase app size.
- It supports structured output (Generable), tool calling, and streaming output.

## Entry Points
- New Issue toolbar input: "AI Assist" button to expand a panel.
- Issue detail editor: "Improve/Rewrite" and "Summarize" actions.
- Optional background assist: auto-suggest labels/priority after the user types a short draft.

## Integration Plan

### 1) Availability gating
- Use `SystemLanguageModel.default` and check `model.availability`.
- If unavailable, show a clear message and keep standard issue creation flow.
- Explicitly handle the "Apple Intelligence not enabled" case.

### 2) Data contracts for AI
- Define a structured result type for issue creation:
  - `IssueAISuggestion`: title, summary, description, acceptanceCriteria, labels, priority, assignee, dueDate (optional), confidence, rationale.
- Mark the type as `Generable` so the model returns structured output.
- Provide a "partial" version for streaming updates if needed.

### 3) Prompting strategy
- Use a short instruction prompt that defines the role and required output schema.
- Provide a minimal input context: user's draft text, selected project, available labels, assignees.
- Keep prompts stable to reduce variance and keep results consistent.

### 4) Tool calling for app-specific data
- Create tools that expose local data to the model:
  - `listProjects()` -> [Project]
  - `listLabels(projectId)` -> [Label]
  - `listAssignees(projectId)` -> [User]
  - `templateFor(projectId)` -> IssueTemplate
- The model chooses when to call tools; the tools read from the local store.

### 5) Session lifecycle
- Create a `LanguageModelSession` per request to keep prompts scoped.
- Optionally prewarm the session when the "New Issue" panel opens to reduce latency.
- Cancel in-flight tasks if the user closes the sheet or edits the draft.

### 6) Streaming UX
- Stream partial results so the UI can render suggestions progressively.
- Show a small "Generating..." indicator and update sections as they arrive.
- Always allow manual edits; AI results should be editable inline.

### 7) Safety and guardrails
- Never auto-submit or auto-assign; require user confirmation.
- Highlight generated content and offer "Accept" / "Discard" per field.
- Keep AI output local; do not send drafts or responses to the network.

### 8) Performance and profiling
- Profile latency and responsiveness while iterating on prompts and UI.
- Keep instructions concise; avoid sending large context.

### 9) Testing plan
- Unit tests for prompt assembly and schema validation.
- Model-availability UI tests to confirm all states render correctly.
- Manual smoke test: create issue with AI assist enabled and verify edits apply.

## UI Sketch (Issue Creation)
1. User opens "New Issue".
2. User enters a short draft or bullet list.
3. User taps "AI Assist".
4. App checks availability and runs the session.
5. Structured suggestions appear, each with Accept/Discard.
6. User edits and submits the final issue.

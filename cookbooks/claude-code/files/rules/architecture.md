# Architecture Discussion Gates

## Cross-Repo Design Decisions

When a task spans 2+ repositories and involves shared contracts (protocol schemas, MQTT topic structure, API interfaces, event formats, shared data models), stop before implementing and use AskUserQuestion to surface the design decision.

Trigger: before writing code that defines a shared contract, ask:
"This defines a shared contract between [A] and [B]. Proposed design: [x]. Adjust before I implement?"

## Architecture Before Implementation

When creating a new system layer (binary, service, routing engine):
1. Name the component
2. Define its single responsibility
3. Define inputs, outputs, and interaction with existing components
4. AskUserQuestion to confirm — then implement

Architecture reviews are free. Post-implementation redesigns cost sessions.

## SDK vs. Consumer Distinction

SDK must be independently useful without any specific consumer.
Consumer-specific logic belongs in the consumer binary, not the SDK.
When unsure which layer a feature belongs to, ask before placing it.

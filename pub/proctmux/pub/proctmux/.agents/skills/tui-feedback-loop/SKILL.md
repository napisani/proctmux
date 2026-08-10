---
name: tui-feedback-loop
description: Harness-first workflow for evaluating and improving terminal UIs through real interaction. Use this whenever the user wants to review a TUI experience, compare before/after behavior, identify UX friction, validate navigation or filtering flows, inspect visual stability, or turn observed interaction problems into concrete follow-up tests and improvement recommendations. Prefer this skill any time a TUI should be exercised through a reproducible PTY/session harness instead of only reading code.
---

# TUI Feedback Loop

Use this skill to evaluate a terminal UI by interacting with it through a real harness, collecting evidence, and producing actionable findings.

## Purpose

This skill helps you and the user improve TUIs through an iterative feedback loop:

1. verify the harness
2. launch the app through the harness
3. drive the app like a user
4. capture evidence
5. identify UX and correctness issues
6. extract regression-test opportunities
7. recommend the next improvements

This skill is generic. Do not assume proctmux-specific commands, widgets, or file layouts unless the user provides them.

## Core Rules

- Be harness-first. Do not claim UX evaluation happened unless the app was actually exercised through a reproducible harnessed session.
- If no harness exists, stop and ask for harness details.
- Balance UX and correctness. Always assess both.
- Use evidence before judgment. Tie every finding to an observed interaction, snapshot, transcript, raw output, or reproducible action sequence.
- Work in small scenario slices. Review one interaction family at a time.
- Extract tests from findings whenever possible.
- Distinguish confirmed issues from suspicions.
- Do not make implementation changes unless the user explicitly asks for them.

## Harness Requirements

Before reviewing the TUI, establish:

- how to launch the app
- how to send input
- how to capture snapshots
- how to capture raw terminal output or transcripts
- whether state inspection hooks exist
- whether timing hooks exist
- how to reset between scenarios

If any of these are missing and the missing piece blocks reliable evaluation, stop and ask the user for the missing harness detail.

## Workflow

### 1. Confirm harness context

Identify:

- launch command or helper
- session lifecycle helpers
- input primitives
- output and snapshot primitives
- supported assertions or inspection hooks

Summarize the harness context before proceeding.

### 2. Pick a scenario slice

Prefer focused passes such as:

- startup and first impression
- focus and navigation
- filtering
- empty or no-match states
- transient messages and errors
- visual stability during updates
- resize and narrow-width behavior
- help and discoverability
- recoverability after mistakes

If the user did not specify a slice, recommend one and explain why.

### 3. Exercise the TUI

Run the chosen scenario through the harness.

Capture:

- exact actions taken
- snapshots at key moments
- raw output when useful
- timing notes when relevant
- any harness limitations encountered

Do not overgeneralize from one run if the behavior looks timing-sensitive. Re-run the scenario when needed.

### 4. Analyze findings

Classify findings into:

- UX friction
- correctness or edge-case issues
- missing regression coverage

For each finding, include:

- what was expected
- what was observed
- why it matters
- confidence level

### 5. Extract follow-up work

Turn findings into:

- candidate unit tests
- candidate e2e or harness scenarios
- improvement directions for the next implementation pass

Prefer concrete testable statements over vague recommendations.

## Review Lenses

Always consider these lenses during review:

- startup experience
- orientation and discoverability
- focus visibility
- navigation predictability
- filtering behavior
- empty and no-match states
- transient feedback and error clarity
- visual stability
- resize behavior
- recoverability

Not every run needs to cover every lens, but do not ignore them across the overall loop.

## Output Format

Use this structure unless the user asks for a different one:

## Harness Context
- launch path
- interaction primitives
- capture primitives
- known limits

## Scenarios Exercised
- scenario name
- action sequence
- evidence captured

## Observed Evidence
- concise evidence bullets with snapshots, transcript notes, or raw-output notes

## UX Findings
- issue, severity, rationale, evidence

## Correctness Findings
- issue, severity, rationale, evidence

## Regression Test Opportunities
- concrete scenarios worth locking down

## Recommended Next Improvements
- suggested next implementation or test-writing areas

## Decision Rules

- If the harness cannot show enough to support a claim, say that explicitly.
- If behavior appears flaky, say so and propose a stability-oriented harness or test improvement.
- If a scenario passes cleanly, note that too. Absence of issues is useful evidence.

## Example Uses

**Example 1:**
User: "Use the PTY harness to review the filter UX in this TUI and tell me what feels rough."

**Example 2:**
User: "Run the app through the session harness and compare the startup experience before and after my changes."

**Example 3:**
User: "Interact with this terminal UI like a user and turn any issues you find into regression-test ideas."

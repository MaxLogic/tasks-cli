# Explicit proof coverage

Historical gates with only `commands` retain their literal-command validation.
Do not rewrite old evidence into the new representation. New gates whose actual
execution differs from their scheduled requirements may add both `executions`
and `coverage`. In this form `commands` lists only fresh commands, in execution
order without duplicates; it may be empty for a wholly reused gate.

```json
{
  "commands": ["combined tests"],
  "executions": {
    "fresh": {
      "command": "combined tests", "exit_code": 0, "duration_seconds": 2,
      "candidate": "current-candidate", "input_hash": "current-source-and-proof",
      "evidence_ref": "proof.md#combined", "cases": ["list-rejects-invalid", "list-valid"]
    },
    "detail": {
      "command": "detail tests", "exit_code": 0, "duration_seconds": 1,
      "candidate": "historical-candidate", "input_hash": "unchanged-detail-inputs",
      "evidence_ref": "proof.md#detail", "cases": ["detail-valid"],
      "reused_from": "original-gate", "reuse_reason": "All consumed detail inputs unchanged"
    }
  },
  "coverage": [{
    "requirement": "scheduled boundary proof", "execution_ids": ["fresh", "detail"],
    "input_hashes": {"fresh": "current-source-and-proof", "detail": "unchanged-detail-inputs"},
    "required_cases": ["list-rejects-invalid", "list-valid", "detail-valid"],
    "reason": "Combined and retained cases satisfy the agreed command's acceptance"
  }]
}
```

The normal gate status, candidate, duration, exit code and task input fields
remain required. Here the gate's exit code is the acceptance/aggregation result;
each execution preserves its native exit code. Gate duration covers fresh work,
not the sum of historical durations. Map every scheduled literal requirement
exactly once; every execution must contribute. Current `input_hashes` must match
the corresponding executions, including consumed shared source, fixtures,
toolchain, options, environment/external state and required review stage. Hashes
must be derived, not guessed. References must resolve to real proof; the validator
checks declared consistency, not artifact truth, fingerprints or completeness
of a human-chosen case list. These still require owner review.

Only explicitly approved inherited compiler/typed-lint diagnostics may retain
a nonzero execution result at task/batch tier. Set execution `kind` to
`compiler` or `typed_lint` and retain:

```json
{"qualification": {"kind": "inherited_diagnostics", "in_scope_diagnostics": 0,
 "approved_by": "<actual user or repository policy>", "evidence_ref": "<individual diagnostic reconciliation>"}}
```

This is qualified acceptance, not a successful compiler run. Tests, unavailable
tools and bad configurations cannot qualify. A Final gate rejects every native
nonzero result, regardless of qualification; historical qualified task evidence
is not rewritten when later Final proof establishes zero diagnostics.

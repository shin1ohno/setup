# Sub-agent Design Principles — Examples & Origin Notes

## parallel-stream-file-exclusivity

Origin: 2026-05-09 two parallel streams both created the same cookbook file; one full PR cycle wasted on the merge conflict.

## destructive-operation-scope-boundary

Origin: 2026-05-09 an agent read "consolidate dashboards" as license to delete predecessor saved objects outside its task scope.

## analysis-only-agent-scope

**Why "no immediate error" is insufficient**: an agent fixing a collection/serialization bug in a typed framework (Terraform provider, GraphQL resolver, protobuf/JSON codec) may eliminate the observable crash while introducing a subtler invariant violation — wrong list order, missing element, schema mismatch — that fails differently on a different code path. An adversarial verifier that only checks "did the panic go away?" misses it; it must check the framework's actual contract (e.g. for a Terraform list of a Required attribute, the applied value must equal the plan element-by-element in order and count).

Origin: 2026-05-31 an analysis agent stopped a panic but broke the plan-order contract; the adversarial Verify phase accepted it.

Origin: 2026-06-01 a synthesis agent restarted a production service with an unvalidated config during the analysis phase.

## fleet-status-verification

Origin: 2026-06-01 a fleet agent reported 19/19 HEALTHY via `systemctl is-active` while emission had stopped.

## tool-availability-toolsearch

Origin: 2026-05-09 a stream blocked itself reporting SendMessage/EnterPlanMode unavailable — both reachable via ToolSearch.

## bulk-research-pattern

```
Example: "Save all reviews from this page" → launch sub-agents per category in background
Example: "Look up all reviews for this brand" → 1 agent per brand in background
Example: "Find bindings for this board" → 1 agent per brand group in background
```

## background-agent-deadline-tracking

Origin: 2026-04-23 two consecutive Ultraplan agents failed silently; the user had to notice and restart.

## 60-second-rule

Origin: 2026-04-23 attempted `docker compose up -d --build` inline as a foreground Bash call; user corrected "時間がかかるタスクは SubAgent で".

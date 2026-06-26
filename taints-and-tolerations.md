# Kubernetes Taints & Tolerations — Reference

## How operator Controls Strictness

`operator` is the **strictness dial** — it decides whether `value` even counts.

| `operator` | What it actually checks |
|------------|------------------------|
| `Equal`    | `key` must match exactly, **and** `value` must match exactly |
| `Exists`   | `key` must match (or even `key` can be skipped for a total wildcard) — `value` is **never even looked at** |

### Field-by-Field Breakdown

| Field    | `operator: Equal`                              | `operator: Exists`                              |
|----------|------------------------------------------------|--------------------------------------------------|
| `key`    | must match                                     | must match (unless also left blank → wildcard)   |
| `value`  | must match                                     | **never checked, ignored entirely**              |
| `effect` | must match (unless left blank → any effect)    | must match (unless left blank → any effect)      |

> **Key insight:** `operator` has exactly one job — deciding whether `value` matters.
> `key` and `effect` follow their own independent rule: match exactly, or be deliberately
> left blank to mean "any."

### Why This Explains Real-World Behavior

- **kube-proxy's wildcard toleration** is just `operator: Exists` with no `key`, no `value` — the loosest possible setting, matches anything.
- **CoreDNS's patched toleration** is `operator: Exists` with a `key`, no `value` — strict on key, loose on value.
- **Scenario 2 below** (wrong value, blocked) only failed because it used `operator: Equal` — if it had used `Exists` instead, that same mismatched value would've been ignored and it would've passed.

---

## 20 Worked Match Scenarios

Each row: the taint(s) on the node, the toleration(s) on the pod, and the
outcome — with the reasoning spelled out.

---

### 1. Exact match, Equal operator

| | |
|---|---|
| **Node taint** | `CriticalAddonsOnly=true:NoSchedule` |
| **Pod toleration** | `key=CriticalAddonsOnly, operator=Equal, value=true, effect=NoSchedule` |
| **Result** | ✅ Scheduled |

**Why:** `Equal` demands `key`, `value`, and `effect` all line up exactly — and
here every one of the three does.

---

### 2. Wrong value, Equal operator

| | |
|---|---|
| **Node taint** | `CriticalAddonsOnly=true:NoSchedule` |
| **Pod toleration** | `key=CriticalAddonsOnly, operator=Equal, value=false, effect=NoSchedule` |
| **Result** | ❌ Blocked |

**Why:** `key` and `effect` match, but `Equal` also checks `value`, and
`true ≠ false`. One mismatched field is enough to fail the whole check.

---

### 3. Exists operator, value ignored

| | |
|---|---|
| **Node taint** | `CriticalAddonsOnly=true:NoSchedule` |
| **Pod toleration** | `key=CriticalAddonsOnly, operator=Exists` (no value given) |
| **Result** | ✅ Scheduled |

**Why:** `Exists` only checks the `key`. The taint's `value` is never even
inspected, so it doesn't matter what it is.

---

### 4. No toleration at all

| | |
|---|---|
| **Node taint** | `CriticalAddonsOnly=true:NoSchedule` |
| **Pod toleration** | none |
| **Result** | ❌ Blocked |

**Why:** The pod has nothing to compare against this taint. Absence of any
toleration means every taint on the node blocks it by default.

---

### 5. Wildcard toleration — no key, no value

| | |
|---|---|
| **Node taint** | `CriticalAddonsOnly=true:NoSchedule` |
| **Pod toleration** | `operator=Exists` (key left blank) |
| **Result** | ✅ Scheduled |

**Why:** Leaving the `key` blank under `Exists` means "match any key
whatsoever." This is the exact pattern **kube-proxy**, **vpc-cni**, and
**eks-pod-identity-agent** ship with.

---

### 6. Wrong key entirely

| | |
|---|---|
| **Node taint** | `CriticalAddonsOnly=true:NoSchedule` |
| **Pod toleration** | `key=SpotInstance, operator=Exists` |
| **Result** | ❌ Blocked |

**Why:** This toleration was built to answer a completely different taint.
It never successfully compares against `CriticalAddonsOnly`.

---

### 7. Effect mismatch

| | |
|---|---|
| **Node taint** | `CriticalAddonsOnly=true:NoSchedule` |
| **Pod toleration** | `key=CriticalAddonsOnly, operator=Equal, value=true, effect=NoExecute` |
| **Result** | ❌ Blocked |

**Why:** `key` and `value` match, but the toleration is scoped to `NoExecute`
while the taint's actual effect is `NoSchedule`. Effects must align too.

> **Test case — what if `operator` is changed to `Exists` here?**
>
> Toleration becomes: `key=CriticalAddonsOnly, operator=Exists, effect=NoExecute`
>
> - Check 1 — **key**: `CriticalAddonsOnly` = `CriticalAddonsOnly` → ✅ Match
> - Check 2 — **operator says skip value**: `Exists` → value never inspected → ✅ Passes automatically
> - Check 3 — **effect**: `NoExecute` ≠ `NoSchedule` → ❌ **Mismatch**
>
> **Result: still blocked.** `Exists` only relaxes the `value` check; it does
> nothing to relax the `effect` check. Effect always has to line up (or be left
> blank) regardless of which operator you use.

---

### 8. Effect left blank on the toleration

| | |
|---|---|
| **Node taint** | `CriticalAddonsOnly=true:NoSchedule` |
| **Pod toleration** | `key=CriticalAddonsOnly, operator=Exists` (no effect given) |
| **Result** | ✅ Scheduled |

**Why:** An omitted `effect` on a toleration means "match this key under any
effect." Combined with `Exists`, this is close to a full pass for that key.

---

### 9. Two taints on the node, pod tolerates only one

| | |
|---|---|
| **Node taints** | `CriticalAddonsOnly=true:NoSchedule` **and** `spot=true:NoSchedule` |
| **Pod toleration** | `key=CriticalAddonsOnly, operator=Exists` |
| **Result** | ❌ Blocked |

**Why:** A node with multiple taints requires **every single one** to be
satisfied. The `spot` taint has no matching toleration here, so the pod
is still turned away — tolerating one of two locks isn't enough.

---

### 10. Two taints, pod tolerates both

| | |
|---|---|
| **Node taints** | `CriticalAddonsOnly=true:NoSchedule` **and** `spot=true:NoSchedule` |
| **Pod tolerations** | `key=CriticalAddonsOnly, operator=Exists` **and** `key=spot, operator=Exists` |
| **Result** | ✅ Scheduled |

**Why:** Each taint now has its own dedicated matching toleration. Once
every lock on the door has a matching badge, the pod is allowed through.

---

### 11. No taint on the node at all

| | |
|---|---|
| **Node taint** | none |
| **Pod toleration** | none |
| **Result** | ✅ Scheduled |

**Why:** With no lock on the door, there is nothing to tolerate. This is the
default, open state of a Karpenter app NodePool with no taints block.

---

### 12. Toleration present, but node has no matching taint

| | |
|---|---|
| **Node taint** | none |
| **Pod toleration** | `key=CriticalAddonsOnly, operator=Exists` |
| **Result** | ✅ Scheduled |

**Why:** Carrying a badge never requires a locked door to use it on. An
unused toleration is harmless — it just means nothing happens with it on
this particular node. This is also the proof that **tolerating ≠ preferring**:
without a `nodeSelector`, this pod could land on any node, tainted or not.

---

### 13. PreferNoSchedule, no toleration

| | |
|---|---|
| **Node taint** | `team=ml:PreferNoSchedule` |
| **Pod toleration** | none |
| **Result** | ⚠️ Scheduled, but discouraged |

**Why:** `PreferNoSchedule` is the **soft** effect. The scheduler tries to place
the pod elsewhere first, but will still use this node if there's no
better candidate available.

---

### 14. NoExecute added to an already-running pod

| | |
|---|---|
| **Node taint** | `maintenance=true:NoExecute` (added live, e.g. for draining) |
| **Pod toleration** | none |
| **Result** | ❌ Evicted |

**Why:** `NoExecute` is the **strict** effect — it doesn't just block new
scheduling, it actively removes pods that are already running and don't
tolerate it.

---

### 15. NoExecute with tolerationSeconds

| | |
|---|---|
| **Node taint** | `maintenance=true:NoExecute` |
| **Pod toleration** | `key=maintenance, operator=Exists, effect=NoExecute, tolerationSeconds=300` |
| **Result** | ⏱️ Scheduled, then evicted after 300 seconds |

**Why:** `tolerationSeconds` grants a grace period. The pod is allowed to
keep running temporarily, then Kubernetes evicts it once the timer
expires — useful for controlled, graceful drains.

---

### 16. CoreDNS, default, before patching

| | |
|---|---|
| **Node taint** | `CriticalAddonsOnly=true:NoSchedule` (on every node, e.g. only a system node group exists) |
| **Pod toleration** | none (CoreDNS's out-of-the-box spec) |
| **Result** | ❌ Blocked — stuck Pending |

**Why:** AWS's default CoreDNS addon ships with **zero tolerations**. If every
node a CoreDNS pod could land on carries this taint, it has nowhere to go.

---

### 17. CoreDNS, after patching

| | |
|---|---|
| **Node taint** | `CriticalAddonsOnly=true:NoSchedule` |
| **Pod toleration** | `key=CriticalAddonsOnly, operator=Exists` (added via `configuration_values` on the addon) |
| **Result** | ✅ Scheduled |

**Why:** The one toleration added in Terraform closes the exact gap from
scenario 16. Paired with `nodeSelector: node-role: system`, CoreDNS now
lands specifically on the system node group.

---

### 18. kube-proxy, default DaemonSet behavior, multiple taints present

| | |
|---|---|
| **Node taints** | `CriticalAddonsOnly=true:NoSchedule` **and** `karpenter.sh/disruption=draining:NoSchedule` |
| **Pod toleration** | `operator=Exists` (built-in wildcard) |
| **Result** | ✅ Scheduled |

**Why:** The wildcard toleration matches any key, so it doesn't matter how
many different taints exist across system nodes or Karpenter nodes —
kube-proxy runs everywhere regardless.

---

### 19. Karpenter NodePool taint, ordinary app pod without a toleration

| | |
|---|---|
| **Node taint** | `dedicated=gpu:NoSchedule` (on a dedicated GPU NodePool) |
| **Pod toleration** | none |
| **Result** | ❌ Blocked |

**Why:** Tainting a specialized Karpenter pool — GPU instances, for example —
keeps ordinary, cost-sensitive app pods from accidentally landing on
expensive nodes they don't actually need.

---

### 20. GPU workload pod, tolerating the GPU taint

| | |
|---|---|
| **Node taint** | `dedicated=gpu:NoSchedule` |
| **Pod toleration** | `key=dedicated, operator=Equal, value=gpu, effect=NoSchedule` |
| **Result** | ✅ Scheduled |

**Why:** This pod was deliberately built to request GPU nodes, and its
toleration exactly matches the GPU pool's taint. Ordinary app pods
without this toleration remain excluded, exactly as intended.

---

## Quick Reference — The Three Effects

| Effect | Scheduling | Running pods |
|--------|-----------|--------------|
| `NoSchedule` | ❌ Blocked | ✅ Unaffected (existing pods stay) |
| `PreferNoSchedule` | ⚠️ Discouraged (soft) | ✅ Unaffected |
| `NoExecute` | ❌ Blocked | ❌ Evicted (unless tolerated with optional `tolerationSeconds`) |

---

## Relevance to This Project

In `eks.tf`, the system node group previously had:

```hcl
taints = {
  system_only = {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }
}
```

This caused **Scenario 16** — CoreDNS (which ships with zero tolerations) could
not schedule on the only available nodes, leaving them unhealthy and causing
`NodeCreationFailure`. The taint was removed to allow all system add-ons to
schedule normally. Karpenter handles workload node isolation separately via
its own NodePool taints.

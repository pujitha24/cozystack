# System Component Memory Limits

Cozystack gives every container in a system namespace a memory limit, and sets explicit requests and limits on the node DaemonSets. This page explains why that is not merely resource hygiene, how to tune it, and what it deliberately does not cover.

## Why a memory limit, and not a PriorityClass

Talos Linux v1.12 introduced a userspace OOM handler that reacts to memory pressure before the kernel OOM killer does. It walks cgroupfs directly and never talks to the API server, so `PriorityClass` — including `system-node-critical` — has no influence on it whatsoever. Setting one on a system component looks like a fix and does nothing. Kubelet eviction ranking does honour priority, but kubelet eviction is not what kills these pods.

The handler scores each pod cgroup with a CEL expression. The default in Talos v1.13.x is:

```
memory_max.hasValue() ? 0.0 :
  {Besteffort: 1.0, Burstable: 0.5, Guaranteed: 0.0, Podruntime: 0.0, System: 0.0}[class] *
    double(memory_current.orValue(0u))
```

Any cgroup scoring zero is dropped from the candidate set entirely. A pod whose containers all carry a memory limit has `memory.max` set on its pod cgroup, scores `0.0`, and can never be selected. A pod without one stays a candidate no matter how little memory it is using.

Three consequences follow, and all three are easy to get wrong:

- Only a **limit** grants immunity. A memory **request** merely moves the pod from BestEffort to Burstable, which under the v1.13.6 default `strictCgroupClassOrdering: true` means "killed second" rather than "not killed".
- **Every** container in the pod needs a limit, init containers included. Kubelet only sets pod-level `memory.max` when all of them have one, so a single limit-free sidecar puts the whole pod back in the candidate set.
- CPU limits are irrelevant here. The handler reads only `memory.max`, `memory.current` and `memory.peak`.

Victim selection is also decoupled from the trigger. The cgroup that caused the pressure and the cgroup that gets `SIGKILL`ed are unrelated by design. In practice tenant workloads carry limits and system components historically did not, which inverted the intended order: a tenant workload thrashing against its own 32 GB limit would drive node-wide memory PSI, and `metallb-speaker` or `linstor-satellite` — using a few dozen megabytes and entirely uninvolved — would be killed for it, every 10 to 15 seconds, until the pressure subsided.

## What Cozystack does

**A default LimitRange in every system namespace.** The `cozystack-operator` maintains a `LimitRange` named `cozystack-system-defaults` alongside each namespace it creates, defaulting container memory for anything that declares none. This is the layer that actually closes the problem, because it covers current components, components added later, and containers whose upstream chart exposes no `resources` knob.

**Explicit requests and limits on node DaemonSets.** Charts additionally set real values on the DaemonSets that run on every node — cilium, metallb speaker and frr-k8s, kube-ovn, linstor-satellite, virt-handler, fluent-bit, node-exporter, multus, velero node-agent, kubevirt-csi-node. Requests there give the scheduler a real signal; the LimitRange cannot do that, because a request defaulted to a useful value would have to be defaulted to the limit.

Tenant namespaces deliberately get **no** LimitRange. A tenant workload running without a memory limit should remain an eviction candidate — that is the upstream design working as intended, and it is what restores the ordering the incident inverted.

## Tuning

Two installer values, both empty by default so the operator's own defaults apply:

| Value | Operator flag | Default |
|---|---|---|
| `cozystackOperator.systemNamespaceMemoryLimit` | `--system-namespace-memory-limit` | `4Gi` |
| `cozystackOperator.systemNamespaceMemoryRequest` | `--system-namespace-memory-request` | `32Mi` |

The limit is a ceiling, not a reservation, so it is deliberately set far above real usage — the point is that `memory.max` exists, not that it binds. Raising it is close to free; lowering it is where the risk lives.

**The limit must stay above the largest memory request in any system namespace.** A defaulted limit below a container's own request is rejected at admission, and the pod simply will not start. Check before lowering it:

```bash
kubectl get pods -A -o json \
  | jq -r '.items[] | select(.metadata.namespace|test("^cozy-"))
      | .metadata.namespace as $ns
      | [.spec.containers[], (.spec.initContainers//[])[]]
      | .[] | select(.resources.requests.memory != null)
      | "\($ns)\t\(.name)\t\(.resources.requests.memory)"' \
  | sort -u
```

**Keep the request small and never unset it.** Kubernetes defaults an unset request to the limit, so clearing `systemNamespaceMemoryRequest` while a limit is in force would have every system container reserve the full limit at schedule time.

Setting the limit to `0` disables the feature and removes the LimitRanges the operator previously created, so the knob is reversible.

A LimitRange only mutates at admission. Existing pods keep running without limits until they restart, so the protection lands progressively as workloads roll rather than the moment the setting is applied.

## Verifying

Confirm a pod cgroup actually carries `memory.max` — this is the property that matters, not the QoS class:

```bash
UID=$(kubectl get pod <pod> -n <ns> -o jsonpath='{.metadata.uid}')
NODE=$(kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.nodeName}')
kubectl debug node/$NODE --image=busybox:1.36 --profile=sysadmin -q -- \
  sh -c "cat /host/sys/fs/cgroup/kubepods/burstable/pod$UID/memory.max"
```

A value rather than `max` means the pod is out of the victim set. Note the QoS directory in the path changes with the pod's class (`besteffort`, `burstable`, `guaranteed`).

Inspect what the handler has actually killed:

```bash
talosctl -n <node> get oomactions
```

Once every eligible pod in a namespace carries a limit, the healthy signature in `talosctl -n <node> dmesg` is the controller still triggering under pressure but logging `no eligible cgroup to kill` with `ranked=0`. The trigger firing is not itself a fault.

## What this does not cover

**Kubernetes static pods.** `kube-apiserver`, `kube-controller-manager` and `kube-scheduler` are managed by Talos, not by any chart, and no LimitRange applies to them. Sizing those is a Talos machine-config matter.

**A handful of vendored containers with no upstream `resources` knob** — the four frr-k8s `cp-*` init containers, the kube-ovn `hostpath-init` and `install-cni` init containers, and `cozy-proxy`, whose chart exposes no resources value at all. These get their limit from the namespace LimitRange and nothing else, which is sufficient for OOM immunity but means they carry no request. Lifting that needs changes upstream.

**Optional components** `hami` and `kilo` carry no chart-level values, on the grounds that inventing numbers for components with no usage measurements behind them is worse than the blanket default.

## When the trigger itself is the problem

Giving system components limits stops them being *victims*. It does not stop the handler *triggering*, and a node under genuine sustained pressure will keep firing. The v1.13.6 default trigger is:

```
(multiply_qos_vectors(d_qos_memory_full_total, {System: 8.0, Podruntime: 4.0}) > 3000.0 &&
 multiply_qos_vectors(qos_memory_full_avg10, {System: 1.0, Podruntime: 1.0}) > 5.0 &&
 time_since_trigger > duration("5s")) ||
(memory_full_avg10 > 75.0 && time_since_trigger > duration("10s"))
```

The first clause is QoS-aware, added by [siderolabs/talos#12602](https://github.com/siderolabs/talos/pull/12602) to stop unrelated pressure from firing it. The second is a global-PSI backstop that is still cause-blind, and a single workload thrashing inside its own cgroup limit can drive root `memory_full` above 75 while the node has free RAM. The `10s` term makes that clause fire at most once per 10 seconds, which is a useful fingerprint when reading `dmesg`.

If a cluster trips the backstop persistently, it can be relaxed through an `OOMConfig` machine-config document — at the cost of raising the last-resort guard before the kernel OOM killer takes over:

```yaml
apiVersion: v1alpha1
kind: OOMConfig
triggerExpression: |-
  (multiply_qos_vectors(d_qos_memory_full_total, {System: 8.0, Podruntime: 4.0}) > 3000.0 &&
   multiply_qos_vectors(qos_memory_full_avg10, {System: 1.0, Podruntime: 1.0}) > 5.0 &&
   time_since_trigger > duration("5s")) ||
  (memory_full_avg60 > 90.0 && time_since_trigger > duration("60s"))
```

Prefer fixing the workload that is generating the pressure. Persistent triggering means a pod is sitting at its memory ceiling and reclaiming constantly, and raising that pod's limit addresses the cause rather than the symptom.

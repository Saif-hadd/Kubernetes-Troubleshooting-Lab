# 28 - CronJob concurrency / missed schedules

## Overview

A `CronJob` creates a `Job` on a schedule. Two failure modes bite production
teams:

1. **Overlap** — the job takes longer than the schedule interval and, with the
   default `concurrencyPolicy: Allow`, a new Job starts every tick while the
   previous one is still running. Work piles up, resource use spikes, and a
   slow job can multiply itself unbounded.
2. **Missed schedules** — after a control-plane pause (an upgrade, an outage)
   the controller may start *many* missed runs at once, or (with
   `startingDeadlineSeconds` too small) skip them entirely.

History limits (`successfulJobsHistoryLimit`, `failedJobsHistoryLimit`) add a
third: completed Jobs accumulate and, with their Pods and logs, bloat the API.

From an SRE perspective this is a **batch scheduling** failure: the individual
Job may be fine; the policy around it is not.

## Symptoms

- Many `report-*` Jobs and Pods running **at the same time** for one CronJob:
  ```bash
  kubectl get jobs -n ktslab
  ```
  ```
  NAME              COMPLETIONS   DURATION   AGE
  report-28994021   0/1           45s        45s
  report-28994020   0/1           105s       105s
  report-28994019   0/1           165s       165s
  ```
- A burst of Jobs starting at once after a control-plane pause.
- Old Jobs accumulating (`kubectl get jobs` grows without bound).

## Root Cause

- **`concurrencyPolicy: Allow` (default)** permits overlapping runs.
  When `job duration > schedule interval`, overlap is guaranteed.
- **No `startingDeadlineSeconds`** lets the controller attempt every missed
  schedule after a pause.
- **`successfulJobsHistoryLimit` / `failedJobsHistoryLimit`** default to a small
  number, but a misconfigured high value (or none) lets history grow.
- A Job with **no `activeDeadlineSeconds`/`backoffLimit`** can run (and retry)
  far longer than intended.

## Diagnosis

### 1. See the overlap

```bash
kubectl -n ktslab get jobs
kubectl -n ktslab get pods -l job-name --sort-by=.metadata.creationTimestamp
kubectl -n ktslab describe cronjob report | sed -n '/Events:/,$p'
```

Several Jobs `Running` at once for a single-minute schedule confirms overlap.

### 2. Check the policy and the interval

```bash
kubectl -n ktslab get cronjob report -o jsonpath='{.spec.schedule}{"  "}{.spec.concurrencyPolicy}{"  "}{.spec.startingDeadlineSeconds}{"\n"}'
```

Compare the schedule interval with the Job's real duration.

### 3. Check for missed-schedule bursts

```bash
kubectl -n ktslab get events --field-selector reason=FailedJob --sort-by=.lastTimestamp
kubectl -n ktslab get cronjob report -o yaml | grep -A5 status
```

`lastScheduleTime` gaps with a burst of Jobs afterwards indicate catch-up.

## Resolution

### Fix A — Forbid overlap

```yaml
spec:
  concurrencyPolicy: Forbid
```

A tick is skipped (not queued) while the previous Job runs. Use `Replace` only
if the newest run should cancel the old one.

### Fix B — Bound missed schedules

```yaml
spec:
  startingDeadlineSeconds: 30
```

Skip a run that is more than 30s late instead of starting a catch-up burst.

### Fix C — Bound the Job itself

```yaml
spec:
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 120
      template:
        spec:
          restartPolicy: OnFailure
```

### Fix D — Fix history limits

```yaml
spec:
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
```

### Verify

```bash
kubectl apply -f scenarios/28-cronjob-concurrency/cronjob-fixed.yaml
kubectl -n ktslab get jobs -w      # never more than one report Job running
kubectl -n ktslab get cronjob report
```

## Best Practices

- **Set `concurrencyPolicy` deliberately** — `Forbid` for jobs that must not
  overlap; the default `Allow` is rarely what you want.
- **Make the schedule interval longer than the job's worst-case duration**, or
  accept that runs are skipped (with `Forbid`) — never let them pile up.
- **Always set `startingDeadlineSeconds`** so a control-plane pause does not
  create a catch-up storm (and does not silently skip everything).
- **Bound jobs** with `activeDeadlineSeconds` and `backoffLimit` so one run
  cannot hang or retry forever.
- **Set history limits** and monitor Job/Pod counts; completed Jobs hold Pods
  and logs that cost API and etcd space.

## Production Tips

- A CronJob whose Jobs count grows over time is an overlap or a missing history
  limit — check `concurrencyPolicy` and the interval first.
- After a control plane outage, expect a burst of missed-schedule Jobs unless
  `startingDeadlineSeconds` is set; a "catch-up storm" can overload the cluster
  right when it is recovering.
- CronJobs use the **controller-manager's clock**, not a node's; timezone and
  clock skew matter. Pin `timeZone` explicitly on modern Kubernetes.
- Long-running or data-critical schedules are usually better as a Job driven by
  an external scheduler (Argo Workflows, Airflow) where retries, dependencies
  and idempotency are first-class — a CronJob is a blunt instrument.
- `suspend: true` is the clean way to pause a CronJob during maintenance rather
  than deleting it; remember to set `suspend` back and account for the missed
  window.

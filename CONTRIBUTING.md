# Contributing to Kubernetes Troubleshooting Lab

Thank you for investing your time in contributing to this project. Every
scenario, fix, and improvement makes this a better resource for the Kubernetes
and SRE community.

## Code of Conduct

Be respectful and constructive. We are all here to learn and share operational
knowledge. Harassment or dismissive behavior will not be tolerated.

## How to Contribute

### 1. Report a bug or suggest a scenario

Open a [GitHub Issue](../../issues) with:

- A clear title (e.g. `Scenario: kubelet PLEG is not healthy`).
- The symptom you observed (`kubectl` output is ideal).
- Your environment (Minikube / Kind / EKS, Kubernetes version).
- Why the existing scenarios do not cover it.

### 2. Improve an existing scenario

Small fixes (typos, clearer explanations, better commands) are always welcome.
For larger changes, please open an issue first to discuss the approach.

### 3. Add a new scenario

1. Pick the next number from the [Future Scenarios Roadmap](../../#future-scenarios-roadmap).
2. Create `scenarios/NN-kebab-case-name/` with at minimum:
   - `README.md` following the SRE template below.
   - `deployment.yaml` reproducing the failure.
   - `service.yaml` if the scenario is service-scoped.
   - Any additional manifests needed.
3. Add a row to the root [Scenarios](../../#scenarios) table.
4. Add a screenshot placeholder row in the root README.
5. Verify the scenario reproduces on Minikube or Kind.

### SRE README template

Every scenario README must include, in order:

```markdown
# <Scenario Title>

## Overview
## Symptoms
## Root Cause
## Diagnosis
## Resolution
## Best Practices
## Production Tips
```

### Manifest conventions

- Use `apps/v1`, `v1`, `networking.k8s.io/v1` — current stable APIs only.
- Always set `resources.requests` and `resources.limits`.
- Always set namespace, labels, and a single `app` label for selection.
- Include `livenessProbe` / `readinessProbe` where relevant.
- Manifests must reproduce the failure when `kubectl apply -f .` is run.
- Include the fix as a commented alternative or a separate `*-fixed.yaml`
  file so readers can diff the two.

## Style Guide

- Write in clear, professional English.
- Use fenced code blocks with the correct language tag (`bash`, `yaml`).
- Keep commands copy-pasteable; avoid placeholders without explaining them.
- Prefer exact `kubectl` output examples over prose.
- Explain the **why**, not just the **what**.

## Pull Request Process

1. Fork the repo and create a feature branch (`git checkout -b scenario/NN-name`).
2. Make your changes with clear commit messages.
3. Test your manifests: `kubectl apply -f scenarios/NN-name/` on a clean
   namespace.
4. Ensure the root README table of contents and scenario table are updated.
5. Open a Pull Request and link any related issue.
6. A maintainer will review. Please address feedback within the PR.

## Verification Checklist

- [ ] Manifests apply cleanly on Minikube / Kind
- [ ] `kubectl get` shows the described symptom
- [ ] `kubectl describe` events match the write-up
- [ ] Resolution steps actually fix the issue
- [ ] README follows the SRE template
- [ ] No secrets, real tokens, or customer data

Thank you for helping build a high-quality Kubernetes troubleshooting resource.

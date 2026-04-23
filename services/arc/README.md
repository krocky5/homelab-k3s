# arc/

Actions Runner Controller (ARC) — self-hosted GitHub Actions runners for the
`crucible` and `crucible-ops` repos, shared via user-level registration under
the `krocky5` account.

## Layout

| File                 | Purpose                                                     |
| -------------------- | ----------------------------------------------------------- |
| `namespace.yaml`     | Creates `arc-runners` namespace with restricted Pod Security. |
| `sealed-pat.yaml`    | SealedSecret containing the fine-grained PAT (added after PAT exists). |

The *controller* lives in `arc-systems` (see `argocd/apps/arc-controller-app.yaml`).
The *runner scale set* is a separate Application (`arc-runner-crucible-app.yaml`)
pointing at the `gha-runner-scale-set` Helm chart.

## Rotating the PAT

```bash
# 1. Generate a new fine-grained PAT at https://github.com/settings/personal-access-tokens
# 2. Re-seal:
kubectl -n arc-runners create secret generic crucible-arc-pat \
  --from-literal=github_token="$NEW_PAT" \
  --dry-run=client -o yaml \
  | kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system \
  > services/arc/sealed-pat.yaml
# 3. git commit services/arc/sealed-pat.yaml ; argocd picks it up.
```

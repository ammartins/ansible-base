# roles/dev-db-refresh

Refresh a **dev** database from its **production** source on the *same* MySQL engine,
scrub login credentials, and hand freshly generated dev credentials to a file you can read.

Built for: `tacoGathering` (prod) → `tacoGathering_dev` (dev/test) on `myvm1`.

## What it guarantees (enforced, not just documented)

| Risk | Guard |
|---|---|
| Refreshing prod by mistake | Target must **not** be in `dev_refresh_protected_databases` |
| Dumping a DB onto itself | `source != target` asserted |
| Filling the disk under MySQL | Dump target must be a **different device** than the MySQL datadir; `-e dev_refresh_allow_same_device=true` is required to override, and the run says so loudly |
| Silent prod writes | Everything is **dry-run** unless `-e dev_refresh_apply=true` |
| Prod sessions working in dev | `beaker_sessions` truncated; `decks.share_token` nulled |
| Prod passwords working in dev | Selected accounts get **regenerated** passwords; other auth columns nulled |
| Secrets in logs/output | Password tasks use `no_log`; values are never printed |

## Where the credentials end up

`/root/dev-db-credentials/tacoGathering_dev-<date>.env`, mode `0600`, owner `root`, kept
`dev_refresh_credentials_keep_days` (14) days. Contents:

```
DB_HOST=62.212.77.72
DB_PORT=3306
DB_NAME=tacoGathering_dev
DEV_PW_teste=<generated>
```

Read it with:

```
ssh -p 831 -i ~/.ssh/id_ed25519_myd2_ops root@62.212.77.72 \
  'sudo cat /root/dev-db-credentials/tacoGathering_dev-*.env | tail'
```

It holds **production data with dev credentials** — it is a handoff file, not a secret store.

## Run it

Dry run (safe; probes are read-only, nothing is written):

```
ANSIBLE_FORKS=1 ansible-playbook -i hosts playbooks/dev-db-refresh.yml --limit myvm1 --check --diff \
  -e ansible_ssh_private_key_file=~/.ssh/id_ed25519_myd2_ops \
  -e 'ansible_ssh_common_args="-o IdentitiesOnly=yes"'
```

Apply (owner only):

```
ANSIBLE_FORKS=1 ansible-playbook -i hosts playbooks/dev-db-refresh.yml --limit myvm1 \
  -e ansible_ssh_private_key_file=~/.ssh/id_ed25519_myd2_ops \
  -e 'ansible_ssh_common_args="-o IdentitiesOnly=yes"' \
  -e dev_refresh_apply=true -e dev_refresh_allow_same_device=true
```

## Known constraint on myvm1 (measured 2026-10-26)

myvm1 has **one** 59 GB disk (`/dev/vda1`, 34 GB free) and the MySQL datadir lives on it, so the
role's disk-safety assert fails by design there. Two options:

1. **Attach a second volume** and point `dev_refresh_dump_mount_point` at it — no overrides needed.
2. Accept the risk explicitly with `-e dev_refresh_allow_same_device=true`. Measured headroom: dump ≈ 150 MB (`tacoGathering`), free ≈ 34 GB — ~0.4 %.

## Nightly schedule

Not installed by this role. To arm it, add a cron entry in the `base` role (or a dedicated
role) that runs the apply command above; the credential file's timestamp is the success signal.

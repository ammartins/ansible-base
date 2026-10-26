# opensearch

Single-node OpenSearch 2.x from the official apt repository, bound to
loopback, security plugin on, no demo configuration. Play:
`playbooks/opensearch.yml` (group `[opensearch]` in `hosts`, currently myD2).

## Variables (see `defaults/main.yml`)

| Variable | Default | Notes |
|---|---|---|
| `opensearch_version` | `2.19.7` | exact apt version (`opensearch=<v>`); bump to upgrade; the deb is ~1 GB |
| `opensearch_cluster_name` | `<inventory_hostname>-opensearch` | |
| `opensearch_node_name` | `inventory_hostname` | |
| `opensearch_network_host` | `127.0.0.1` | role refuses non-loopback unless `opensearch_allow_nonloopback: true` |
| `opensearch_http_port` / `opensearch_transport_port` | `9200` / `9300` | |
| `opensearch_data_dir` / `opensearch_log_dir` | `/var/lib/opensearch` / `/var/log/opensearch` | |
| `opensearch_conf_dir` | `/etc/opensearch` | owned `opensearch:opensearch`, 0750 |
| `opensearch_heap_size` | `1g` | Xms=Xmx, `jvm.options.d/10-heap.options`; max half the RAM, < ~31g |
| `opensearch_jvm_extra_options` | `[]` | extra lines for the same drop-in |
| `opensearch_vm_max_map_count` | `262144` | `/etc/sysctl.d/60-opensearch.conf` |
| `opensearch_vm_swappiness` | `null` (unmanaged) | set e.g. `1`; host also runs k8s, so not forced |
| `opensearch_bootstrap_memory_lock` | `false` | needs `LimitMEMLOCK=infinity` systemd override if enabled |
| `opensearch_admin_user` | `admin` | |
| `opensearch_admin_password_hash` | `""` (**required**, vault) | bcrypt hash, not the password |
| `opensearch_tls_mode` | `selfsigned` | or `provided` |
| `opensearch_tls_days` | `825` | self-signed validity |
| `opensearch_tls_extra_sans` | `[]` | e.g. `["DNS:opensearch.example.org"]` |
| `opensearch_tls_*_src` | `""` | `provided` mode: controller paths of CA/node/admin PEMs |
| `opensearch_verify` | `true` | post-converge GET on the HTTP port, accepts 200/401 (skipped in `--check`) |

## Why apt (install method)

The fleet manages system services with `apt` + `service` (security-ssh/fail2ban,
base packages); docker is not used for system services. OpenSearch publishes
an official signed apt repo with a systemd unit and a bundled JDK, so apt
gives package ownership, a unit, and a pinnable version without adding a
container runtime. Trade-off: a ~1 GB package and an upstream-controlled repo
(the repo signing subkey expires 2027-03-06; the key URL is a variable).

## Security posture

* **Loopback only.** `network.host: 127.0.0.1`; there is no host firewall on
  myD2, so the assert in `tasks/main.yml` blocks any other bind unless you opt
  in explicitly.
* **No demo config.** The package is installed with
  `DISABLE_INSTALL_DEMO_CONFIG=true` (no demo certs, no `admin:admin`).
  `plugins.security.allow_unsafe_democertificates: false`.
* **Auth.** `internal_users.yml` is replaced with a single admin whose bcrypt
  hash comes from vault (`opensearch_admin_password_hash`); empty => the role
  asserts and stops. Generate the hash on a host that has the package:
  `OPENSEARCH_JAVA_HOME=/usr/share/opensearch/jdk /usr/share/opensearch/plugins/opensearch-security/tools/hash.sh -p '<password>'`
  (or any bcrypt tool, `$2y$12$...`). Store it with `ansible-vault encrypt_string`.
* **TLS** on HTTP and transport, with transport hostname verification and
  `nodes_dn`/`admin_dn` pinned. `selfsigned`: CA, node and admin certs are
  created with openssl in `/etc/opensearch/tls` only when missing (PKCS#8 keys,
  0600). `provided`: PEMs are copied from the controller (vault the keys).
* `allow_default_init_securityindex: true`: the security index is built from
  `/etc/opensearch/opensearch-security/*.yml` on **first start**. Later edits
  to those files (e.g. a new password hash) are not picked up automatically:
  run `securityadmin.sh` with the admin cert from `/etc/opensearch/tls`
  (`-cd /etc/opensearch/opensearch-security -icl -nhnv -cacert ... -cert admin.pem -key admin-key.pem`).

## Swapping / kernel

`vm.max_map_count=262144` is mandatory. Swap hurts OpenSearch; either set
`opensearch_vm_swappiness: 1`, or use memory lock (`opensearch_bootstrap_memory_lock: true`
plus a systemd override `LimitMEMLOCK=infinity`). Both are off by default so
the role does not change global memory policy on a shared host.

## Certificates: install / renew

* Install: automatic on first converge (`selfsigned`), or `provided`.
* Renew self-signed: on the host remove `node.pem` and/or `admin.pem` (leaf only)
  or all of `root-ca.pem root-ca-key.pem node*.pem admin*.pem` (new CA), re-run
  the play (`--tags opensearch`); the role recreates them and restarts the service.
* Renew `provided`: replace the controller files, re-run the play.

## Exposing through haproxy (later, out of scope here)

Keep OpenSearch on loopback and terminate public TLS in haproxy with the LE
cert, `server os 127.0.0.1:9200 ssl verify required ca-file /etc/opensearch/tls/root-ca.pem`,
plus an ACL/source allowlist. Do not widen `network.host`.

## Check-then-apply runbook

```
# 1. syntax + lint (local)
ansible-playbook -i hosts playbooks/opensearch.yml --syntax-check -e @vault.yml
# 2. dry run, one host, review the diff
ansible-playbook -i hosts playbooks/opensearch.yml --check --diff --limit myD2 \
  --tags opensearch -e @vault.yml --ask-vault-pass
# 3. only after review, apply (same line without --check), then repeat step 2:
#    it must report changed=0
```

On a host where OpenSearch is not installed, `--check` can only evaluate the
prerequisites/repository/package steps; the sysctl, TLS, configuration and
service tasks are skipped (a debug message says so) and are verified only
after the first apply. Re-run `--check --diff` afterwards for the full diff.

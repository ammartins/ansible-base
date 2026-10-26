#!/usr/bin/env bash
# Installed by ansible-base roles/opensearch. Pattern-wide log retention + capacity
# guard for the joaquim OpenSearch pilot.
#
# Why a script and not only ILM: OpenSearch ILM can delete an index once it is older
# than N days and can roll over on PER-INDEX conditions. It has no action meaning
# "delete once the whole pattern exceeds X". Without a real sweep, a size cap is a
# wish and one verbose day quietly eats the volume.
#
# Rules, oldest first:
#   1) age:  delete indices created more than RETENTION_DAYS ago
#   2) size: while the pattern total exceeds MAX_TOTAL_GB, delete the single oldest,
#            re-measure, repeat — bounded by MAX_DELETIONS per run
#
# Refusals: never touches the write index, anything outside PATTERN, anything already
# gone, or anything at all while the cluster is red (red is investigated, not pruned).
# Stops on the first delete error instead of walking the list blind.
#
# Disk note: if the flood-stage watermark is crossed, indices become read-only and
# the block does NOT clear itself when space is freed. Unblock by hand with:
#   curl -XPUT "127.0.0.1:9200/*/_settings" -H 'Content-Type: application/json' \
#        -d '{"index.blocks.read_only_allow_delete": null}'
set -euo pipefail

URL="http://127.0.0.1:9200"
PATTERN="${OS_PATTERN:-{{ opensearch_pattern }}}"
RETENTION_DAYS="${OS_RETENTION_DAYS:-{{ opensearch_retention_days }}}"
MAX_TOTAL_GB="${OS_MAX_TOTAL_GB:-{{ opensearch_max_total_gb }}}"
MAX_DELETIONS="${OS_MAX_DELETIONS:-10}"
DRY_RUN="${OS_DRY_RUN:-0}"
DATA_DIR="${OS_DATA_DIR:-{{ opensearch_data_dir }}}"

# Indices deleted (or pretend-deleted in a dry run) are excluded from every later
# measurement; without this the size loop re-measures the same total and spins.
declare -A GONE=()
kept() { [ -z "${GONE[$1]+x}" ]; }

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
say() { echo "[$(ts)] $*"; }
human() { numfmt --to=iec "$1" 2>/dev/null || echo "$1 B"; }

delete_one() {
  local idx="$1"
  if [ "$DRY_RUN" = "1" ]; then say "DRY-RUN would DELETE $idx"; GONE["$idx"]=1; return 0; fi
  if curl -sf -m 30 -XDELETE "$URL/$idx" >/dev/null; then
    say "DELETED $idx"; GONE["$idx"]=1
  else
    say "ERROR: delete failed for $idx"; return 1
  fi
}

list_indices() {
  # pri.store.size is emitted in bytes (the human-readable column is 'p'), so totals
  # are summed as integers with no unit parsing.
  curl -sf -m 20 "$URL/_cat/indices/$PATTERN?h=index,pri.store.size,creation.date.string&s=creation.date" || true
}

status=$(curl -sf -m 10 "$URL/_cluster/health?filter_path=status" | cut -d'"' -f4 || true)
if [ -z "$status" ]; then say "ERROR: no answer from $URL — leaving indices alone"; exit 1; fi
if [ "$status" = "red" ]; then say "ERROR: cluster is RED — refusing to delete anything"; exit 1; fi
say "cluster status: $status"

indices=$(list_indices)
if [ -z "$indices" ]; then say "no indices match $PATTERN — nothing to do"; exit 0; fi

cutoff=$(date -u -d "-${RETENTION_DAYS} days" +%Y-%m-%dT00:00:00)
total_bytes=0
declare -a aged=()
while read -r idx bytes created; do
  [ -z "${idx:-}" ] && continue
  case "$idx" in *-write) continue ;; esac
  kept "$idx" || continue
  total_bytes=$(( total_bytes + ${bytes:-0} ))
  # ISO-8601 timestamps compare correctly as strings.
  if [[ "${created:0:19}" < "${cutoff}" ]]; then aged+=("$idx"); fi
done <<< "$indices"

say "age cutoff: $cutoff | age-expired: ${#aged[@]} | pattern total: $(human "$total_bytes")"

deleted=0
for idx in "${aged[@]}"; do
  if [ "$deleted" -ge "$MAX_DELETIONS" ]; then say "reached MAX_DELETIONS=$MAX_DELETIONS — stopping"; break; fi
  if ! delete_one "$idx"; then say "ERROR: aborting sweep after failed delete"; exit 1; fi
  deleted=$((deleted + 1))
done

# Size cap: re-measure after the age pass, then trim oldest-first until under cap.
limit_bytes=$(( MAX_TOTAL_GB * 1024 * 1024 * 1024 ))
for _ in $(seq 1 "$MAX_DELETIONS"); do
  total_bytes=0
  oldest=""
  while read -r idx bytes created; do
    [ -z "${idx:-}" ] && continue
    case "$idx" in *-write) continue ;; esac
    kept "$idx" || continue
    total_bytes=$(( total_bytes + ${bytes:-0} ))
    [ -z "$oldest" ] && oldest="$idx"
  done <<< "$(list_indices)"
  if [ "$total_bytes" -le "$limit_bytes" ]; then
    say "under cap: $(human "$total_bytes") <= ${MAX_TOTAL_GB}GB"; break
  fi
  if [ -z "$oldest" ]; then say "nothing left to trim"; break; fi
  say "over cap ($(human "$total_bytes")); trimming oldest: $oldest"
  if ! delete_one "$oldest"; then say "ERROR: aborting sweep after failed delete"; exit 1; fi
  deleted=$((deleted + 1))
done

avail=$(df -P "$(dirname "$DATA_DIR")" | awk 'NR==2 {print $4}')
say "volume free: $(human $((avail * 1024)))"
say "done (deletions: $deleted)"

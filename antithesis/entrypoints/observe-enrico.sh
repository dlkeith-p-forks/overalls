#!/usr/bin/env bash
set -euo pipefail
umask 077

# Passive, bounded observation of this container's eight native Git admission
# inode paths and /proc fd holders. The output grants no process-control API.
state=/var/lib/enrico
output=/run/overalls-enrico-observer
[[ -s "$state/launch-generation" ]] || exit 1
generation=$(<"$state/launch-generation")
[[ "$generation" =~ ^[1-9][0-9]*$ ]] || exit 1
mkdir -p "$output"
chmod 0700 "$output"
temporary=$(mktemp "$output/.snapshot.XXXXXXXX")
records=$(mktemp "$output/.records.XXXXXXXX")
repositories=$(mktemp "$output/.repositories.XXXXXXXX")
trap 'rm -f "$temporary" "$records" "$repositories"' EXIT
complete=true

for slot in {0..7}; do
  lock="$state/.enrico-git-slot-$slot.lock"
  if [[ ! -f "$lock" || -L "$lock" ]] ||
     [[ "$(stat -c '%a:%u:%h' "$lock" 2>/dev/null)" != '600:0:1' ]]; then
    complete=false
    continue
  fi
  identity=$(stat -c '%d:%i' "$lock") || { complete=false; continue; }
  [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || { complete=false; continue; }
  device=${identity%:*}
  inode=${identity#*:}
  jq -n --argjson slot "$slot" --argjson device "$device" --argjson inode "$inode" \
    '{slot:$slot,device:$device,inode:$inode,pid:null}' >> "$records"
  for descriptor in /proc/[0-9]*/fd/*; do
    [[ -e "$descriptor" || -L "$descriptor" ]] || continue
    process=${descriptor#/proc/}
    process=${process%%/*}
    [[ "$process" =~ ^[1-9][0-9]*$ ]] || { complete=false; continue; }
    observed=$(stat -Lc '%d:%i' "$descriptor" 2>/dev/null) || { complete=false; continue; }
    if [[ "$observed" == "$identity" ]]; then
      jq -n --argjson slot "$slot" --argjson device "$device" \
        --argjson inode "$inode" --argjson pid "$process" \
        '{slot:$slot,device:$device,inode:$inode,pid:$pid}' >> "$records"
    fi
  done
done

repository_count=0
for lock in "$state"/.enrico-*.git.lock; do
  [[ -e "$lock" || -L "$lock" ]] || continue
  repository_count=$((repository_count + 1))
  if ((repository_count > 128)); then complete=false; break; fi
  if [[ ! -f "$lock" || -L "$lock" ]] ||
     [[ "$(stat -c '%a:%u:%h' "$lock" 2>/dev/null)" != '600:0:1' ]]; then
    complete=false
    continue
  fi
  name=${lock##*/}
  [[ "$name" =~ ^\.enrico-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.git\.lock$ ]] || { complete=false; continue; }
  repository_id=${BASH_REMATCH[1]}
  identity=$(stat -c '%d:%i' "$lock") || { complete=false; continue; }
  [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || { complete=false; continue; }
  device=${identity%:*}
  inode=${identity#*:}
  jq -n --arg id "$repository_id" --argjson device "$device" --argjson inode "$inode" \
    '{repository_id:$id,device:$device,inode:$inode,pid:null}' >> "$repositories"
  for descriptor in /proc/[0-9]*/fd/*; do
    [[ -e "$descriptor" || -L "$descriptor" ]] || continue
    process=${descriptor#/proc/}
    process=${process%%/*}
    [[ "$process" =~ ^[1-9][0-9]*$ ]] || { complete=false; continue; }
    observed=$(stat -Lc '%d:%i' "$descriptor" 2>/dev/null) || { complete=false; continue; }
    if [[ "$observed" == "$identity" ]]; then
      jq -n --arg id "$repository_id" --argjson device "$device" \
        --argjson inode "$inode" --argjson pid "$process" \
        '{repository_id:$id,device:$device,inode:$inode,pid:$pid}' >> "$repositories"
    fi
  done
done

observed_at=$(date +%s%3N)
[[ "$observed_at" =~ ^[1-9][0-9]*$ ]] || exit 1
jq -s --argjson generation "$generation" --argjson observed_at "$observed_at" \
  --argjson complete "$complete" --slurpfile repositories "$repositories" \
  '{version:1,generation:$generation,observed_at_unix_ms:$observed_at,complete:$complete,
    slots:(group_by(.slot) | map({slot:.[0].slot,device:.[0].device,inode:.[0].inode,
      holder_pids:([.[] | .pid | select(. != null)] | unique)})),
    repositories:($repositories | group_by(.repository_id) |
      map({repository_id:.[0].repository_id,device:.[0].device,inode:.[0].inode,
      holder_pids:([.[] | .pid | select(. != null)] | unique)}))}' \
  "$records" > "$temporary"
mv -T "$temporary" "$output/snapshot.json"

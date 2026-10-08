#!/usr/bin/env bash

set -euo pipefail

WORKTREE=${1:?usage: validate-assets.sh <worktree> <changed-paths-file>}
LIST=${2:?usage: validate-assets.sh <worktree> <changed-paths-file>}

REPORT=${REPORT:-}
BASE=${BASE:-}
MAX_ICNS_BYTES=$(( ${MAX_ICNS_MB:-5} * 1024 * 1024 ))
MAX_CAR_BYTES=$(( ${MAX_CAR_MB:-20} * 1024 * 1024 ))
MAX_DOMAINS=${MAX_DOMAINS:-10}

NL='
'
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

errors=()
warnings=()
added=()
updated=()
removed=()
domains=()

err()  { errors+=("$1"); }
warn() { warnings+=("$1"); }

has() {
  local needle=$1; shift
  local item
  for item in "$@"; do [ "$item" = "$needle" ] && return 0; done
  return 1
}

paths=()
if [ -s "$LIST" ]; then
  while IFS= read -r -d '' item || [ -n "$item" ]; do
    case $item in
      *"$NL"*)
        while IFS= read -r line; do
          [ -n "$line" ] && paths[${#paths[@]}]=$line
        done <<< "$item"
        ;;
      "") ;;
      *) paths[${#paths[@]}]=$item ;;
    esac
  done < "$LIST"
fi

if [ ${#paths[@]} -eq 0 ]; then
  err "This pull request does not change any files."
fi

domain_re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
name_re='^[a-z0-9][a-z0-9._-]*$'

check_domain() {
  local domain=$1 path=$2

  if [ "$domain" != "$(lower "$domain")" ]; then
    err "\`$path\` - domain directories must be lowercase (use \`$(lower "$domain")\`)."
    return 1
  fi
  if ! [[ $domain =~ $domain_re ]]; then
    err "\`$path\` - \`$domain\` is not a valid domain name."
    return 1
  fi
  if [ ${#domain} -gt 253 ]; then
    err "\`$path\` - \`$domain\` is longer than 253 characters."
    return 1
  fi
  if [[ $domain == www.* ]]; then
    err "\`$path\` - drop the \`www.\` prefix and use \`${domain#www.}\`."
    return 1
  fi
  if [[ ! $domain =~ \.[a-z][a-z0-9-]*$ ]]; then
    err "\`$path\` - \`$domain\` must end in an alphabetic top-level domain."
    return 1
  fi
  return 0
}

for path in "${paths[@]}"; do
  if [[ $path != icons/* ]]; then
    err "\`$path\` - only files under \`icons/\` may be changed by a pull request."
    continue
  fi

  rest=${path#icons/}
  domain=${rest%%/*}
  name=${rest#*/}

  if [ "$domain" = "$rest" ] || [ -z "$name" ]; then
    err "\`$path\` - assets live in \`icons/<domain>/\`, not directly in \`icons/\`."
    continue
  fi
  if [[ $name == */* ]]; then
    err "\`$path\` - subdirectories are not allowed inside \`icons/$domain/\`."
    continue
  fi

  ext=$(lower "${name##*.}")
  if [ "$ext" != icns ] && [ "$ext" != car ]; then
    err "\`$path\` - only \`.icns\` and \`.car\` files are accepted."
    continue
  fi
  if [ "$name" != "$(lower "$name")" ] || ! [[ $name =~ $name_re ]]; then
    err "\`$path\` - file names must be lowercase and limited to \`a-z0-9._-\`."
    continue
  fi

  check_domain "$domain" "$path" || continue
  has "$domain" "${domains[@]+"${domains[@]}"}" || domains+=("$domain")

  file="$WORKTREE/$path"
  if [ ! -e "$file" ]; then
    removed+=("$path")
    continue
  fi
  if [ ! -f "$file" ]; then
    err "\`$path\` - not a regular file (symlinks and submodules are not accepted)."
    continue
  fi

  size=$(wc -c < "$file" | tr -d ' ')
  if [ "$size" -eq 0 ]; then
    err "\`$path\` - the file is empty."
    continue
  fi

  if [ "$ext" = icns ]; then
    if [ "$size" -gt "$MAX_ICNS_BYTES" ]; then
      err "\`$path\` - $((size / 1024)) KiB exceeds the $(( MAX_ICNS_BYTES / 1024 / 1024 )) MiB limit for \`.icns\`."
      continue
    fi
    if [ "$(head -c 4 -- "$file")" != "icns" ]; then
      err "\`$path\` - missing the \`icns\` magic header, this is not an ICNS file."
      continue
    fi
    # Bytes 4-7 are the big-endian length of the whole file.
    declared=$(od -An -tu1 -j4 -N4 -- "$file" | awk 'NF >= 4 {print $1*16777216 + $2*65536 + $3*256 + $4; exit}')
    if [ "$declared" != "$size" ]; then
      warn "\`$path\` - header declares $declared bytes but the file is $size bytes. It may be truncated."
    fi
  else
    if [ "$size" -gt "$MAX_CAR_BYTES" ]; then
      err "\`$path\` - $((size / 1024)) KiB exceeds the $(( MAX_CAR_BYTES / 1024 / 1024 )) MiB limit for \`.car\`."
      continue
    fi
    if [ "$(head -c 8 -- "$file")" != "BOMStore" ]; then
      warn "\`$path\` - missing the \`BOMStore\` magic header. A compiled asset catalog should start with it. Rebuild with \`actool\`."
    fi
  fi

  if [ -n "$BASE" ] && git -C "$WORKTREE" cat-file -e "$BASE:$path" 2>/dev/null; then
    updated+=("$path")
  else
    added+=("$path")
  fi
done

if [ ${#domains[@]} -gt "$MAX_DOMAINS" ]; then
  err "This pull request touches ${#domains[@]} domains. Please keep it to $MAX_DOMAINS or fewer (one site per pull request is ideal)."
fi

for domain in "${domains[@]+"${domains[@]}"}"; do
  dir="$WORKTREE/icons/$domain"
  [ -d "$dir" ] || continue

  stray=()
  icns_count=0
  while IFS= read -r entry; do
    base=${entry##*/}
    case $(lower "$base") in
      *.icns) icns_count=$((icns_count + 1)) ;;
      *.car) ;;
      *) stray+=("icons/$domain/$base") ;;
    esac
  done < <(find "$dir" -mindepth 1 -maxdepth 1 | sort)

  for entry in "${stray[@]+"${stray[@]}"}"; do
    err "\`$entry\` - \`icons/$domain/\` may only contain \`.icns\` and \`.car\` files."
  done
  if [ "$icns_count" -eq 0 ]; then
    err "\`icons/$domain/\` has no \`.icns\` file. Every domain needs one."
  fi
  if [ ! -f "$dir/icon.icns" ]; then
    err "\`icons/$domain/icon.icns\` is missing. The primary icon must use that exact name."
  fi
  if [ ! -f "$dir/icon.car" ]; then
    warn "\`icons/$domain/\` has no \`icon.car\`. A compiled asset catalog is recommended but optional."
  fi
done

{
  if [ ${#errors[@]} -eq 0 ]; then
    echo "### ✅ Asset check passed"
  else
    echo "### ❌ Asset check failed"
  fi
  echo

  if [ ${#errors[@]} -gt 0 ]; then
    echo "**Problems that must be fixed**"
    echo
    for item in "${errors[@]}"; do echo "- $item"; done
    echo
  fi

  if [ ${#warnings[@]} -gt 0 ]; then
    echo "**Warnings** (these do not block the pull request)"
    echo
    for item in "${warnings[@]}"; do echo "- $item"; done
    echo
  fi
} | if [ -n "$REPORT" ]; then tee -- "$REPORT"; else cat; fi

[ ${#errors[@]} -eq 0 ]

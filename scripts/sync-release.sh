#!/usr/bin/env bash

set -euo pipefail

domain=${1:?usage: sync-release.sh <domain>}
tag=$domain
dir="icons/$domain"
sha=${GITHUB_SHA:-$(git rev-parse HEAD)}
repo=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}

domain_re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
if ! [[ $domain =~ $domain_re ]] || [[ $domain == *.lock ]]; then
  echo "::error::Refusing to publish '$domain': not a usable domain name." >&2
  exit 1
fi

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | cut -d' ' -f1
  else
    shasum -a 256 -- "$1" | cut -d' ' -f1
  fi
}

human() {
  awk -v b="$1" 'BEGIN {
    if (b < 1024) printf "%d B", b
    else if (b < 1048576) printf "%.1f KiB", b / 1024
    else printf "%.2f MiB", b / 1048576
  }'
}

if [ ! -d "$dir" ]; then
  if gh release view "$tag" >/dev/null 2>&1; then
    gh release delete "$tag" --yes --cleanup-tag
    echo "Deleted release and tag '$tag'."
  else
    git push -q origin ":refs/tags/$tag" 2>/dev/null \
      && echo "Deleted orphaned tag '$tag'." \
      || echo "Nothing to delete for '$tag'."
  fi
  exit 0
fi

assets=()
while IFS= read -r file; do
  assets[${#assets[@]}]=$file
done < <(find "$dir" -maxdepth 1 -type f \( -name '*.icns' -o -name '*.car' \) | sort)

if [ ${#assets[@]} -eq 0 ]; then
  echo "::error::$dir holds no .icns or .car files." >&2
  exit 1
fi

notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
{
  echo "Dock icons for \`$domain\`."
  echo
  echo "| File | Size | SHA-256 |"
  echo "| --- | --: | --- |"
  for file in "${assets[@]}"; do
    printf '| `%s` | %s | `%s` |\n' \
      "${file##*/}" "$(human "$(wc -c < "$file" | tr -d ' ')")" "$(sha256 "$file")"
  done
  echo
  echo '```sh'
  echo "curl -fLO https://github.com/$repo/releases/download/$tag/icon.icns"
  echo '```'
  echo
  echo "Tag \`$tag\` is a rolling pointer to the latest commit that touched"
  echo "\`$dir\`, currently [\`${sha:0:7}\`](https://github.com/$repo/commit/$sha)."
} > "$notes"

git tag -f "$tag" "$sha" >/dev/null
git push -qf origin "refs/tags/$tag"

if gh release view "$tag" >/dev/null 2>&1; then
  gh release edit "$tag" --title "$domain" --notes-file "$notes"

  names=$(for file in "${assets[@]}"; do printf '%s\n' "${file##*/}"; done)
  while IFS= read -r existing; do
    [ -n "$existing" ] || continue
    if ! printf '%s\n' "$names" | grep -qxF -- "$existing"; then
      gh release delete-asset "$tag" "$existing" --yes
      echo "Removed stale asset '$existing' from '$tag'."
    fi
  done < <(gh release view "$tag" --json assets -q '.assets[].name')

  gh release upload "$tag" "${assets[@]}" --clobber
  echo "Updated release '$tag' with ${#assets[@]} asset(s)."
else
  gh release create "$tag" "${assets[@]}" --title "$domain" --notes-file "$notes"
  echo "Created release '$tag' with ${#assets[@]} asset(s)."
fi

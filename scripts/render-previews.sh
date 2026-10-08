#!/usr/bin/env bash

set -euo pipefail

WORKTREE=${1:?usage: render-previews.sh <worktree> <changed-paths-file> <out-dir>}
LIST=${2:?usage: render-previews.sh <worktree> <changed-paths-file> <out-dir>}
OUT=${3:?usage: render-previews.sh <worktree> <changed-paths-file> <out-dir>}

PREVIEW_PX=${PREVIEW_PX:-256}
REPORT=${REPORT:-}

NL='
'
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

mkdir -p "$OUT"

magick_cmd=""
if command -v magick >/dev/null 2>&1; then
  magick_cmd=magick
elif command -v convert >/dev/null 2>&1; then
  magick_cmd=convert
fi

human() {
  awk -v b="$1" 'BEGIN {
    if (b < 1024) printf "%d B", b
    else if (b < 1048576) printf "%.1f KiB", b / 1024
    else printf "%.2f MiB", b / 1048576
  }'
}

png_width() {
  od -An -tu1 -j16 -N4 -- "$1" \
    | awk 'NF >= 4 {print $1*16777216 + $2*65536 + $3*256 + $4; exit}'
}

extract_icns() {
  local src=$1 dir=$2
  if command -v icns2png >/dev/null 2>&1; then
    icns2png -x -o "$dir" -- "$src" >/dev/null 2>&1 || true
  elif command -v iconutil >/dev/null 2>&1; then
    mkdir -p "$dir"
    if iconutil --convert iconset --output "$dir/x.iconset" "$src" >/dev/null 2>&1; then
      mv "$dir"/x.iconset/*.png "$dir"/ 2>/dev/null || true
    fi
  else
    return 1
  fi
  compgen -G "$dir/*.png" >/dev/null
}

render_icns() {
  local src=$1 dest=$2 tmp best best_px px variants=()
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  extract_icns "$src" "$tmp" || return 1

  best=""
  best_px=0
  for png in "$tmp"/*.png; do
    [ -e "$png" ] || continue
    px=$(png_width "$png")
    [ -n "$px" ] && [ "$px" -gt 0 ] || continue
    variants[${#variants[@]}]="${px}x${px}"
    if [ "$px" -gt "$best_px" ]; then
      best_px=$px
      best=$png
    fi
  done

  [ -n "$best" ] || return 1

  if [ -n "$magick_cmd" ]; then
    "$magick_cmd" "$best" -resize "${PREVIEW_PX}x${PREVIEW_PX}>" -strip "$dest" 2>/dev/null \
      || cp -- "$best" "$dest"
  elif command -v sips >/dev/null 2>&1 && [ "$best_px" -gt "$PREVIEW_PX" ]; then
    cp -- "$best" "$dest"
    sips --resampleHeightWidthMax "$PREVIEW_PX" "$dest" >/dev/null 2>&1 || true
  else
    cp -- "$best" "$dest"
  fi

  printf '%s\n' "${variants[@]}" | sort -u -n -t x -k1,1 | paste -sd ' ' -
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

rows=()
rendered=0

for path in "${paths[@]+"${paths[@]}"}"; do
  [[ $path == icons/*/* ]] || continue
  file="$WORKTREE/$path"
  [ -f "$file" ] || continue

  rest=${path#icons/}
  domain=${rest%%/*}
  name=${rest#*/}
  ext=$(lower "${name##*.}")
  [ "$ext" = icns ] || [ "$ext" = car ] || continue

  bytes=$(wc -c < "$file" | tr -d ' ')
  variants="-"

  if [ "$ext" = icns ]; then
    dest="$OUT/${domain}__${name%.*}.png"
    if variants=$(render_icns "$file" "$dest"); then
      rendered=$((rendered + 1))
      [ -n "$variants" ] || variants="-"
    else
      variants="-"
      rm -f -- "$dest"
      echo "warning: could not render a preview for $path" >&2
    fi
  fi

  rows[${#rows[@]}]="$domain|${name}|${ext}|$(human "$bytes")|${variants}"
done

if [ ${#rows[@]} -eq 0 ]; then
  echo "No icon assets to preview."
  exit 0
fi

details() {
  echo "### Assets"
  echo
  echo "| Domain | File | Type | Size | Variants |"
  echo "| --- | --- | --- | --: | --- |"
  printf '%s\n' "${rows[@]}" | sort | while IFS='|' read -r domain name ext size variants; do
    printf '| `%s` | `%s` | %s | %s | %s |\n' "$domain" "$name" "$ext" "$size" "$variants"
  done
}

details
echo "Rendered $rendered preview(s) into $OUT."

if [ -n "$REPORT" ]; then
  {
    echo
    details
  } >> "$REPORT"
fi

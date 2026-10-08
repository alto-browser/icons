#!/usr/bin/env bash
#
# Turn the artifact produced by the "PR check" workflow into the body of the
# pull request comment.
#
# Usage: build-preview-comment.sh <artifact-dir> [raw-url-base]
#
# The artifact holds the validation report plus one "<domain>__<name>.png" per
# rendered icon. <raw-url-base> is where those PNGs were published. Without it
# the images are left out and only the report is rendered.

set -euo pipefail

DIR=${1:?usage: build-preview-comment.sh <artifact-dir> [raw-url-base]}
RAW=${2:-}

MARKER='<!-- dock-icons-preview -->'
PER_ROW=${PER_ROW:-4}

echo "$MARKER"
echo "## Dock icon preview"
echo

previews=()
while IFS= read -r png; do
  previews[${#previews[@]}]=${png##*/}
done < <(find "$DIR" -maxdepth 1 -name '*.png' | sort)

if [ ${#previews[@]} -eq 0 ]; then
  echo "No \`.icns\` preview could be rendered. Check that the file is a valid ICNS."
  echo
elif [ -z "$RAW" ]; then
  echo "Previews were rendered but could not be published. See the run artifacts."
  echo
else
  echo "<table>"
  column=0
  for png in "${previews[@]}"; do
    domain=${png%%__*}
    name=${png#*__}
    name=${name%.png}

    [ "$column" -eq 0 ] && echo "<tr>"
    printf '<td align="center" width="150">'
    printf '<img src="%s/%s" width="128" alt="%s"><br>' "${RAW%/}" "$png" "$domain"
    printf '<sub><b>%s</b><br>%s.icns</sub>' "$domain" "$name"
    printf '</td>\n'

    column=$((column + 1))
    if [ "$column" -ge "$PER_ROW" ]; then
      echo "</tr>"
      column=0
    fi
  done
  [ "$column" -ne 0 ] && echo "</tr>"
  echo "</table>"
  echo
  echo "<sub>Previews show the largest variant in each \`.icns\`, scaled to 128px. \`.car\` archives cannot be rendered here.</sub>"
  echo
fi

if [ -f "$DIR/report.md" ]; then
  cat "$DIR/report.md"
fi

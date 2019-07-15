#!/usr/bin/env bash

if [ ! -f "params" ]; then
  echo "The \"params\" file doest't exists, not running anything."
  exit 1
fi
# shellcheck disable=SC1091
source params

if [ -n "${TARGET_COMMIT}" ]; then
  # Create updater file from template with the current commit
  sed 's/%%TARGET_COMMIT%%/'"$TARGET_COMMIT"'/' preupdater_template.sh > preupdater.sh || (echo "preupdater templating failed" ; exit 1)
  # shellcheck disable=SC2002
  cat batch | stdbuf -oL xargs -I{} -P 15 /bin/sh -c "grep -a -q '{} : DONE' preupdater.log || (cat preupdater.sh | balena ssh {} | sed 's/^/{} : /' | tee -a preupdater.log)"
else
  echo "TARGET_COMMIT is not set."
  exit 2
fi

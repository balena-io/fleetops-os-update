#!/usr/bin/env bash

if [ ! -f "params" ]; then
  echo "The \"params\" file doest't exists, not running anything."
  exit 1
fi
# shellcheck disable=SC1091
source params

if [ -n "${TARGET_COMMIT}" ]; then
  # shellcheck disable=SC2002
  cat batch | stdbuf -oL xargs -I{} -P 15 /bin/sh -c "balena device {} | grep -q 'COMMIT:.*${TARGET_COMMIT}' && (cat updater.sh | balena ssh {} -s --noninteractive | sed 's/^/{} : /' | tee -a updater.log)"
else
  echo "TARGET_COMMIT is not set."
  exit 2
fi

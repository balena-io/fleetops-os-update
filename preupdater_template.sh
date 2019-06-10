#!/bin/bash

set -o errexit -o pipefail

# Don't run anything before this source as it sets PATH here
# shellcheck disable=SC1091
source /etc/profile
# Load
# shellcheck disable=SC1091
source /usr/sbin/resin-vars

setup_logfile() {
    local workdir=$1
    LOGFILE="${workdir}/preupdate.$(date +"%Y%m%d_%H%M%S").log"
    touch "$LOGFILE"
    tail -f "$LOGFILE" &
    # this is global
    tail_pid=$!
    # redirect all logs to the logfile
    exec 1>> "$LOGFILE" 2>&1
}

finish_up() {
    local failure=$1
    local exit_code=0
    if [ -n "${failure}" ]; then
        echo "Fail: ${failure}"
        exit_code=1
    else
        echo "DONE"
    fi
    sleep 2
    kill $tail_pid || true
    exit ${exit_code}
}


device_repin() {
    COMMIT_HASH=$1
    if [ -z "${COMMIT_HASH}" ]; then
        finish_up "No commit hash provided!"
    fi
    BUILD_ID=$(curl --fail --retry 10 -s "${API_ENDPOINT}/v2/build?\$select=id,commit_hash&\$filter=application%20eq%20${APPLICATION_ID}%20and%20commit_hash%20eq%20'$COMMIT_HASH'" -H "Authorization: Bearer ${DEVICE_API_KEY}" | jq '.d[0].id')  || finish_up "Couldn't get build ID."
    echo "setting device ${DEVICE_ID} to commit ${COMMIT_HASH} with buildID = ${BUILD_ID}"
    curl --fail --retry 10 -s -X PATCH "${API_ENDPOINT}/v2/device(${DEVICE_ID})" -H "Authorization: Bearer ${DEVICE_API_KEY}" -H "Content-Type: application/json" --data-binary '{"build":'"${BUILD_ID}"'}' || finish_up "Couldn't set new commit hash."
}


main() {
    workdir="/mnt/data/ops2"
    mkdir -p "${workdir}" && cd "${workdir}"

    # also sets tail_pid
    setup_logfile "${workdir}"

    local superstartscript="/usr/bin/start-resin-supervisor"
    # shellcheck disable=SC2016
    if grep -q '^(\[ "$SUPERVISOR_IMAGE_ID".*' "${superstartscript}"; then
        # Modify the supervisor start script so it doesn't recreate the supervisor container on restart
        tempfile=$(mktemp -u /tmp/tmp.supervisor.XXXXXXXXX)
        cp "${superstartscript}" "${tempfile}"

        # shellcheck disable=SC2016
        sed -i 's/^(\[ "$SUPERVISOR_IMAGE_ID".*//' "${tempfile}"
        cat << EOF >> "${tempfile}"
if [ "\$SUPERVISOR_IMAGE_ID" = "\$SUPERVISOR_CONTAINER_IMAGE_ID" ]; then
    docker start --attach resin_supervisor
else
    runSupervisor
fi
EOF
        mount --bind "${tempfile}" "${superstartscript}"
        echo "Supervisor start script was modified."
    else
        echo "Supervisor script is already modified."
    fi

    echo "Restarting supervisor to make sure changes to the start script are picked up"
    systemctl restart resin-supervisor || finish_up "Supervisor restart didn't work."
    i=0
    while [ -z "$(docker ps | grep resin_supervisor)" ] && [ $i -lt 60 ]; do
      sleep 1
      i=$[$i+1]
    done
    if [ -z "$(docker ps | grep resin_supervisor)" ]; then
      finish_up "Supervisor container didn't come up before timeout"
    fi


    echo "Modifying supervisor container"
    docker exec resin_supervisor sed -i 's/waitAsync()\.timeout(5e3)/waitAsync()\.timeout(5e5)/' /usr/src/app/dist/app.js || finish_up "Supervisor container hotfix didn't work."
    echo "Restarting supervisor container"
    systemctl restart resin-supervisor || finish_up "Supervisor restart didn't work."

    device_repin "%%TARGET_COMMIT%%"

    echo "Finished"

    finish_up
}

(
  # Check if already running and bail if yes
  flock -n 99 || (echo "Already running script..."; exit 1)
  main
) 99>/tmp/updater.lock
# Proper exit, required due to the locking subshell
exit $?

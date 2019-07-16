#!/bin/bash

set -o errexit -o pipefail

# Don't run anything before this source as it sets PATH here
# shellcheck disable=SC1091
source /etc/profile
# load supervisor version: SUPERVISOR_TAG, SUPERVISOR_IMAGE variables
# shellcheck disable=SC1091
source /etc/resin-supervisor/supervisor.conf
# Load
# shellcheck disable=SC1091
source /usr/sbin/resin-vars

URLBASE="https://misc1.dev.balena.io/~imrehg/fleetops-od-os"
TARGET_OS_VERSION="2.32.0+rev1"
TARGET_SUPERVISOR_REPO="balena/armv7hf-supervisor"
TARGET_SUPERVISOR_VERSION="v9.14.0"
TARGET_OS_VERSION_FILENAME=$(echo "balenaos${TARGET_OS_VERSION}-raspberrypi3.tar.xz" | tr + _)
DOWNLOADS=("xzdec.gz" "rdiff.xz" "hostosupdate.sh" "os/${TARGET_OS_VERSION_FILENAME}" "checksums.txt")

setup_logfile() {
    local workdir=$1
    LOGFILE="${workdir}/osupdate.$(date +"%Y%m%d_%H%M%S").log"
    touch "$LOGFILE"
    tail -f "$LOGFILE" &
    # this is global
    tail_pid=$!
    # redirect all logs to the logfile
    exec 1>> "$LOGFILE" 2>&1
}

stop_supervisor() {
    systemctl stop resin-supervisor || true
    docker rm -f resin_supervisor || true
    systemctl stop update-resin-supervisor.timer || true
}

retry_download() {
    local url=$1
    local curl_retval
    local http_status
    echo "Downloading: ${url}"
    http_status=$(curl -C- --retry 20 --fail -w "%{http_code}" -O "${url}") || curl_retval=$?
    if [ -n "${curl_retval}" ] && [ "${curl_retval}" -ne 22 ]; then
        finish_up "Curl failure while downloading."
    fi
    if [ -n "${http_status}" ]; then
        # Check if download is successful
        if [ "${http_status}" -ne 200 ]; then
            while [ "${http_status}" -ne 416 ]; do
                # If not finished downlaoding, keep trying
                curl_retval=
                sleep 5;
                echo "Retrying download"
                http_status=$(curl -C- --retry 20 --fail -w "%{http_code}" -O "$url" ) || curl_retval=$?
                if [ -n "${curl_retval}" ] && [ "${curl_retval}" -ne 22 ]; then
                    finish_up "Curl failure while downloading."
                fi
                if [ "${http_status}" -eq 404 ]; then
                    finish_up "Required file not found on server."
                fi
            done
        fi
        echo "Download finished."
    else
        finish_up "Curl download without final status."
    fi
}

update_supervisor() {
    echo "Updating the supervisor"

    sed -e "s|SUPERVISOR_TAG=.*|SUPERVISOR_TAG=${TARGET_SUPERVISOR_VERSION}|" /etc/resin-supervisor/supervisor.conf > /tmp/update-supervisor.conf
    sed -i -e "s|SUPERVISOR_TAG=.*|SUPERVISOR_TAG=${TARGET_SUPERVISOR_VERSION}|" /etc/resin-supervisor/supervisor.conf

    sed -e "s|SUPERVISOR_IMAGE=.*|SUPERVISOR_IMAGE=${TARGET_SUPERVISOR_REPO}|" /etc/resin-supervisor/supervisor.conf > /tmp/update-supervisor.conf
    sed -i -e "s|SUPERVISOR_IMAGE=.*|SUPERVISOR_IMAGE=${TARGET_SUPERVISOR_REPO}|" /etc/resin-supervisor/supervisor.conf

    update_supervisor_in_api
    # Do not restart the supervisor
}

update_supervisor_in_api() {
    CONFIGJSON="${CONFIG_PATH}"
    TAG="${TARGET_SUPERVISOR_VERSION}"
    APIKEY="$(jq -r '.apiKey // .deviceApiKey' "${CONFIGJSON}")"
    DEVICEID="$(jq -r '.deviceId' "${CONFIGJSON}")"
    API_ENDPOINT="$(jq -r '.apiEndpoint' "${CONFIGJSON}")"
    SLUG="$(jq -r '.deviceType' "${CONFIGJSON}")"
    while ! SUPERVISOR_ID=$(curl -s "${API_ENDPOINT}/v4/supervisor_release?\$select=id,image_name&\$filter=((device_type%20eq%20'$SLUG')%20and%20(supervisor_version%20eq%20'$TAG'))&apikey=${APIKEY}" | jq -e -r '.d[0].id'); do
        echo "Retrying..."
        sleep 5
    done
    echo "Extracted supervisor ID: $SUPERVISOR_ID; setting in the API"
    while ! curl -s "${API_ENDPOINT}/v2/device($DEVICEID)?apikey=$APIKEY" -X PATCH -H 'Content-Type: application/json;charset=UTF-8' --data-binary "{\"supervisor_release\": \"$SUPERVISOR_ID\"}" ; do
        echo "Retrying..."
        sleep 5
    done
}

finish_up() {
    local failure=$1
    local exit_code=0
    if [ -n "${failure}" ]; then
        echo "Fail: ${failure}"
        exit_code=1
    else
        echo "Success; rebooting"
        nohup bash -c "sleep 5 ; reboot " > /dev/null 2>&1 &
    fi
    sleep 2
    kill $tail_pid || true
    exit ${exit_code}
}

main() {
    if grep -q "${TARGET_OS_VERSION}" /etc/os-release ; then
       echo "OS update already done, nothing else to do."
       finish_up
    fi

    workdir="/mnt/data/ops2"
    mkdir -p "${workdir}" && cd "${workdir}"

    # also sets tail_pid
    setup_logfile "${workdir}"

    delta_name="${SUPERVISOR_TAG}-${TARGET_SUPERVISOR_VERSION}.delta"
    delta_url="${URLBASE}/deltas/${delta_name}.xz"
    echo "Delta URL: ${delta_url}"

    # shellcheck disable=SC1083
    if [ "$(curl -s --head -w %{http_code} "${delta_url}" -o /dev/null)" = "200" ]; then
        echo "Delta found!"
        DOWNLOADS+=("deltas/${delta_name}.xz")
    else
        finish_up "Delta NOT found, bailing!"
    fi

    for item in "${DOWNLOADS[@]}" ; do
        retry_download "${URLBASE}/${item}"
    done

    # Prepare executables
    gunzip -f xzdec.gz && chmod +x xzdec
    ./xzdec rdiff.xz > rdiff && chmod +x rdiff
    chmod +x hostosupdate.sh

    # Extract delta
    ./xzdec "${delta_name}.xz" > "${delta_name}"

    current_supervisor="${SUPERVISOR_IMAGE}:${SUPERVISOR_TAG}"
    output_file="${SUPERVISOR_TAG}"

    echo "Docker save of original supervisor started"
    docker save "${current_supervisor}" > "${output_file}" || finish_up "Docker save error"

    # Work in a subdirectory
    rm -rf workdir || true
    mkdir workdir
    cd workdir
    tar -xf "../${output_file}"
    # shellcheck disable=SC2038
    calculated_sha=$(find . -type f -name layer.tar | xargs sha256sum | sort | grep -v 5f70 | awk '{print $2}'|xargs cat | sha256sum | awk '{ print $1}')
    shipped_sha=$(grep "${SUPERVISOR_TAG}$" ../checksums.txt | awk '{ print $1}')
    if [ "$shipped_sha" != "$calculated_sha" ]; then
        finish_up "Integrity check failure. Expected ${shipped_sha} : got ${calculated_sha}"
    else
        echo "Integrity check okay"
    fi
    # Create delta base
    # shellcheck disable=SC2038
    find . -type f -name layer.tar | xargs sha256sum | sort | grep -v 5f70 | awk '{print $2}' | xargs cat > delta-base

    echo "Creating supervisor image from patch"
    ../rdiff patch delta-base "../${delta_name}" "../${TARGET_SUPERVISOR_VERSION}.tar"

    stop_supervisor

    echo "Docker load supervisor image"
    docker load -i "../${TARGET_SUPERVISOR_VERSION}.tar" || finish_up "Docker load error"

    cd "${workdir}"

    echo "Checking OS update image integrity"
    grep "${TARGET_OS_VERSION_FILENAME}" "checksums.txt" | sha256sum -c -- || finish_up "OS update image integrity check failed"
    echo "Extracing host OS update image"
    ./xzdec "${TARGET_OS_VERSION_FILENAME}" > hostos.tar
    echo "Loading host OS update image into docker"
    docker load -i hostos.tar

    echo "Running host OS update"
    ./hostosupdate.sh --hostos-version "${TARGET_OS_VERSION}" --no-reboot || finish_up "OS update failed"
    # Remove update image
    # shellcheck disable=SC2046
    docker rmi $(docker images | grep resin/resinos | awk '{ print $3}') || true

    echo "Update supervisor"
    update_supervisor

    echo "Cleaning up"
    rm -rf "${workdir}/workdir" || true
    find "${workdir}" -type f ! -name "*.log" -exec rm -rf {} \;

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

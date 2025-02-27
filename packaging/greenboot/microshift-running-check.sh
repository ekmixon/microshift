#!/bin/bash
set -e

SCRIPT_NAME=$(basename "$0")
SCRIPT_PID=$$
PODS_NS_LIST=(openshift-ovn-kubernetes openshift-service-ca openshift-ingress openshift-dns openshift-storage kube-system)
PODS_CT_LIST=(2                        1                    1                 2             2                 2)
RETRIEVE_PODS=false

# Source the MicroShift health check functions library
# shellcheck source=packaging/greenboot/functions.sh
source /usr/share/microshift/functions/greenboot.sh

# Set the term handler to convert exit code to 1
trap 'forced_termination' TERM SIGINT

# Set the exit handler to log the exit status
trap 'script_exit' EXIT

# Handler that will be called when the script is terminated by sending TERM or
# INT signals. To override default exit codes it forces returning 1 like the
# rest of the error conditions throughout the health check.
function forced_termination() {
    echo "Signal received, terminating."
    exit 1
}

# The script exit handler logging the FAILURE or FINISHED message depending
# on the exit status of the last command
#
# args: None
# return: None
function script_exit() {
    if [ "$?" -ne 0 ] ; then
        if ${RETRIEVE_PODS}; then
            log_failure_cmd "pod-list" "${OCGET_CMD} pods -A -o wide"
            log_failure_cmd "pod-events" "${OCGET_CMD} events -A"
        fi
        print_failure_logs
        echo "FAILURE"
    else
        echo "FINISHED"
    fi
}

# Run a command specified in the arguments, redirect its output to a temporary
# file and add this file to 'LOG_FAILURE_FILES' setting so that is it printed
# in the logs if the script exits with failure.
#
# All the command output including stdout and stderr is redirected to its log file.
#
# arg1: A name to be used when creating "/tmp/${name}.XXXXXXXXXX" temporary files
# arg2: A command to be run
# return: None
function log_failure_cmd() {
    local -r logName="$1"
    local -r logCmd="$2"
    local -r logFile=$(mktemp "/tmp/${logName}.XXXXXXXXXX")

    # Run the command ignoring errors and log its output
    (${logCmd}) &> "${logFile}" || true
    # Save the log file name in the list to be printed
    LOG_FAILURE_FILES+=("${logFile}")
}

# Check the microshift.service systemd unit activity, terminating the script
# with the SIGTERM signal if the unit reports a failed state
#
# args: None
# return: 0 if the systemd unit is active, or 1 otherwise
function microshift_service_active() {
    local -r is_failed=$(systemctl is-failed microshift.service)
    local -r is_active=$(systemctl is-active microshift.service)

    # Terminate the script in case of a failed service - nothing to wait for
    if [ "${is_failed}" = "failed" ] ; then
        echo "Error: The microshift.service systemd unit is failed. Terminating..."
        kill -TERM ${SCRIPT_PID}
    fi
    # Check the service activity
    [ "${is_active}" = "active" ] && return 0
    return 1
}

# Check if MicroShift API 'readyz' and 'livez' health endpoints are OK
#
# args: None
# return: 0 if all API health endpoints are OK, or 1 otherwise
function microshift_health_endpoints_ok() {
    local -r check_rd=$(${OCGET_CMD} --raw='/readyz?verbose' | awk '$2 != "ok"')
    local -r check_lv=$(${OCGET_CMD} --raw='/livez?verbose'  | awk '$2 != "ok"')

    [ "${check_rd}" != "readyz check passed" ] && return 1
    [ "${check_lv}" != "livez check passed"  ] && return 1
    return 0
}

# Check if any MicroShift pods are in the 'Running' status
#
# args: None
# return: 0 if any pods are in the 'Running' status, or 1 otherwise
function any_pods_running() {
    local -r count=$(${OCGET_CMD} pods ${OCGET_OPT} -A 2>/dev/null | awk '$4~/Running/' | wc -l)

    [ "${count}" -gt 0 ] && return 0
    return 1
}

#
# Main
#

# Exit if the current user is not 'root'
if [ "$(id -u)" -ne 0 ] ; then
    echo "The '${SCRIPT_NAME}' script must be run with the 'root' user privileges"
    exit 1
fi

echo "STARTED"

# Print the boot variable status
print_boot_status

# Exit if the MicroShift service is not enabled
if [ "$(systemctl is-enabled microshift.service 2>/dev/null)" != "enabled" ] ; then
    echo "MicroShift service is not enabled. Exiting..."
    exit 0
fi

# Set the wait timeout for the current check based on the boot counter
WAIT_TIMEOUT_SECS=$(get_wait_timeout)

# Always log potential MicroShift upgrade errors on failure
LOG_FAILURE_FILES+=("/var/lib/microshift-backups/prerun_failed.log")

# Wait for MicroShift service to be active (failed status terminates the script)
echo "Waiting ${WAIT_TIMEOUT_SECS}s for MicroShift service to be active and not failed"
if ! wait_for "${WAIT_TIMEOUT_SECS}" microshift_service_active ; then
    echo "Error: Timed out waiting for MicroShift service to be active"
    exit 1
fi

# Wait for MicroShift API health endpoints to be OK
echo "Waiting ${WAIT_TIMEOUT_SECS}s for MicroShift API health endpoints to be OK"
if ! wait_for "${WAIT_TIMEOUT_SECS}" microshift_health_endpoints_ok ; then
    log_failure_cmd "health-readyz" "${OCGET_CMD} --raw=/readyz?verbose"
    log_failure_cmd "health-livez"  "${OCGET_CMD} --raw=/livez?verbose"

    echo "Error: Timed out waiting for MicroShift API health endpoints to be OK"
    exit 1
fi

# Starting pod-specific checks
# Log list of pods and their events on failure
RETRIEVE_PODS=true

# Wait for any pods to enter running state
echo "Waiting ${WAIT_TIMEOUT_SECS}s for any pods to be running"
if ! wait_for "${WAIT_TIMEOUT_SECS}" any_pods_running ; then
    echo "Error: Timed out waiting for any MicroShift pod to be running"
    exit 1
fi

# Wait for MicroShift core pod images to be downloaded
for i in "${!PODS_NS_LIST[@]}"; do
    CHECK_PODS_NS=${PODS_NS_LIST[${i}]}

    echo "Waiting ${WAIT_TIMEOUT_SECS}s for pod image(s) from the '${CHECK_PODS_NS}' namespace to be downloaded"
    if ! wait_for "${WAIT_TIMEOUT_SECS}" namespace_images_downloaded ; then
        echo "Error: Timed out waiting for pod image(s) from the '${CHECK_PODS_NS}' namespace to be downloaded"
        exit 1
    fi
done

# Wait for MicroShift core pods to enter ready state
for i in "${!PODS_NS_LIST[@]}"; do
    CHECK_PODS_NS=${PODS_NS_LIST[${i}]}
    CHECK_PODS_CT=${PODS_CT_LIST[${i}]}

    echo "Waiting ${WAIT_TIMEOUT_SECS}s for ${CHECK_PODS_CT} pod(s) from the '${CHECK_PODS_NS}' namespace to be in 'Ready' state"
    if ! wait_for "${WAIT_TIMEOUT_SECS}" namespace_pods_ready ; then
        echo "Error: Timed out waiting for ${CHECK_PODS_CT} pod(s) in the '${CHECK_PODS_NS}' namespace to be in 'Ready' state"
        exit 1
    fi
done

# Verify that MicroShift core pods are not restarting
declare -A pid2name
for i in "${!PODS_NS_LIST[@]}"; do
    CHECK_PODS_NS=${PODS_NS_LIST[${i}]}

    echo "Checking pod restart count in the '${CHECK_PODS_NS}' namespace"
    namespace_pods_not_restarting "${CHECK_PODS_NS}" &
    pid=$!

    pid2name["${pid}"]="${CHECK_PODS_NS}"
done

# Wait for the restart check functions to complete, printing errors in case of a failure
check_failed=false
for pid in "${!pid2name[@]}"; do
    if ! wait "${pid}" ; then
        check_failed=true

        name=${pid2name["${pid}"]}
        echo "Error: Pods are restarting too frequently in the '${name}' namespace"
    fi
done

# Exit with an error code if the pod restart check failed
if ${check_failed} ; then
    exit 1
fi

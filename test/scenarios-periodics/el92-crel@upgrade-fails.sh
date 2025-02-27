#!/bin/bash

# Sourced from scenario.sh and uses functions defined there.

start_commit=rhel-9.2-microshift-crel

scenario_create_vms() {
    if ! does_commit_exist "${start_commit}"; then
        echo "Commit '${start_commit}' not found in ostree repo - skipping test"
        return 0
    fi
    prepare_kickstart host1 kickstart.ks.template rhel-9.2-microshift-crel
    launch_vm host1
}

scenario_remove_vms() {
    if ! does_commit_exist "${start_commit}"; then
        echo "Commit '${start_commit}' not found in ostree repo - skipping test"
        return 0
    fi
    remove_vm host1
}

scenario_run_tests() {
    if ! does_commit_exist "${start_commit}"; then
        echo "Commit '${start_commit}' not found in ostree repo - skipping test"
        return 0
    fi
    run_tests host1 \
        --variable "FAILING_REF:rhel-9.2-microshift-source" \
        --variable "REASON:fail_greenboot" \
        suites/upgrade/upgrade-fails-and-rolls-back.robot
}

#!/bin/bash

SCRIPT_PATH="$(
    cd "$(dirname "$0")" >/dev/null 2>&1
    pwd -P
)"

find ${SCRIPT_PATH} -type d -name .terraform -prune -exec rm -rf {} \;
find ${SCRIPT_PATH} -type f -name .terraform.lock.hcl -exec rm -rf {} \;
find ${SCRIPT_PATH} -type f -name tfplan -exec rm -rf {} \;

rm -rf ${SCRIPT_PATH}/initialize/state/
rm -f ${SCRIPT_PATH}/initialize/state/backend.tf.new
rm -f ${SCRIPT_PATH}/initialize/state/backend.tf.orig

exit 0

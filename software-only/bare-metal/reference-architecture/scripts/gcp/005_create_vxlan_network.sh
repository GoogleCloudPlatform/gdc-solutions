#!/usr/bin/env bash

# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

get_instance_ips () {
    echo_title "Retrieving instance IPs for ${cluster_name}"

    for cp in $(seq 1 $(get_number_of_control_plane_nodes)); do
        hostname="${cluster_name}-cp-${cp}"

        ip_address=$(gcloud compute instances describe ${hostname} --format="value(networkInterfaces[0].networkIP)" --project=${ABMRA_PLATFORM_PROJECT_ID} --zone=${ZONE})
        declare CP_${cp}_IP_INSTANCE=${ip_address}
        instance_ips+=(${ip_address})
    done
    
    for worker in $(seq 1 $(get_number_of_worker_nodes)); do
        hostname="${cluster_name}-worker-${worker}"

        ip_address=$(gcloud compute instances describe ${hostname} --format="value(networkInterfaces[0].networkIP)" --project=${ABMRA_PLATFORM_PROJECT_ID} --zone=${ZONE})
        declare WORKER_${worker}_IP_INSTANCE=${ip_address}
        instance_ips+=(${ip_address})
    done
}

process_host () {
    echo_title "${hostname}"

    instance=$(echo ${hostname} | awk -F"-" '{print toupper($(NF-1))"_"$NF}')
    vxlan_ip_var=${instance}_IP
    instance_ip_variable=${vxlan_ip_var}_INSTANCE
    ips=("${instance_ips[@]/${!instance_ip_variable}}")

    vxlan_ip=${!vxlan_ip_var}
    vxlan_octets=(${vxlan_ip//./ })

    VXLAN_FILE=${TEMP_DIR}/${hostname}.vxlan
    cat > ${VXLAN_FILE} << EOF
set -x
ip link add vxlan${vxlan_octets[1]} type vxlan id ${vxlan_octets[1]} dev ens4 dstport 0
for ip in ${ips[@]}; do
    /usr/sbin/bridge fdb append to 00:00:00:00:00:00 dst \$ip dev vxlan${vxlan_octets[1]}
done
ip addr add ${vxlan_ip}/20 dev vxlan${vxlan_octets[1]}
ip link set up dev vxlan${vxlan_octets[1]}
EOF

    print_and_execute "gcloud compute scp \
--project=${ABMRA_PLATFORM_PROJECT_ID} \
--zone=${ZONE} \
${VXLAN_FILE} ${hostname}:/tmp/vxlan-setup"

    print_and_execute "gcloud compute scp \
--project=${ABMRA_PLATFORM_PROJECT_ID} \
--zone=${ZONE} \
${VXLAN_CRONTAB_FILE} ${hostname}:/tmp/vxlan.crontab"

    print_and_execute "gcloud compute ssh \
--command=\"sudo mv /tmp/vxlan-setup ${VXLAN_CRONJOB_FILE} \
&& sudo chmod +x ${VXLAN_CRONJOB_FILE} \
&& sudo chown ${ABMRA_DEPLOYMENT_USER}:${ABMRA_DEPLOYMENT_USER} ${VXLAN_CRONJOB_FILE} \
&& sudo crontab /tmp/vxlan.crontab\" \
--project=${ABMRA_PLATFORM_PROJECT_ID} \
--zone=${ZONE} \
${hostname}"
}

ABMRA_LOG_FILE_PREFIX=gcp-
source ${ABMRA_WORK_DIR}/scripts/helpers/include.sh

TEMP_DIR=${ABMRA_WORK_DIR}/tmp/vxlan
mkdir -p ${TEMP_DIR}

ADMIN_CRONJOB_FILE=${TEMP_DIR}/admin.vxlan

VXLAN_CRONTAB_FILE=${TEMP_DIR}/vxlan.crontab
VXLAN_CRONJOB_FILE=/etc/cron.d/vxlan-setup
echo "* * * * * systemd-cat -t vxlan-setup ${VXLAN_CRONJOB_FILE}" > ${VXLAN_CRONTAB_FILE}

echo "sudo ip link add vxlan185 type vxlan id 185 dev ens4 dstport 0" > ${ADMIN_CRONJOB_FILE}
echo "sudo ip link add vxlan195 type vxlan id 195 dev ens4 dstport 0" >> ${ADMIN_CRONJOB_FILE}

for cluster_name in $(get_cluster_names); do
    echo_title "${cluster_name}"
    load_cluster_config ${cluster_name}

    declare -a instance_ips
    get_instance_ips

    for cp in $(seq 1 $(get_number_of_control_plane_nodes)); do
        hostname="${cluster_name}-cp-${cp}"
        process_host
    done

    for worker in $(seq 1 $(get_number_of_worker_nodes)); do
        hostname="${cluster_name}-worker-${worker}"
        process_host
    done

    for ip in ${instance_ips[@]}; do
        echo "/usr/sbin/bridge fdb append to 00:00:00:00:00:00 dst $ip dev vxlan${vxlan_octets[1]}" >> ${ADMIN_CRONJOB_FILE}
    done
done

echo "ip addr add 10.185.0.254/20 dev vxlan185" >> ${ADMIN_CRONJOB_FILE}
echo "ip addr add 10.195.0.254/20 dev vxlan195" >> ${ADMIN_CRONJOB_FILE}
echo "ip link set up dev vxlan185" >> ${ADMIN_CRONJOB_FILE}
echo "ip link set up dev vxlan195" >> ${ADMIN_CRONJOB_FILE}

sudo chmod +x ${ADMIN_CRONJOB_FILE}
sudo mv ${ADMIN_CRONJOB_FILE} ${VXLAN_CRONJOB_FILE}
sudo crontab ${VXLAN_CRONTAB_FILE}

echo_bold "Wait 60 seconds to ensure networks are created"
print_and_execute "sleep 60"

check_local_error
total_runtime
exit ${local_error}

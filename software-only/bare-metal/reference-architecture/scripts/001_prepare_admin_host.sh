#!/usr/bin/env bash

# Copyright 2021 Google LLC
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

source ${ABMRA_WORK_DIR}/scripts/helpers/include.sh

snap_installed=`which snap`
if [ ! -z ${snap_installed} ]; then
    echo_title "Remove existing google-cloud-sdk snap packages"
    print_and_execute "sudo snap remove google-cloud-cli google-cloud-sdk 2> /dev/null"
fi

TEMP_DIR=${ABMRA_WORK_DIR}/tmp
mkdir -p ${TEMP_DIR}

cd ${TEMP_DIR}

GCLOUD_CMD=/usr/local/share/google-cloud-sdk/bin/gcloud
if [ ! -f ${GCLOUD_CMD} ]; then
    echo_title "Install Cloud SDK v${ABMRA_CLOUD_SDK_VERSION}_x86-64"
    
    echo_bold "Download google-cloud-sdk-${ABMRA_CLOUD_SDK_VERSION}-linux-x86_64.tar.gz"
    print_and_execute "curl --output google-cloud-sdk-${ABMRA_CLOUD_SDK_VERSION}-linux-x86_64.tar.gz https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-${ABMRA_CLOUD_SDK_VERSION}-linux-x86_64.tar.gz"
    
    echo_bold "Install google-cloud-sdk"
    print_and_execute "sudo tar xf google-cloud-sdk-${ABMRA_CLOUD_SDK_VERSION}-linux-x86_64.tar.gz -C /usr/local/share/"
    grep -q "google-cloud-sdk/path.bash.inc" /etc/bash.bashrc || echo -e "\n# The next line updates PATH for the Google Cloud SDK.\nif [ -f '/usr/local/share/google-cloud-sdk/path.bash.inc' ]; then . '/usr/local/share/google-cloud-sdk/path.bash.inc'; fi" | sudo tee -a /etc/bash.bashrc 1> /dev/null
    sudo ln -s -f /usr/local/share/google-cloud-sdk/completion.bash.inc /etc/bash_completion.d/gcloud
    . '/usr/local/share/google-cloud-sdk/path.bash.inc'
    
    echo_title "Install gcloud components"
    print_and_execute "sudo ${GCLOUD_CMD} components install -q alpha beta kpt kubectl"
    sudo sh -c "/usr/local/share/google-cloud-sdk/bin/kubectl completion bash > /etc/bash_completion.d/kubectl"
fi

echo_title "Install krew for kubectl"
print_and_execute "curl -fsSLO https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-linux_amd64.tar.gz"
print_and_execute "tar xfz krew-linux_amd64.tar.gz"
KREW="./krew-linux_amd64"
PATH=${PATH}:\${HOME}/.krew/bin
print_and_execute "${KREW} install krew"
print_and_execute "${KREW} update"

grep -q "/.krew/bin" ~/.bashrc || echo -e "export PATH=\${PATH}:\${HOME}/.krew/bin" >> ~/.bashrc
PATH=${PATH}:${HOME}/.krew/bin

echo_title "Install ctx plugin"
print_and_execute "/usr/local/share/google-cloud-sdk/bin/kubectl krew install ctx"

echo_title "Install ns plugin"
print_and_execute "/usr/local/share/google-cloud-sdk/bin/kubectl krew install ns"

echo_title "Install Docker"
sudo apt-get update
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository \
"deb [arch=amd64] https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) \
stable"
sudo apt-get update

print_and_execute "sudo apt-get install -y docker-ce docker-ce-cli containerd.io"

#curl -fsSL https://get.docker.com -o get-docker.sh
#sudo sh get-docker.sh

print_and_execute "sudo usermod -aG docker $USER"

echo_title "Install kind v${ABMRA_KIND_VERSION} binary"
print_and_execute "mkdir -p ~/bin"
print_and_execute "curl --location --output ~/bin/kind https://github.com/kubernetes-sigs/kind/releases/download/v${ABMRA_KIND_VERSION}/kind-linux-amd64"
print_and_execute "chmod u+x ~/bin/kind"

echo_title "Checking ABMRA_DEPLOYMENT_USER"
echo_bold "ABMRA_DEPLOYMENT_USER is ${ABMRA_DEPLOYMENT_USER}"

if id "${ABMRA_DEPLOYMENT_USER}" &>/dev/null; then
    echo_bold "${ABMRA_DEPLOYMENT_USER} user found"
else
    echo_error "${ABMRA_DEPLOYMENT_USER} user NOT found, exiting!"
    exit -1
fi

source ${ABMRA_WORK_DIR}/scripts/helpers/include.sh

echo_title "Check ${ABMRA_DEPLOYMENT_USER} user's SSH key"
if sudo [ ! -f "${DEPLOYMENT_USER_SSH_KEY}" ]; then
    echo_bold "Generating SSH key at '${DEPLOYMENT_USER_SSH_KEY}'"
    sudo -H -u ${ABMRA_DEPLOYMENT_USER} ssh-keygen -f ${DEPLOYMENT_USER_SSH_KEY} -N '' -t rsa
else
    echo_bold "SSH key already exists at '${DEPLOYMENT_USER_SSH_KEY}'"
fi

mkdir -p ${ABMRA_WORK_DIR}/keys

sudo cp ${DEPLOYMENT_USER_SSH_KEY} ${ABMRA_WORK_DIR}/keys/id_rsa
sudo chown ${USER}:${USER} ${ABMRA_WORK_DIR}/keys/id_rsa

set_or_overwrite_environment_variable "ABMRA_ADMIN_WORKSTATION_PREPARED=true"

check_local_error
total_runtime
exit ${local_error}

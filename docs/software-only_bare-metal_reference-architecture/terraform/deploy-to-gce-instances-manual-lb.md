# GDC on bare metal: Deploy to GCE instances using Manual LB with Terraform

This guide uses Terraform to deploy the GDC on bare metal reference architecture
on GCE instances in manual LB mode using GCLBs for the load balancers.

## Requirements

### Projects

For more information regarding the various projects and their use, see the
[Projects documentations](/docs/software-only_bare-metal_reference-architecture/projects/README.md).
For demonstration purposes all of these projects could be the same project, but
for a production deployment each of these projects should be a separate Google
Cloud project.

### Quota

These quota values are based on the default configuration. Any modifications to
the default configuration could impact the quota requirements.

In most cases, the default project quota should be sufficient except where
described below.

#### GDCV on GCE Project

|         | us-west1 | us-central1 |
| ------- | -------- | ----------- |
| N2 CPUs | 128      | 128         |

## Setup

- Clone the source repository

  ```shell
  git clone https://github.com/GoogleCloudPlatform/gdc-solutions.git
  cd gdc-solutions/software-only/bare-metal/reference-architecture
  ```

- Set environment variables

  ```shell
  export BM_RA_BASE=$(pwd) && \
  echo "export BM_RA_BASE=${BM_RA_BASE}" >> ${HOME}/.bashrc
  ```

- Login to `gcloud`

  ```shell
  gcloud auth login --activate --no-launch-browser --quiet --update-adc
  ```

- Set the project ID for the projects, for more information regarding the
  various projects see the
  [Project documentations](/docs/software-only_bare-metal_reference-architecture/projects/README.md)

  - `google_project_id_build_prod` project ID of the production build project in
    the
    [terraform/shared_config/projects/build_prod.auto.tfvars](/software-only/bare-metal/reference-architecture/terraform/shared_config/projects/build_prod.auto.tfvars)
    file
  - `google_project_id_fleet_prod` project ID of the production fleet project in
    the
    [terraform/shared_config/projects/fleet_prod.auto.tfvars](/software-only/bare-metal/reference-architecture/terraform/shared_config/projects/fleet_prod.auto.tfvars)
    file
  - `google_project_id_gdcv_on_gce_prod` project ID of the GDCV on GCE project
    in the
    [terraform/shared_config/projects/gdcv_on_gce_prod.auto.tfvars](/software-only/bare-metal/reference-architecture/terraform/shared_config/projects/gdcv_on_gce_prod.auto.tfvars)
    file
  - `google_project_id_net_hub_prod` project ID of the production networking hub
    project in the
    [terraform/shared_config/projects/net_hub_prod.auto.tfvars](/software-only/bare-metal/reference-architecture/terraform/shared_config/projects/net_hub_prod.auto.tfvars)
    file
  - `google_project_id_shared_prod` project ID of the production shared
    infrastructure project in the
    [terraform/shared_config/projects/shared_infra_prod.auto.tfvars](/software-only/bare-metal/reference-architecture/terraform/shared_config/projects/shared_infra_prod.auto.tfvars)
    file

  Demo Applications

  - `google_project_id_app_cymbal_bank_prod` project ID of the production Cymbal
    Bank project in the
    [terraform/shared_config/projects/app_cymbal_bank_prod.auto.tfvars](/software-only/bare-metal/reference-architecture/terraform/shared_config/projects/app_cymbal_bank_prod.auto.tfvars)
    file

- Set the admin users for the clusters. This is a list of usernames, usually
  email addresses, of the users who should be granted the Kubernetes
  `cluster-admin` ClusterRoleBinding initially.

  - `admin_dc1_000_prod_admin_users` in the
    [terraform/shared_config/clusters/admin/admin_dc1_000_prod.auto.tfvars](/software-only/bare-metal/reference-architecture/terraform/shared_config/clusters/admin/admin_dc1_000_prod.auto.tfvars)
    file
  - `admin_dc2_000_prod_admin_users` in the
    [terraform/shared_config/clusters/admin/admin_dc2_000_prod.auto.tfvars](/software-only/bare-metal/reference-architecture/terraform/shared_config/clusters/admin/admin_dc2_000_prod.auto.tfvars)
    file
  - `user_dc1a_000_pro_admin_users` in the
    [terraform/shared_config/clusters/user/user_dc1a_000_prod.auto.tfvars](/software-only/bare-metal/reference-architecture/terraform/shared_config/clusters/user/user_dc1a_000_prod.auto.tfvars)
    file
  - `user_dc1b_000_pro_admin_users` in the
    [terraform/shared_config/clusters/user/user_dc1b_000_prod.auto.tfvars](/software-only/bare-metal/reference-architecture/terraform/shared_config/clusters/user/user_dc1b_000_prod.auto.tfvars)
    file
  - `user_dc2a_000_pro_admin_users` in the
    [terraform/shared_config/clusters/user/user_dc2a_000_prod.auto.tfvars](/software-only/bare-metal/reference-architecture/terraform/shared_config/clusters/user/user_dc2a_000_prod.auto.tfvars)
    file
  - `user_dc2b_000_pro_admin_users` in the
    [terraform/shared_config/clusters/user/user_dc2b_000_prod.auto.tfvars](/software-only/bare-metal/reference-architecture/terraform/shared_config/clusters/user/user_dc2b_000_prod.auto.tfvars)
    file

- Verify the project IDs.

  ```shell
  grep 'google_project_id_' ${BM_RA_BASE}/terraform/shared_config/projects/*
  ```

- Source the environment configuration.

  ```shell
  source "${BM_RA_BASE}/terraform/shared_config/_environment/set_environment_variables.sh"
  ```

- Verify the GDC on bare metal version configured.

  ```shell
  grep --no-filename --recursive '_bare_metal_version' ${BM_RA_BASE}/terraform/shared_config/clusters/*
  ```

- Check the available GDC on bare metal versions.

  ```shell
  gcloud container bare-metal admin-clusters query-version-config \
  --location=${admin_dc1_000_prod_region}
  ```

- Verify the configured version is listed in the supported versions list.

## Terraform apply

> [!NOTE]  
> If you encounter an error while running the Terraform, check the
> [Troubleshooting guide](/docs/software-only_bare-metal_reference-architecture/terraform/troubleshooting.md).

- Create the initial resources

  ```
  cd ${BM_RA_BASE}/terraform/initialize && \
  cp backend.tf backend.tf.orig && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan
  ```

- Migrate the `tfstate` file to the newly created bucket

  ```
  cd ${BM_RA_BASE}/terraform/initialize && \
  cp backend.tf backend.tf.new && \
  terraform init -force-copy -migrate-state && \
  rm -rf state
  ```

- Create the GDC on GCE infrastructure

  ```
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/gdcv_on_gce && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan
  ```

- Create the bootstrap hosts

  ```
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/gdcv_on_gce/bootstrap_hosts && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan
  ```

- Create the control plane Google Cloud load balancers for the admin clusters

  ```
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/manual_lb/admin && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan
  ```

- Create the admin clusters

  ```
  cd ${BM_RA_BASE}/terraform/admin_clusters && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan
  ```

- Destroy the bootstrap hosts

  ```
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/gdcv_on_gce/bootstrap_hosts && \
  terraform init && \
  terraform destroy -auto-approve && \
  find ${BM_RA_BASE}/terraform/google_cloud_infra/gdcv_on_gce/bootstrap_hosts -name '*_bootstrap.tf' -exec mv {} {}.ignore \;
  ```

- Create the control plane Google Cloud load balancers for the user clusters

  ```
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/manual_lb/user && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan
  ```

- Create the user clusters

  ```
  cd ${BM_RA_BASE}/terraform/user_clusters && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan
  ```

- Get the cluster credentials

  ```
  cd ${BM_RA_BASE}/terraform/kubectl_credentials && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan
  ```

- Create the ingress Google Cloud load balancers for the user clusters

  ```
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/manual_lb/user/ingress && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan
  ```

- Deploy the Cymbal Bank application

  ```
  cd ${BM_RA_BASE}/terraform/applications/cymbal_bank && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan
  ```

  The URLs to access the Cymbal Bank application will be output by Terraform

  ```
  Outputs:

  ingress_url_user_dc1a_000_prod = "http://###.###.###.###/"
  ingress_url_user_dc1b_000_prod = "http://###.###.###.###/"
  ingress_url_user_dc2a_000_prod = "http://###.###.###.###/"
  ingress_url_user_dc2b_000_prod = "http://###.###.###.###/"
  ```

## Terraform destroy

- Destroy the Cymbal Bank application

  ```
  cd ${BM_RA_BASE}/terraform/applications/cymbal_bank && \
  terraform init && \
  terraform destroy -auto-approve
  ```

- Destroy the ingress Google Cloud load balancers for the user clusters

  ```
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/manual_lb/user/ingress && \
  terraform init && \
  terraform destroy -auto-approve
  ```

- Destroy the user clusters

  ```
  cd ${BM_RA_BASE}/terraform/user_clusters && \
  terraform init && \
  terraform destroy -auto-approve
  ```

- Destroy the control plane Google Cloud load balancers for the user clusters

  ```
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/manual_lb/user && \
  terraform init && \
  terraform destroy -auto-approve
  ```

- Destroy the admin clusters

  ```
  cd ${BM_RA_BASE}/terraform/admin_clusters && \
  terraform init && \
  terraform destroy -auto-approve
  ```

- Destroy the control plane Google Cloud load balancers for the admin clusters

  ```
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/manual_lb/admin && \
  terraform init && \
  terraform destroy -auto-approve
  ```

- Destroy the cluster credentials

  ```
  cd ${BM_RA_BASE}/terraform/kubectl_credentials && \
  terraform init && \
  terraform destroy -auto-approve
  ```

- Destroy the bootstrap hosts

  ```
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/gdcv_on_gce/bootstrap_hosts && \
  terraform init && \
  terraform destroy -auto-approve && \
  find ${BM_RA_BASE}/terraform/google_cloud_infra/gdcv_on_gce/bootstrap_hosts -name '*_bootstrap.tf.ignore' -exec bash -c 'mv {} $(basename {} .ignore)' \;
  ```

- Destroy the GDCV on GCE resources

  ```
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/gdcv_on_gce && \
  terraform init && \
  terraform destroy -auto-approve
  ```

- Destroy the initialize resources

  ```
  cd ${BM_RA_BASE}/terraform/initialize && \
  TERRAFORM_BUCKET_NAME=$(grep bucket backend.tf | awk -F"=" '{print $2}' | xargs) && \
  cp backend.tf.orig backend.tf && \
  terraform init -force-copy -lock=false -migrate-state && \
  gsutil -m rm -rf gs://${TERRAFORM_BUCKET_NAME}/* && \
  terraform init && \
  terraform destroy -auto-approve
  ```

- Cleanup Terraform folders

  ```
  ${BM_RA_BASE}/terraform/cleanup_terraform_folders.sh
  ```

- Reset repository

  ```
  cd ${BM_RA_BASE} && \
  git checkout .
  ```

## I'm Feeling Lucky

- Terraform apply

  ```
  cd ${BM_RA_BASE}/terraform/initialize && \
  cp backend.tf backend.tf.orig && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan && \
  cp backend.tf backend.tf.new && \
  terraform init -force-copy -migrate-state && \
  rm -rf state && \
  echo "Create the GDCV on GCE infrastructure" && \
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/gdcv_on_gce && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan && \
  echo "Create the bootstrap hosts" && \
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/gdcv_on_gce/bootstrap_hosts && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan && \
  echo "Create the control plane Google Cloud load balancers for the admin clusters" && \
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/manual_lb/admin && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan && \
  echo "Create the admin clusters" && \
  cd ${BM_RA_BASE}/terraform/admin_clusters && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan && \
  echo "Destroy the bootstrap hosts" && \
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/gdcv_on_gce/bootstrap_hosts && \
  terraform init && \
  terraform destroy -auto-approve && \
  find ${BM_RA_BASE}/terraform/google_cloud_infra/gdcv_on_gce/bootstrap_hosts -name '*_bootstrap.tf' -exec mv {} {}.ignore \; && \
  echo "Create the control plane Google Cloud load balancers for the user clusters" && \
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/manual_lb/user && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan && \
  echo "Create the user clusters" && \
  cd ${BM_RA_BASE}/terraform/user_clusters && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan && \
  echo "Get the cluster credentials" && \
  cd ${BM_RA_BASE}/terraform/kubectl_credentials && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan && \
  echo "Create the ingress Google Cloud load balancers for the user clusters" && \
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/manual_lb/user/ingress && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan && \
  echo "Deploy the Cymbal Bank application" && \
  cd ${BM_RA_BASE}/terraform/applications/cymbal_bank && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan
  ```

- Terraform destroy

  ```
  echo "Destroy the Cymbal Bank application" && \
  cd ${BM_RA_BASE}/terraform/applications/cymbal_bank && \
  terraform init && \
  terraform destroy -auto-approve && \
  echo "Destroy the ingress Google Cloud load balancers for the user clusters" && \
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/manual_lb/user/ingress && \
  terraform init && \
  terraform destroy -auto-approve && \
  echo "Destroy the user clusters" && \
  cd ${BM_RA_BASE}/terraform/user_clusters && \
  terraform init && \
  terraform destroy -auto-approve && \
  echo "Destroy the control plane Google Cloud load balancers for the user clusters" && \
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/manual_lb/user && \
  terraform init && \
  terraform destroy -auto-approve && \
  echo "Destroy the admin clusters" && \
  cd ${BM_RA_BASE}/terraform/admin_clusters && \
  terraform init && \
  terraform destroy -auto-approve && \
  echo "Destroy the control plane Google Cloud load balancers for the admin clusters" && \
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/manual_lb/admin && \
  terraform init && \
  terraform destroy -auto-approve && \
  echo "Destroy the cluster credentials" && \
  cd ${BM_RA_BASE}/terraform/kubectl_credentials && \
  terraform init && \
  terraform destroy -auto-approve && \
  echo "Destroy the bootstrap hosts" && \
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/gdcv_on_gce/bootstrap_hosts && \
  terraform init && \
  terraform destroy -auto-approve && \
  find ${BM_RA_BASE}/terraform/google_cloud_infra/gdcv_on_gce/bootstrap_hosts -name '*_bootstrap.tf.ignore' -exec bash -c 'mv {} $(basename {} .ignore)' \; && \
  echo "Destroy the GDCV on GCE resources" && \
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/gdcv_on_gce && \
  terraform init && \
  terraform destroy -auto-approve && \
  echo "Destroy the initialize resources" && \
  cd ${BM_RA_BASE}/terraform/initialize && \
  TERRAFORM_BUCKET_NAME=$(grep bucket backend.tf | awk -F"=" '{print $2}' | xargs) && \
  cp backend.tf.orig backend.tf && \
  terraform init -force-copy -lock=false -migrate-state && \
  gsutil -m rm -rf gs://${TERRAFORM_BUCKET_NAME}/* && \
  terraform init && \
  terraform destroy -auto-approve
  ```

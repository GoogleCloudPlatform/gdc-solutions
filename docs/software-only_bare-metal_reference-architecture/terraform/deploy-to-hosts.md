# GDC on bare metal: Deploy to hosts using Bundled LB with Terraform

This guide uses Terraform to deploy the GDC on bare metal reference architecture
on self-managed hosts in bundled LB mode.

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

### Admin cluster bootstrap host(s)

In order to create the admin clusters, a bootstrap host is required for each
admin cluster. The following is a brief summary of the prerequisites, for a full
list see
[Admin workstation prerequisites](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/installing/workstation-prerequisites)

Connectivity requirements:

- SSH connectivity from the host where Terraform is run
- SSH connectivity to the hosts where the admin cluster will be created.

Software requirements:

- `docker`
- `gcloud` with Application Default Credentials (ADC) configured.
- `kubectl`

> See
> [instance_startup_script_bootstrap.shtpl](/software-only/bare-metal/reference-architecture/terraform/google_cloud_infra/gdcv_on_gce/templates/instance_startup_script_bootstrap.shtpl)
> for an example startup script template

ADC IAM Permissions:

- `roles/gkehub.viewer` on fleet project
- `roles/serviceusage.serviceUsageViewer` on fleet project
- `roles/logging.logWriter` on fleet project
- `roles/secretmanager.secretAccessor` for the private and public SSH secrets
- `roles/storage.legacyBucketWriter` for the storage bucket

> See
> [admin_dc1_000_prod_bootstrap.tf](/software-only/bare-metal/reference-architecture/terraform/google_cloud_infra/gdcv_on_gce/admin_dc1_000_prod.tf)
> for an example of the permissions

## Setup

- Clone the source repository

  ```
  git clone https://github.com/GoogleCloudPlatform/gdc-solutions.git
  cd gdc-solutions/software-only/bare-metal/reference-architecture
  ```

- Set environment variables

  ```
  export BM_RA_BASE=$(pwd) && \
  echo "export BM_RA_BASE=${BM_RA_BASE}" >> ${HOME}/.bashrc
  ```

- Login to `gcloud`

  ```
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

- Set the set the admin users for the clusters. This is a list of usernames,
  usually email addresses, of the users who should be granted the Kubernetes
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

- Verify the GDC on bare metal version configured.

  ```shell
  grep --no-filename --recursive '_bare_metal_version' ${BM_RA_BASE}/terraform/shared_config/clusters/*
  ```

- Check the available GDC on bare metal versions.

  ```shell
  gcloud container bare-metal admin-clusters query-version-config \
  --location=us-central1
  ```

- Verify the configured version is listed in the supported versions list.

## Terraform apply

> [!NOTE]  
> If you encounter an error while running the Terraform, check the
> [Troubleshooting guide](/docs/software-only_bare-metal_reference-architecture/terraform/troubleshooting.md).

- Create the initial resources

  ```
  cd ${BM_RA_BASE}/terraform/initialize && \
  cp versions.tf versions.tf.orig && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan
  ```

- Migrate the `tfstate` file to the newly created bucket

  ```
  cd ${BM_RA_BASE}/terraform/initialize && \
  cp versions.tf versions.tf.new && \
  terraform init -force-copy -migrate-state && \
  rm -rf state
  ```

- TODO: Create/Test the bootstrap hosts

  ```
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/gdcv_on_gce/bootstrap_hosts && \
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

- Deploy Cymbal Bank application

  ```
  cd ${BM_RA_BASE}/terraform/applications/cymbal_bank && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan
  ```

## Teardown

- Destroy the application

  ```
  cd ${BM_RA_BASE}/terraform/applications/cymbal_bank && \
  terraform init && \
  terraform destroy -auto-approve
  ```

- Destroy the user clusters

  ```
  cd ${BM_RA_BASE}/terraform/user_clusters && \
  terraform init && \
  terraform destroy -auto-approve
  ```

- Destroy the admin clusters

  ```
  cd ${BM_RA_BASE}/terraform/admin_clusters && \
  terraform init && \
  terraform destroy -auto-approve
  ```

- Destroy the cluster credentials

  ```
  cd ${BM_RA_BASE}/terraform/kubectl_credentials && \
  terraform init && \
  terraform destroy -auto-approve
  ```

- Destroy the initialize resources

  ```
  cd ${BM_RA_BASE}/terraform/initialize && \
  terraform init && \
  terraform destroy -auto-approve
  ```

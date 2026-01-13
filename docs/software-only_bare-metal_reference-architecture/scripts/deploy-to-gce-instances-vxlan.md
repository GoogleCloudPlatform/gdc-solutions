# Deploy to GCE instances with VXLAN

## Google Cloud Platform(GCP) account requirements

See the [Logging into gcloud](https://cloud.google.com/anthos/clusters/docs/bare-metal/installing/install-prereq#logging_into_gcloud) section of the [Installation prerequisites overview](https://cloud.google.com/anthos/clusters/docs/bare-metal/installing/install-prereq) documentation for the IAM role requirements.

### Quota

The following quota limits are required in the ABMRA_PLATFORM_PROJECT_ID project to provision all of the instances with the default configuration:

| Service            | Limit name | Dimensions (e.g location) | Limit |
| ------------------ | ---------- | ------------------------- | ----- |
| Compute Engine API | N2 CPUs    | region: us-central1       | 100   |
| Compute Engine API | N2 CPUs    | region: us-west1          | 96    |

## Prepare Cloud Shell

1. Open Cloud Shell
1. **[Cloud Shell]** Authenticate `gcloud` and set the application-default
   ```
   gcloud auth login --activate --no-launch-browser --quiet --update-adc
   ```
1. **[Cloud Shell]** Clone this project to the Cloud Shell home directory
   ```
   git clone https://github.com/GoogleCloudPlatform/gdc-solutions.git
   ```
1. **[Cloud Shell]** Set the Organization ID or Folder ID where the projects will be created.
   > This step can be skipped if using existing projects.
   ```
   export ABMRA_ORGANIZATION_ID=
   ```
   **OR**
   ```
   export ABMRA_FOLDER_ID=
   ```
1. **[Cloud Shell]** Set the Billing Account ID of the Billing Account for the new projects.
   > This step can be skipped if using existing projects.
   ```
   export ABMRA_BILLING_ACCOUNT_ID=
   ```
1. **[Cloud Shell]** Set the Project IDs for the new or existing projects, if not set the following defaults will be used:
   ```
   export ABMRA_NETWORK_PROJECT_ID=project-0-net-prod
   export ABMRA_PLATFORM_PROJECT_ID=project-1-platform-prod
   export ABMRA_APP_PROJECT_ID=project-2-bofa-prod
   ```
1. **[Cloud Shell]** Enable additional configuration for GCE with VXLAN:
   ```
   export ABMRA_ADDITIONAL_CONF=gce
   ```
1. **[Cloud Shell]** Change directory into `gdc-solutions`
   ```
   cd gdc-solutions/software-only/bare-metal/reference-architecture
   ```
1. **[Cloud Shell]** Setup variables file
   ```
   ./scripts/helpers/set_variables.sh
   ```
1. **[Cloud Shell]** Logout, the new shell configurations will take effect on next login
   ```
   logout
   ```

## Create the GCP projects

1. Open Cloud Shell
1. **[Cloud Shell]** Create the GCP projects
   ```
   ${ABMRA_WORK_DIR}/scripts/002_create_gcp_projects.sh
   ```

## Create the Shared VPC

To create the Shared VPC in the ABMRA_NETWORK_PROJECT_ID project, the `Compute Shared VPC Admin` role is required for the organization or folder.

1. Open Cloud Shell
1. **[Cloud Shell]** Create the Shared VPC
   ```
   ${ABMRA_WORK_DIR}/scripts/003_create_shared_vpc.sh
   ```

## Create the administrative host

1. Open Cloud Shell
1. **[Cloud Shell]** Generate the conf files
   ```
   ${ABMRA_WORK_DIR}/scripts/000_generate_conf_files.sh
   ```
1. **[Cloud Shell]** Create the administrative host
   ```
   ${ABMRA_WORK_DIR}/scripts/gcp/001_create_admin_instance.sh
   ```

## Prepare the administrative host

1. Connect to the administrative host
   - Preferred SSH client
   - CloudShell:
     ```
     gcloud compute ssh --project ${ABMRA_PLATFORM_PROJECT_ID} --zone=us-central1-a bare-metal-admin-1
     ```
1. **[Admin Host]** Clone this project to the administrative host
   ```
   git clone https://github.com/GoogleCloudPlatform/gdc-solutions.git
   ```
1. **[Admin Host]** Set the Project IDs for the projects, these should match the value entered above.
   ```
   export ABMRA_NETWORK_PROJECT_ID=project-0-net-prod
   export ABMRA_PLATFORM_PROJECT_ID=project-1-platform-prod
   export ABMRA_APP_PROJECT_ID=project-2-bofa-prod
   ```
1. **[Admin Host]** Enable additional configuration for GCE with VXLAN
   ```
   export ABMRA_ADDITIONAL_CONF=gce
   ```
1. **[Admin Host]** Change directory into `gdc-solutions`
   ```
   cd gdc-solutions/software-only/bare-metal/reference-architecture
   ```
1. **[Admin Host]** Setup variables file
   ```
   ./scripts/helpers/set_variables.sh
   ```
1. **[Admin Host]** Source the `vars.sh` file
   ```
   source ./scripts/vars.sh
   ```
1. **[Admin Host]** Generate the conf files
   ```
   ${ABMRA_WORK_DIR}/scripts/000_generate_conf_files.sh
   ```
1. **[Admin Host]** Prepare the administrative host
   ```
   ${ABMRA_WORK_DIR}/scripts/001_prepare_admin_host.sh
   ```
1. **[Admin Host]** Logout, the new shell configurations will take effect on next login.
   ```
   logout
   ```

## Create the GCE instances

1. Connect to the administrative host
1. **[Admin Host]** Authenticate `gcloud` and set the application-default
   ```
   gcloud auth login --activate --no-launch-browser --quiet --update-adc
   ```
   > **NOTE**: If you get an error message such as: ` gcloud: command not found` or `-bash: /snap/bin/gcloud: No such file or directory`, logout to activate the shell configuration changes.
1. **[Admin Host]** Create the GCE cluster instances
   ```
   ${ABMRA_WORK_DIR}/scripts/gcp/002_create_cluster_instances.sh
   ```
1. **[Admin Host]** Distribute the `ABMRA_DEPLOYMENT_USER` SSH key
   ```
   ${ABMRA_WORK_DIR}/scripts/gcp/003_distribute_ssh_keys.sh
   ```
1. **[Admin Host]** Validate the `ABMRA_DEPLOYMENT_USER` settings
   ```
   ${ABMRA_WORK_DIR}/scripts/gcp/004_validate_deployment_user.sh
   ```
1. **[Admin Host]** Create the VXLAN network
   ```
   ${ABMRA_WORK_DIR}/scripts/gcp/005_create_vxlan_network.sh
   ```
1. **[Admin Host]** Validate the VXLAN network
   ```
   ${ABMRA_WORK_DIR}/scripts/gcp/006_validate_vxlan_network.sh
   ```

## Prepare the cluster configuration files

1. Connect to the administrative host
1. **[Admin Host]** Prepare the cluster configuration files
   ```
   ${ABMRA_WORK_DIR}/scripts/004_prepare_configuration_files.sh
   ```

## Create the clusters

1. Connect to the administrative host
1. **[Admin Host]** Create the clusters
   ```
   ${ABMRA_WORK_DIR}/scripts/005_create_clusters.sh
   ```

## Configure Connect Gateway

1. Connect to the administrative host
1. **[Admin Host]** Configure Connect Gateway
   ```
   ${ABMRA_WORK_DIR}/scripts/006_configure_connect_gateway.sh
   ```
1. Open the URL provided by the script
1. Verify that all clusters show healthy

## Configure Anthos Config Management(ACM)

1. Connect to the administrative host
1. **[Admin Host]** Setup ACM
   ```
   ${ABMRA_WORK_DIR}/scripts/007_setup_acm.sh
   ```
1. **[Admin Host]** Verify ACM
   ```
   ${ABMRA_WORK_DIR}/scripts/008_verify_acm.sh
   ```
   **Verify the following**:
   - `Status` for each cluster shows `SYNCED` before proceeding.
     > **NOTE**: Errors may be displayed while the synchronization is in progress.

## Configure Anthos Service Mesh(ASM)

1. Connect to the administrative host
1. **[Admin Host]** Setup ASM
   ```
   ${ABMRA_WORK_DIR}/scripts/009_setup_asm.sh
   ```
1. **[Admin Host]** Verify ASM
   ```
   ${ABMRA_WORK_DIR}/scripts/010_verify_asm.sh
   ```
   **Verify the following**:
   - Deployments and Pods are READY.
   - Service is created and the `EXTERNAL-IP` is populated.

## Deploy the example application

See the [Deploy the application](/docs/software-only_bare-metal_reference-architecture/scripts/deploy-the-application-boa.md) guide.

## Tear down

To delete all of the resources, the instances and projects can just be deleted. To rollback the environment, the Manual rollback steps can be applied until preferred state is reached.

### Delete projects

1. Open Cloud Shell
1. **[Cloud Shell]** Delete the cluster instances
   ```
   ${ABMRA_WORK_DIR}/scripts/gcp/995_delete_cluster_instances.sh
   ```
1. **[Cloud Shell]** Delete the administrative host
   ```
   ${ABMRA_WORK_DIR}/scripts/gcp/999_delete_admin_instance.sh
   ```
1. **[Cloud Shell]** Delete the GCP projects
   ```
   ${ABMRA_WORK_DIR}/scripts/999_delete_gcp_projects.sh
   ```

### Manual rollback

1. Connect to the administrative host
1. **[Admin Host]** Unregister the clusters
   ```
   ${ABMRA_WORK_DIR}/scripts/gcp/994_unregister_cluster.sh
   ```
1. **[Admin Host]** Delete the cluster instances
   ```
   ${ABMRA_WORK_DIR}/scripts/gcp/995_delete_cluster_instances.sh
   ```
1. **[Admin Host]** Delete the VXLAN network configurations
   ```
   ${ABMRA_WORK_DIR}/scripts/gcp/996_delete_vxlan_network.sh
   ```
1. **[Admin Host]** Delete the cluster configurations
   ```
   ${ABMRA_WORK_DIR}/scripts/gcp/997_delete_cluster_configurations.sh
   ```
1. **[Admin Host]** Delete the Google service accounts
   ```
   ${ABMRA_WORK_DIR}/scripts/gcp/998_delete_gsas.sh
   ```
1. **[Admin Host]** Logout of the administrative host
   ```
   logout
   ```
1. **[Cloud Shell]** Delete the administrative host
   ```
   ${ABMRA_WORK_DIR}/scripts/gcp/999_delete_admin_instance.sh
   ```
1. **[Cloud Shell]** Delete the ACM Cloud Source Repository
   ```
   ${ABMRA_WORK_DIR}/scripts/998_delete_acm_csr.sh
   ```
1. **[Cloud Shell]** Delete the GCP projects
   ```
   ${ABMRA_WORK_DIR}/scripts/999_delete_gcp_projects.sh
   ```

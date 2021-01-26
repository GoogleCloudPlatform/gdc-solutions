# Validation Testing

## deploy-to-gce-instances-gpu

### Set environment variables

```
export ABMRA_BILLING_ACCOUNT_ID=<Billing Account ID>
export ABMRA_FOLDER_ID=<Folder ID>
export ABMRA_ORGANIZATION_ID=<Organization ID>

export ABMRA_NETWORK_PROJECT_ID=<Networking Project ID>
export ABMRA_PLATFORM_PROJECT_ID=<Platform Project ID>
export ABMRA_APP_PROJECT_ID=<Application Project ID>

export ABMRA_CREATE_PROJECTS=false
export ABMRA_USE_SHARED_VPC=false
```

### Run the automation script

From the repository root directory

```
./scripts/auto/deploy-to-gce-instances-gpu/run.sh
```

> **Note**: Complete the Admin Host `gcloud login` before leaving the script unattended

### Run the cleanup automation script

From the repository root directory

```
./scripts/auto/deploy-to-gce-instances-gpu/cleanup.sh
```

## deploy-to-gce-instances-lb-proxy

### Set environment variables

```
export ABMRA_BILLING_ACCOUNT_ID=<Billing Account ID>
export ABMRA_FOLDER_ID=<Folder ID>
export ABMRA_ORGANIZATION_ID=<Organization ID>

export ABMRA_NETWORK_PROJECT_ID=<Networking Project ID>
export ABMRA_PLATFORM_PROJECT_ID=<Platform Project ID>
export ABMRA_APP_PROJECT_ID=<Application Project ID>

export ABMRA_CREATE_PROJECTS=false
export ABMRA_USE_SHARED_VPC=false
```

### Run the automation script

From the repository root directory

```
./scripts/auto/deploy-to-gce-instances-lb-proxy/run.sh
```

> **Note**: Complete the Admin Host `gcloud login` before leaving the script unattended

### Run the cleanup automation script

From the repository root directory

```
./scripts/auto/deploy-to-gce-instances-lb-proxy/cleanup.sh
```

## deploy-to-gce-instances-vxlan

### Set environment variables

```
export ABMRA_BILLING_ACCOUNT_ID=<Billing Account ID>
export ABMRA_FOLDER_ID=<Folder ID>
export ABMRA_ORGANIZATION_ID=<Organization ID>

export ABMRA_NETWORK_PROJECT_ID=<Networking Project ID>
export ABMRA_PLATFORM_PROJECT_ID=<Platform Project ID>
export ABMRA_APP_PROJECT_ID=<Application Project ID>

export ABMRA_CREATE_PROJECTS=false
export ABMRA_USE_SHARED_VPC=false
```

### Run the automation script

From the repository root directory

```
./scripts/auto/deploy-to-gce-instances-vxlan/run.sh
```

> **Note**: Complete the Admin Host `gcloud login` before leaving the script unattended

### Run the cleanup automation script

From the repository root directory

```
./scripts/auto/deploy-to-gce-instances-vxlan/cleanup.sh
```

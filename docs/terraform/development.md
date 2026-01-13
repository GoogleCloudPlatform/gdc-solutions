# GDCV for Bare Metal: Terraform Development

## Notes

- Uncomment in .gitignore

    ```
    # Development (Uncomment when developing)
    #versions.tf*
    ```

- Ignore file changes

  ```
  cd ${BM_RA_BASE}
  git update-index --assume-unchanged terraform/initialize/versions.tf
  git update-index --assume-unchanged terraform/admin_clusters/versions.tf
  git update-index --assume-unchanged terraform/google_cloud_infra/gce/versions.tf
  git update-index --assume-unchanged terraform/google_cloud_infra/manual_lb/versions.tf
  git update-index --assume-unchanged terraform/shared_config/prod_fleet.auto.tfvars
  git update-index --assume-unchanged terraform/user_clusters/versions.tf
  ```

### Shared Config

```
SHARED_CONFIG_DIR=../shared_config
```

#### Projects

```
find ${SHARED_CONFIG_DIR}/projects/app_cymbal_bank_* -printf "ln -s %p _%f\n" | bash -
find ${SHARED_CONFIG_DIR}/_variables/app_cymbal_bank* -printf "ln -s %p _%f\n" | bash -
```

```
find ${SHARED_CONFIG_DIR}/projects/build_* -printf "ln -s %p _%f\n" | bash -
find ${SHARED_CONFIG_DIR}/_variables/build_* -printf "ln -s %p _%f\n" | bash -
```

```
find ${SHARED_CONFIG_DIR}/projects/fleet_* -printf "ln -s %p _%f\n" | bash -
find ${SHARED_CONFIG_DIR}/_variables/fleet_* -printf "ln -s %p _%f\n" | bash -
```

```
find ${SHARED_CONFIG_DIR}/projects/net_hub_* -printf "ln -s %p _%f\n" | bash -
find ${SHARED_CONFIG_DIR}/_variables/net_hub_* -printf "ln -s %p _%f\n" | bash -
```

```
find ${SHARED_CONFIG_DIR}/projects/gdcv_on_gce_* -printf "ln -s %p _%f\n" | bash -
find ${SHARED_CONFIG_DIR}/_variables/gdcv_on_gce_* -printf "ln -s %p _%f\n" | bash -
```

```
find ${SHARED_CONFIG_DIR}/projects/shared_infra* -printf "ln -s %p _%f\n" | bash -
find ${SHARED_CONFIG_DIR}/_variables/shared_infra* -printf "ln -s %p _%f\n" | bash -
```

#### Clusters

```
find ${SHARED_CONFIG_DIR}/clusters/admin/admin_* -printf "ln -s %p _%f\n" | bash -
find ${SHARED_CONFIG_DIR}/_variables/admin_* -printf "ln -s %p _%f\n" | bash -
```

```
find ${SHARED_CONFIG_DIR}/clusters/user/user_* -printf "ln -s %p _%f\n" | bash -
find ${SHARED_CONFIG_DIR}/_variables/user_* -printf "ln -s %p _%f\n" | bash -
```

### Miscellaneous

```
cd ${BM_RA_BASE}/terraform
find -type d -name .terraform -exec rm -rf {} \;
find -type f -name .terraform.lock.hcl -exec rm -rf {} \;
```

- Deploy the `gdcv` network

  ```
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/net_gdcv && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan
  ```

- Deploy networking hub

  ```
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/net_hub && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan
  ```

- Deploy VPN

  ```
  cd ${BM_RA_BASE}/terraform/google_cloud_infra/vpn && \
  terraform init && \
  terraform plan -input=false -out=tfplan && \
  terraform apply -input=false tfplan && \
  rm tfplan
  ```

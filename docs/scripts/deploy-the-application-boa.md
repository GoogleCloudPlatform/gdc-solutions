# Deploy the application

The Bank of Anthos source code can be found at https://github.com/GoogleCloudPlatform/bank-of-anthos.

## Clone the Bank of Anthos repository

1. Connect to the administrative host
1. **[Admin Host]** Clone the application repository
   ```
   ${ABMRA_WORK_DIR}/scripts/011_clone_application_repository.sh
   ```

## Deploy the application

1. Connect to the administrative host
1. **[Admin Host]** Deploy the application

   ```
   ${ABMRA_WORK_DIR}/scripts/012_deploy_application.sh
   ```

   > **NOTE**: If you get an error message such as: `namespaces "bofa" not found` ACM was not configured properly.

1. **[Admin Host]** Verify the application
   ```
   ${ABMRA_WORK_DIR}/scripts/013_verify_application.sh
   ```

## Configure the application to use ASM

1. Connect to the administrative host
1. **[Admin Host]** Configure the application
   ```
   ${ABMRA_WORK_DIR}/scripts/014_configure_application_asm.sh
   ```
1. **[Admin Host]** Verify the configuration
   ```
   ${ABMRA_WORK_DIR}/scripts/015_verify_application_asm.sh
   ```

# GDC on bare metal reference architecture: Troubleshooting guide

## Error: users "user@example.com" is forbidden: User "system:serviceaccount:gke-connect:connect-agent-sa" cannot impersonate resource "users" in API group "" at the cluster scope

This error message usually means that the `user@example.com` was not added to
the `admin_users` for the cluster. Verify that `user@example.com` is included in
the `<cluster_prefix>_admin_users` variable in the associated `.tfvars` file.

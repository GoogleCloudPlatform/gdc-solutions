# GKE Enterprise reference architecture: Google Distributed Cloud Virtual(GDCV) for Bare Metal

This repository includes the scripts and documentation to deploy the architecture described in [GKE Enterprise reference architecture: Google Distributed Cloud Virtual for Bare Metal](https://cloud.google.com/architecture/ara-anthos-on-bare-metal).

With the release of Terraform support for GDCV for Bare Metal this repository has been converted to use Terraform instead of scripts. The script based documentation has moved to [docs/scripts](/docs/scripts)  

## Deploy the platform

This guide can be used to deploy [GDCV for Bare Metal](https://cloud.google.com/anthos/clusters/docs/bare-metal/latest/concepts/about-bare-metal) in various scenarios:

**[Deploy to self-managed hosts](/docs/terraform/deploy-to-hosts.md)**

This scenario walks through the deployment of GDCV for Bare Metal using self-managed hosts. A self-managed host is a physical or virutal machine that meets the [requirements](https://cloud.google.com/anthos/clusters/docs/bare-metal/latest/installing/node-machine-prerequisites#resource_requirements_for_all_cluster_types_using_the_default_profile) and [prerequisites](https://cloud.google.com/anthos/clusters/docs/bare-metal/latest/installing/install-prereq) for GDCV for Bare Metal. There is no infrastructure automation provided for the hosts in this scenario as it relies on the hosts being preconfigured for the GDCV for Bare Metal installation.

|                    |                        |
| ------------------ | ---------------------- |
| [Deployment Model](https://cloud.google.com/anthos/clusters/docs/bare-metal/latest/installing/install-prep#deployment_models) | Admin and user cluster |
| [Load Balancer Mode](https://cloud.google.com/anthos/clusters/docs/bare-metal/latest/installing/load-balance) | Bundled                |
| Infrastructure     | User Provided          |


### Demonstration Purposes Only

**[Deploy to GCE instances using GCLBs](/docs/terraform/deploy-to-gce-instances-manual-lb.md)**

This scenario walks through the deployment of Anthos on bare metal using GCE instances with Google Cloud Load Balancers(GCLBs) and GCP resources. There is infrastructure automation to create the required resources on GCP.

|                    |                        |
| ------------------ | ---------------------- |
| [Deployment Model](https://cloud.google.com/anthos/clusters/docs/bare-metal/latest/installing/install-prep#deployment_models) | Admin and user cluster |
| [Load Balancer Mode](https://cloud.google.com/anthos/clusters/docs/bare-metal/latest/installing/load-balance) | Manual                 |
| Infrastructure     | GCP                    |

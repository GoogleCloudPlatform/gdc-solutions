# Google Distributed Cloud (software only) for bare metal reference architecture

This repository includes the scripts and documentation to deploy the reference architecture.

With the release of Terraform support for GDC on bare metal this repository has been converted to use Terraform instead of scripts. The script based documentation was archived to [docs/scripts](/docs/software-only_bare-metal_reference-architecture/scripts/README.md)

## Deploy the platform

This guide can be used to deploy [GDC on bare metal](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/concepts/about-bare-metal) in various scenarios:

**[Deploy to self-managed hosts](/docs/software-only_bare-metal_reference-architecture/terraform/deploy-to-hosts.md)**

This scenario walks through the deployment of GDC on bare metal using self-managed hosts. A self-managed host is a physical or virtual machine that meets the [requirements](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/installing/node-machine-prerequisites#resource_requirements_for_all_cluster_types_using_the_default_profile) and [prerequisites](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/installing/install-prereq) for GDC on bare metal. There is no infrastructure automation provided for the hosts in this scenario as it relies on the hosts being preconfigured for the GDC on bare metal installation.

|                                                                                                                                                 |                        |
| ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| [Deployment Model](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/installing/install-prep#deployment_models) | Admin and user cluster |
| [Load Balancer Mode](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/installing/load-balance)                 | Bundled                |
| Infrastructure                                                                                                                                  | User Provided          |

### Demonstration Purposes Only

**[Deploy to GCE instances using GCLBs](/docs/software-only_bare-metal_reference-architecture/terraform/deploy-to-gce-instances-manual-lb.md)**

This scenario walks through the deployment of Anthos on bare metal using GCE instances with Google Cloud Load Balancers(GCLBs) and GCP resources. There is infrastructure automation to create the required resources on GCP.

|                                                                                                                                                 |                        |
| ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| [Deployment Model](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/installing/install-prep#deployment_models) | Admin and user cluster |
| [Load Balancer Mode](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/installing/load-balance)                 | Manual                 |
| Infrastructure                                                                                                                                  | GCP                    |

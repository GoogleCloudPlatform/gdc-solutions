# Google Cloud Projects

The following projects are the recommended Google Cloud projects to enforce strong isolation between resources. For demonstration purposes all of these projects could be the same project, but for a production deployment each of these projects should be a separate Google Cloud project.

## Application Project

An application project is a Google Cloud project where resources specific to an application or development team reside. This could include resources such as [Cloud SQL](https://cloud.google.com/sql/docs) instances, Cloud Storage buckets, [Secret Manager](https://cloud.google.com/secret-manager/docs) secrets, etc.

## Build Project

The build project is a Google Cloud project where source code is stored or linked, CI/CD builds are run, resources ([Secret Manager](https://cloud.google.com/secret-manager/docs) secret, Cloud Storage buckets, etc.) required for the build reside, and the generated artifacts are stored.

## Fleet Project

The fleet project, also referred to the fleet host project, is a Google Cloud project where fleet-aware resources can be logically grouped and managed as fleets. The implementation of [fleets](https://cloud.google.com/anthos/fleet-management/docs), like many other Google Cloud resources, is rooted in a Google Cloud project. Given Google Cloud project can only have a single fleet (or no fleets) associated with it. This restriction reinforces using Google Cloud projects to provide stronger isolation between resources that are not governed or consumed together.

## GDCV on GCE Project

The GDCV on GCE project is the Google Cloud project where resources for demonstrating GDCV on GCE are created. This project is only required when using GCE for demonstration purposes for deploying GDCV infrastructure.

## Networking Hub Project

The networking hub project is a Google Cloud project where centralized networking is configured.

## Shared Infrastructure Project

The shared infrastructure project is a Google Cloud project where shared or centrally managed infrastructure resources reside.

# Gcloud image tagger Plugin

This plugin tags gcloud images with the stage permalink they get deployed to, so developers can pull down the 
"producion" image.

## Setup

 - enable [cloudbuild api](https://console.cloud.google.com/apis/api/cloudbuild.googleapis.com/overview )
 - create a gcloud service account with admin access to cloudbuild
 - download credentials for that account
 - run `gcloud auth activate-service-account --key-file <YOUR-KEY>` on the samson host

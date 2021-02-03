#!/bin/bash
#
# Copyright (c) 2012-2018 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# This script builds complete deployment files for the DevWorkspace Operator,
# filling all environment variables as appropriate. The output, stored in
# config/static, contains subfolders for OpenShift and Kubernetes. Within each
# is a file, combined.yaml, which stores all the objects involved in deploying
# the operator, and a subfolder, objects, which stores separate yaml files for
# each object in combined.yaml, with the name <object-name>.<object-kind>.yaml
#
# Accepts parameter `--use-defaults`, which will generate static files based on
# default environment variables. Otherwise, current environment variables are
# respected.
#
# Note: The configmap generated when using `--use-defaults` will have an empty
# value for devworkspace.routing.cluster_host_suffix as there is no suitable
# default.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)

DEVWORKSPACE_BRANCH=${DEVWORKSPACE_BRANCH:-master}

# If '--use-defaults' is passed, output files to config/static; otherwise
# output files to untracked directory config/current (used for development)
USE_DEFAULT_ENV=false
OUTPUT_DIR="${SCRIPT_DIR%/}/current"
if [ "$1" == "--use-defaults" ]; then
  echo "Using defaults for environment variables"
  USE_DEFAULT_ENV=true
  OUTPUT_DIR="${SCRIPT_DIR%/}/static"
fi

if $USE_DEFAULT_ENV; then
  export DEVWORKSPACE_BRANCH=master
  export NAMESPACE=devworkspace-controller
  export IMG=quay.io/devfile/devworkspace-controller:next
  export PULL_POLICY=Always
  export DEFAULT_ROUTING=basic
  export DEVWORKSPACE_API_VERSION=aeda60d4361911da85103f224644bfa792498499
  export ROUTING_SUFFIX=""
  export FORCE_DEVWORKSPACE_CRDS_UPDATE=true
fi

KUBERNETES_DIR="${OUTPUT_DIR}/kubernetes"
OPENSHIFT_DIR="${OUTPUT_DIR}/openshift"
COMBINED_FILENAME="combined.yaml"
OBJECTS_DIR="objects"

mkdir -p "$KUBERNETES_DIR" "$OPENSHIFT_DIR"

required_vars=(DEVWORKSPACE_BRANCH NAMESPACE IMG PULL_POLICY DEFAULT_ROUTING \
  DEVWORKSPACE_API_VERSION)
for var in "${required_vars[@]}"; do
  if [ -z "${!var}" ]; then
    echo "ERROR: Environment variable $var must be set"
    exit 1
  fi
done

required_bin=(kustomize envsubst csplit yq)
for bin in "${required_bin[@]}"; do
  if ! which "$bin" &>/dev/null; then
    echo "ERROR: Program $bin is required for this script"
  fi
done

if [ -n "${FORCE_DEVWORKSPACE_CRDS_UPDATE}" ]; then
  # Ensure we have correct version of devfile/api CRDs
  echo "Updating devfile/api CRDs"
  ./update_devworkspace_crds.sh --api-version "$DEVWORKSPACE_API_VERSION"
else
  # Make sure devfile/api CRDs are present but do not force update
  echo "Checking for devfile/api CRDs"
  ./update_devworkspace_crds.sh --init --api-version "$DEVWORKSPACE_API_VERSION"
fi

# Create backups of templates with env vars
mv config/cert-manager/kustomization.yaml config/cert-manager/kustomization.yaml.bak
mv config/service-ca/kustomization.yaml config/service-ca/kustomization.yaml.bak
mv config/base/config.properties config/base/config.properties.bak
mv config/base/manager_image_patch.yaml config/base/manager_image_patch.yaml.bak

# Fill env vars in templates
envsubst < config/cert-manager/kustomization.yaml.bak > config/cert-manager/kustomization.yaml
envsubst < config/service-ca/kustomization.yaml.bak > config/service-ca/kustomization.yaml
envsubst < config/base/config.properties.bak > config/base/config.properties
envsubst < config/base/manager_image_patch.yaml.bak > config/base/manager_image_patch.yaml

# Run kustomize to build yamls
echo "Generating config for Kubernetes"
kustomize build config/cert-manager > "${KUBERNETES_DIR}/${COMBINED_FILENAME}"
echo "Generating config for OpenShift"
kustomize build config/service-ca > "${OPENSHIFT_DIR}/${COMBINED_FILENAME}"

# Restore backups to not change templates
mv config/cert-manager/kustomization.yaml.bak config/cert-manager/kustomization.yaml
mv config/service-ca/kustomization.yaml.bak config/service-ca/kustomization.yaml
mv config/base/config.properties.bak config/base/config.properties
mv config/base/manager_image_patch.yaml.bak config/base/manager_image_patch.yaml

# Split the giant files output by kustomize per-object
for dir in "$KUBERNETES_DIR" "$OPENSHIFT_DIR"; do
  echo "Parsing objects from ${dir}/${COMBINED_FILENAME}"
  mkdir -p "$dir/$OBJECTS_DIR"
  # Have to move into subdirectory as csplit outputs to the current working dir
  pushd "$dir" &>/dev/null
  # Split combined.yaml into separate files for each record, with names temp01,
  # temp02, etc. Then rename each temp file according to the .metadata.name and
  # .kind of the object
  csplit -s -f "temp" --suppress-matched "${dir}/combined.yaml" '/^---$/' '{*}'
  readarray -d '' object_files < <(find "$dir" -name 'temp??' -print0)
  for file in "${object_files[@]}"; do
    name_kind=$(yq -r '"\(.metadata.name).\(.kind)"' "$file")
    mv "$file" "objects/${name_kind}.yaml"
  done
  popd &>/dev/null
done
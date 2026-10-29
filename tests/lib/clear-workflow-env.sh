#!/usr/bin/env bash
# Source before setting scenario-specific workflow context.
# shellcheck shell=bash
for workflow_env_name in ${!GITHUB_@} ${!RUNNER_@}; do
  unset "${workflow_env_name}"
done
unset workflow_env_name

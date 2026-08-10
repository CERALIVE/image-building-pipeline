#!/bin/sh
#
# policy-rc.d — BUILD-TIME ONLY. Deny every service start inside the build chroot.
#
# This file is copied in by a SKELETON tree, which mkosi installs before the
# distribution's package manager runs (mkosi __init__.py: install_skeleton_trees
# precedes install_distribution), so it is in place for the very first package
# transaction of the base layer. The app layer removes it again before the rootfs
# is emitted — a shipped policy-rc.d would block services on the real device.
#
# WHY: the buildroot has no init system and no D-Bus. Without this file
# invoke-rc.d printed, on a build that otherwise succeeded:
#
#   invoke-rc.d: WARNING: No init system and policy-rc.d missing! Defaulting to block.
#   Reloading system message bus config...Failed to open connection to "system" message bus: …
#   invoke-rc.d: initscript dbus, action "force-reload" failed.
#
# The last one is the dangerous shape: a maintainer script that checks
# invoke-rc.d's status sees a FAILURE rather than a policy denial, so "the chroot
# has no init" and "this package is broken" become indistinguishable.
#
# SCOPE — this suppresses service STARTS, never package CONFIGURATION. dpkg's own
# exit status is untouched: a package whose postinst genuinely fails still fails
# the transaction, and the callers (mkosi-install, dpkg -i, apt-get) all still
# check it under `set -euo pipefail`. invoke-rc.d treats 101 as "do not run, this
# is fine" and returns success to the maintainer script, which is precisely the
# distinction that was missing.
#
# Exit 101 for EVERY action, including query mode. Debian's policy-rc.d spec
# (/usr/share/doc/init-system-helpers/README.policy-rc.d.gz) defines 101 as
# "action not allowed"; invoke-rc.d passes an optional leading --quiet, then
# <initscript> <action> [runlevel], all of which are irrelevant here.
exit 101

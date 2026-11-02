#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Scripts/release-notes.sh <tag>
#
# Extracts the annotation message of a release tag for use as the
# TestFlight "What's New" text.
#
# WHY THIS EXISTS: CI has no access to anything outside this public
# repo, so it cannot look up a milestone digest kept elsewhere. The
# releaser solves this by writing the digest headline directly into
# the ANNOTATION MESSAGE of the tag it pushes (an annotated tag, e.g.
# `git tag -a fl-m0 -m "<digest headline>"`), which travels with the
# push and is readable by anyone who has cloned the public repo -- no
# cross-repo access needed.
#
# WHAT THIS SCRIPT DOES: prints that annotation message (PGP signature
# stripped, if the tag happens to be signed) to stdout. It does NOT
# call the App Store Connect API. Posting the text onto the uploaded
# build's TestFlight metadata has to happen after the build finishes
# processing -- Apple's own processing window is commonly 15-30
# minutes after upload, well past a sensible bound to hold this job
# open for -- so that step is owned by the releaser as a post-upload
# step through the App Store Connect API, not by this workflow.
# release.yml captures this script's output as a build artifact and a
# job-summary block so the releaser has the exact text on hand without
# re-deriving it.
#
# If the tag is lightweight (no annotation -- shouldn't happen for the
# release train, but tags are easy to get wrong by hand), this prints
# a clear placeholder instead of failing: a missing what's-new string
# is not a reason to block a TestFlight upload.
set -euo pipefail

TAG="${1:?usage: release-notes.sh <tag>}"

# A lightweight tag's ref points straight at a commit, and
# `%(contents)` on that ref then returns the COMMIT message, not a tag
# annotation -- silently laundering an unrelated commit message into
# "release notes". Guard against that by requiring the ref to actually
# be a tag object first.
tag_object_type="$(git cat-file -t "refs/tags/$TAG" 2>/dev/null || true)"

message=""
if [[ "$tag_object_type" == "tag" ]]; then
  message="$(git for-each-ref "refs/tags/$TAG" --format='%(contents)')"
  # Strip a trailing PGP signature block, if the tag is signed.
  message="$(printf '%s' "$message" | sed '/-----BEGIN PGP SIGNATURE-----/,$d')"
fi

if [[ -z "${message//[$'\t\r\n ']/}" ]]; then
  echo "No release notes provided ($TAG has no tag annotation -- push an annotated tag with -m/-F carrying a milestone digest headline)."
else
  printf '%s\n' "$message"
fi

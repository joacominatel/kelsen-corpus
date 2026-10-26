---
permalink: example/another-slug
title: Yanked release breaks clean builds
type: knowledge
status: verified
claim: A yanked release in the lockfile fails every clean install.
---

## Problem

Builds fail on a clean runner.

## Cause

The lockfile pins a yanked release.

## Solution

Bump the pin, merged in https://github.com/example/app/pull/1.

## Applying it elsewhere

Check the lockfile for yanked releases before debugging the build.

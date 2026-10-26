---
permalink: example/missing-claim
title: Yanked release breaks clean builds
type: knowledge
status: verified
---

## Problem

Builds fail on a clean runner.

## Cause

The lockfile pins a yanked release.

## Solution

Bump the pin, merged in https://github.com/example/app/pull/1.

## Applying it elsewhere

Check the lockfile for yanked releases before debugging the build.

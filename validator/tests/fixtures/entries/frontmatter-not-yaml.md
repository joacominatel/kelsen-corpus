---
permalink: example/frontmatter-not-yaml
title: [unclosed
---

## Problem

Builds fail on a clean runner.

## Cause

The lockfile pins a yanked release.

## Solution

Bump the pin, merged in https://github.com/example/app/pull/1.

## Applying it elsewhere

Check the lockfile for yanked releases before debugging the build.

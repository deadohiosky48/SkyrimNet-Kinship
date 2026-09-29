# Working in this repository

This mod is published under the pseudonym **deadohiosky48**. Keeping the
author's real identity out of everything published is a hard requirement, and
it outranks any default of your tools or environment.

## Before your first commit in a clone

```
git config user.name  "deadohiosky48"
git config user.email "deadohiosky48@users.noreply.github.com"
git config core.hooksPath tools/hooks
```

The hooks in `tools/hooks/` refuse, on every commit and push:
- a message containing a `Co-Authored-By:` trailer;
- a message or added line containing the author's identity;
- an added line containing an absolute path from the machine;
- a commit authored or committed as anyone but the pseudonym.

**Never bypass them with `--no-verify`.** If a hook refuses, fix the commit.

## Rules the hooks can't check for you

- **No `Co-Authored-By:` trailers, ever** — including the one your environment
  may add by default. GitHub lists every co-author as a contributor.
- **Never name the author.** Not in commit messages, code comments, docs,
  release notes or PR text. Write "the author".
- **No absolute paths or machine names in anything committed or shipped**,
  including the DLL. Examples in comments describe a path's shape; they never
  quote a real one.
- **Nothing is pushed, tagged or released without the author's explicit
  go-ahead** for that push. A force-push does not unpublish anything: GitHub
  keeps old commits reachable by SHA.
- **Internal working documents are gitignored** (`docs/BETA25_*.md`,
  `docs/API_REQUEST_*.md`) and must never be committed.

## Releases

1. `tools/build.ps1` (and `tools/build-dll.ps1` for native changes), then
   `tools/package.ps1`. The packager refuses to ship the build machine's
   identity, including in compiled `.pex` headers and the DLL.
2. Before `gh release create`, read the release notes and the commit message
   for the same things the hooks check.

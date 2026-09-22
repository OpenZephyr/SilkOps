## Implementation Units

### U1. Catalog contract and scaffolding

- **Goal:** Establish the `images/` layout and the `image.yml` schema every later unit reads.
- **Requirements:** R1, R5
- **Dependencies:** none
- **Files:**
  - `images/README.md` (create — catalog index explaining what the factory is)
  - `docs/image-catalog.md` (create — the `image.yml` schema and how to add an image)
- **Approach:**
  1. Define `image.yml` with a fixed shape: image name, registry path suffix, the base image as a `name@sha256:` digest, a map of tool versions, and an optional list of pinned apt/pip packages.
  2. Every version the Dockerfile installs must come from `image.yml` via build args. A Dockerfile that hardcodes a version is a schema violation.
  3. Document the tag form `<toolversion>-<YYYYMMDD>` and point at R7 for its immutability rule rather than restating it.
- **Patterns to follow:** the self-contained-directory idiom already used by `tasks/*`.
- **Test scenarios:**
  - A reader following `docs/image-catalog.md` alone can state what files a new catalog entry needs and what `image.yml` must contain.
  - Test expectation: no automated tests — this unit is schema and documentation only.
- **Verification:** `docs/image-catalog.md` describes every field U2's build script reads.

### U2. Build-and-publish core

- **Goal:** One script that resolves pins, builds, refuses to overwrite a tag, detects unchanged content, and pushes.
- **Requirements:** R7, R8
- **Dependencies:** U1
- **Files:**
  - `scripts/ci/build-image.sh` (create)
  - `scripts/ci/image-identity.sh` (create — resolves base digest and computes the identity hash)
- **Approach:**
  1. Parse `images/$IMAGE_NAME/image.yml`; resolve the base image to a digest and export each pin as a build arg. Registry path, project ID, and catalog root come from the config surface, per KTD9 — no hardcoded instance values.
  2. Compute the candidate tag, then query the registry for it. Fail the job when it exists, per KTD2.
  3. Build with BuildKit and `--cache-from` the previous tag.
  4. Extract the installed-package manifest from the built image and compute the identity hash per KTD3. Compare against the previous build record's hash; exit 0 without pushing when equal.
  5. Push only when the hash differs.
- **Execution note:** Prove the two guards before the happy path. A build script that publishes correctly but silently overwrites a tag is worse than one that does not build yet.
- **Patterns to follow:** the registry login and `--cache-from` usage in the existing `Build` job in `.gitlab-ci.yml`.
- **Test scenarios:**
  - Covers AE3. Running against an image whose candidate tag already exists in the registry fails the job with a message naming the tag, and pushes nothing.
  - Covers AE1. Running twice with no upstream change publishes on the first run and exits 0 without a push on the second.
  - Covers AE2. Running after a pinned base package moves produces a different identity hash and pushes a new tag.
  - A malformed or missing `image.yml` fails with a message naming the file, not a shell trace.
  - A registry query that fails on network error fails the job rather than falling through to a push.
- **Verification:** Two consecutive local runs against an unchanged image produce exactly one pushed tag.

### U3. Scan and audit record generation

- **Goal:** Turn a completed build into a permanent record, an SBOM, and a regenerated index.
- **Requirements:** R11, R12, R13, R14, R17
- **Dependencies:** U2
- **Files:**
  - `scripts/ci/scan-image.sh` (create — Trivy invocation, JSON and CycloneDX output)
  - `scripts/ci/render-record.py` (create — JSON build record to markdown, plus index regeneration)
- **Approach:**
  1. Scan the built image with Trivy, emitting JSON findings and a CycloneDX SBOM.
  2. Assemble a JSON build record: `schema_version` (KTD6), tag, resolved base digest, identity hash, package manifest, scan summary and findings, originating commit SHA, and the previous tag it is diffed against.
  3. Render `images/<name>/builds/<tag>.md` from that JSON, including the package-level difference against the previous record.
  4. Regenerate `images/<name>/README.md` as an index listing tags newest-first.
  5. Never modify an existing record file. The renderer writes new files and rewrites only the index.
- **Test scenarios:**
  - Covers AE4. A scan reporting a HIGH finding still produces a record, the record names the finding, and the job exits 0 (KTD8).
  - Covers AE2. A record generated after a package version moves names the old and new versions in its difference section.
  - The first build of a brand-new image produces a record whose difference section states there is no previous tag, rather than erroring.
  - Regenerating the index twice with no new build leaves the index byte-identical.
  - A record file that already exists is never opened for writing.
  - Trivy JSON containing zero vulnerabilities produces a record stating that, not an empty section.
  - Every emitted JSON record carries `schema_version`, and the renderer refuses a record whose version it does not know.
- **Verification:** A completed build leaves exactly one new file under `builds/`, one SBOM, and an index whose newest entry is that tag.

### U4. Pipeline wiring

- **Goal:** Wire the scripts into `ci-cd`'s pipeline with per-image change rules, a schedule, parallel execution, and a non-looping commit-back.
- **Requirements:** R6, R9, R10, R15
- **Dependencies:** U3
- **Files:**
  - `tasks/image-factory/.image-factory.yml` (create — the `.build-image` hidden template and the per-image jobs)
  - `.gitlab-ci.yml` (modify — include the new task file, add the `build-images` stage, add the workflow guard)
- **Approach:**
  1. Define `.build-image` extending `.shared_runner_config` (KTD4) and running U2's and U3's scripts in sequence. Instance values (registry path, project ID) enter as CI variables with defaults, per KTD9.
  2. Add one job per catalog image, each setting `IMAGE_NAME` and carrying `rules: changes:` scoped to its own directory, per KTD1. Jobs share a stage so they run in parallel.
  3. Add a schedule rule that runs all three regardless of changes.
  4. Commit records back with the project access token and a `[skip ci]` subject, and add a `workflow:rules` clause that refuses pipelines for those commits, per KTD5.
  5. On merge requests, render records as job artifacts and skip both the push and the commit-back.
- **Test scenarios:**
  - Covers AE5. An MR touching only `images/sec-tools/` creates the `build-sec-tools` job and does not create `build-godot` or `build-tf-scan`.
  - Covers AE6. The record commit-back lands on the default branch and creates no pipeline.
  - A scheduled pipeline creates all three build jobs regardless of what changed.
  - An MR pipeline produces record artifacts, pushes no tag, and makes no commit.
  - The three build jobs run concurrently rather than in sequence.
  - Removing the access token variable fails the commit-back with a named error rather than silently skipping the record.
- **Verification:** `glab ci lint` passes, and a scheduled run produces three concurrent jobs.

### U5. The `godot` image

- **Goal:** Replace `aura-brawlers`'s per-job toolchain assembly with a pre-materialized layer.
- **Requirements:** R2
- **Dependencies:** U4
- **Files:**
  - `images/godot/Dockerfile` (create)
  - `images/godot/image.yml` (create)
- **Approach:**
  1. Pin a Debian base by digest; install the runtime libraries the export needs — `xvfb`, `mesa-vulkan-drivers`, `libvulkan1`, and the X and font libraries the current `.godot-setup` installs.
  2. Install the Godot editor binary at the pinned version.
  3. Unpack export templates for every target platform into the image at the path Godot expects, per KTD7. This is the layer that replaces the 980s download and the 1132s copy.
  4. Install `wine64` and `rcedit` for Windows resource embedding.
  5. Write the editor settings file that points Godot at `rcedit` and `wine`, so consumers do not have to.
- **Patterns to follow:** the tool list and template path in `.godot-setup` and the release jobs in `aura-brawlers/.gitlab-ci.yml`.
- **Test scenarios:**
  - `godot --version` inside the image reports the version pinned in `image.yml`.
  - The export-template directory exists at the path Godot expects and contains the Linux, Windows, and macOS templates.
  - `xvfb-run -a godot --headless --version` succeeds, proving the headless display path works.
  - `rcedit` and `wine64` are both resolvable on `PATH`.
  - Building with a changed `GODOT_VERSION` in `image.yml` produces an image reporting the new version, proving nothing is hardcoded in the Dockerfile.
- **Verification:** A Godot export runs in the image with no download, unpack, or `apt-get` step.

### U6. The `sec-tools` image

- **Goal:** Remove the per-run toolchain installation from the manual security scan jobs.
- **Requirements:** R3
- **Dependencies:** U4
- **Files:**
  - `images/sec-tools/Dockerfile` (create)
  - `images/sec-tools/image.yml` (create)
  - `tasks/manual-sec-scan/.manual-sec-scan.yml` (modify — drop the `setupdeb` anchor, point at the image)
- **Approach:**
  1. Bake Trivy, Bandit, Vulture, `npm-audit-plus`, and the Trivy JUnit template at pinned versions.
  2. Rewrite the four scan jobs to run on the factory image and delete the `.setupdeb` anchor, which currently installs Trivy and `docker-ce` from upstream apt repositories on every run.
  3. Keep the existing job names, artifact paths, and rules so consumers that already reference them do not break.
- **Test scenarios:**
  - `trivy --version`, `bandit --version`, `vulture --version`, and `npm-audit-plus --help` all succeed in the image.
  - The Trivy JUnit template is present at the path the scan jobs reference.
  - `trivy-scan-full`, `trivy-scan-severe`, `all-scan`, and `sec-scan` keep their existing names and artifact paths after the rewrite.
  - A scan job produces the same JUnit artifact shape it produced before the migration.
- **Verification:** No scan job contains an `apt-get`, `wget`, or `npm install` step.

### U7. The `tf-scan` image

- **Goal:** Pin the Terraform scanning toolchain, which currently floats on `:latest`.
- **Requirements:** R4
- **Dependencies:** U4
- **Files:**
  - `images/tf-scan/Dockerfile` (create)
  - `images/tf-scan/image.yml` (create)
  - `tasks/terraform-scanners/.terraform-scan.yml` (modify — replace the three `:latest` images with the factory tag)
- **Approach:**
  1. Bake terrascan, tfsec, and checkov at versions pinned in `image.yml`, replacing `tenable/terrascan:latest`, `aquasec/tfsec:latest`, and `bridgecrew/checkov:latest`.
  2. Collapse the three jobs onto one image while keeping them as three separate jobs, so their artifacts and rules stay unchanged.
  3. Drop the per-job `entrypoint` overrides, which exist only to work around the upstream images' entrypoints.
- **Test scenarios:**
  - `terrascan version`, `tfsec --version`, and `checkov --version` each report the version pinned in `image.yml`.
  - All three jobs produce their existing JUnit artifact paths after the rewrite.
  - No job definition references a `:latest` tag.
  - The shared `.specify_rules` reference still applies to all three jobs.
- **Verification:** `grep -r ':latest' tasks/` returns nothing.

### U8. Proof migration, measurement, and consumer docs

- **Goal:** Move `aura-brawlers` onto the `godot` image, measure the result, and correct the consumer documentation.
- **Requirements:** R16, R18
- **Dependencies:** U5
- **Files:**
  - `README.md` (modify — consumer instructions, correct `ref: master` to `ref: main`)
  - `aura-brawlers/.gitlab-ci.yml` (modify, separate repo — replace `.godot-setup` with the pinned factory image)
- **Approach:**
  1. Record the current `release-build-linux` baseline of 3243s and the job IDs it came from.
  2. In `aura-brawlers`, replace `image: ubuntu:22.04` plus the `.godot-setup` `before_script` with the pinned factory tag, and delete the Godot download, template download, template copy, and apt steps.
  3. Keep the `.godot` import cache, which is project content rather than toolchain.
  4. Re-run `release-build-linux` on the same runner class and record the new duration and section breakdown beside the baseline.
  5. Update `ci-cd`'s `README.md` with how to consume a factory image, and fix the stale `ref: master` instructions.
- **Execution note:** Land the `ci-cd` README change and the `aura-brawlers` migration as separate MRs in their own repos.
- **Test scenarios:**
  - Covers AE3. The migrated job pins an exact tag, not a floating one.
  - `release-build-linux` produces a Linux binary identical in shape to the pre-migration artifact, and the build-identifier and shader-baker assertions still pass.
  - The measured post-migration duration is recorded against the 3243s baseline, on the same runner class.
  - `godot-unit-tests` and `godot-gameplay-smoke` still pass on the factory image.
  - Following `README.md` alone, a consumer can add a factory image to a pipeline without reading this plan.
- **Verification:** `aura-brawlers`'s pipeline contains no toolchain download step, and the before/after numbers are written down.

---


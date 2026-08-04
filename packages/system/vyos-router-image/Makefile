NAME=vyos-router-image
NAMESPACE=cozy-system

# ── Pinned VyOS build inputs (reproducibility levers) ────────────────────────
# The build TOOLING is pinned by digest/commit; the upstream rolling apt mirror
# (packages.vyos.net/repositories/rolling) floats, so this is pinned-inputs /
# best-effort reproducible, not bit-identical. Bump these deliberately: the image
# and the site-router cloud-init contract advance atomically (see
# packages/apps/site-router/docs/image-lifecycle.md).
#
# VYOS_BUILD_IMAGE and VYOS_BUILD_REF are tracked by Renovate custom managers
# (.github/renovate.json) — nothing else can see a pin held in a Makefile
# variable, so without them these would age silently. VYOS_VERSION is a rolling
# snapshot label with no upstream release feed to watch and stays a manual bump.
#
# VYOS_BUILD_REF CANNOT be left to age. It selects the kernel the live-build asks
# for (data/defaults.toml `kernel_version`), and the rolling mirror carries only
# the current one — so a ref that has fallen behind fails with
# `E: Package 'linux-image-<old>-vyos' has no installation candidate` rather than
# building something stale. That is not a flake to retry: the pin has to move.
# Verify a bump before trusting it by comparing the ref's kernel_version against
# what the mirror actually serves:
#   gh api repos/vyos/vyos-build/contents/data/defaults.toml?ref=<ref> \
#     --jq .content | base64 -d | grep kernel_version
#   curl -fsSL https://packages.vyos.net/repositories/rolling/dists/rolling/main/binary-amd64/Packages.gz \
#     | gunzip | grep -oE '^Package: linux-image-[0-9.]+-vyos$' | sort -u
VYOS_BUILD_IMAGE = vyos/vyos-build:current@sha256:77b88166bb9dfb2fdef4f870064e579a1e33247a52c03a12c1703bf9b854a4c5
VYOS_BUILD_REF   = 6dea44971db1addc73682f3a82add133bcaee2de
VYOS_VERSION     = 1.5-rolling-20260802
VYOS_ARCH        = amd64

include ../../../hack/common-envs.mk

QCOW2 = ../../../_out/assets/vyos-router-$(VYOS_ARCH).qcow2

# Package the qcow2 as a KubeVirt containerDisk OCI image, push it, and stamp the
# digest .tag into the CONSUMING chart (packages/apps/site-router), whose boot
# DataVolume imports it via CDI's registry importer — mirroring how the talos
# build stamps bootbox/images/matchbox.tag. In CI the build-vyos job's `git diff`
# captures that stamped .tag as a patch fragment, which `finalize` reassembles
# into pr.patch so e2e resolves the freshly-built digest.
image: image-vyos-router-disk

image-vyos-router-disk: qcow2
	docker buildx build -f images/vyos-router-disk/Dockerfile ../../.. \
		$(call image-tags,vyos-router-disk,$(VYOS_VERSION)) \
		--metadata-file images/vyos-router-disk.json \
		$(BUILDX_ARGS)
	echo "$(REGISTRY)/vyos-router-disk:$(IMAGE_TAG)@$$(yq e '."containerimage.digest"' images/vyos-router-disk.json -o json -r)" \
		> ../../apps/site-router/images/vyos-router-disk.tag
	rm -f images/vyos-router-disk.json

# Heavy privileged live-build step; produces $(QCOW2). Kept idempotent so a rerun
# reuses an already-built disk.
qcow2:
	test -f $(QCOW2) || \
		VYOS_BUILD_IMAGE="$(VYOS_BUILD_IMAGE)" \
		VYOS_BUILD_REF="$(VYOS_BUILD_REF)" \
		VYOS_VERSION="$(VYOS_VERSION)" \
		VYOS_ARCH="$(VYOS_ARCH)" \
		hack/build-qcow2.sh

# No vendored upstream chart to pull, and the build-input pins above are
# refreshed by Renovate rather than by `make update`.
update: ;

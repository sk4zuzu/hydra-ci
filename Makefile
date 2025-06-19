SHELL := $(shell which bash)
SELF  := $(patsubst %/,%,$(dir $(abspath $(firstword $(MAKEFILE_LIST)))))

export

.PHONY: all

all:

.PHONY: init plan apply destroy

init plan:
	terraform $@

apply destroy: TF_LOG ?= INFO
apply destroy: init
	terraform $@ --auto-approve

.PHONY: touch check

touch:
	nix flake update --override-input entropy file+file://<(date --utc)

check:
	nix flake check --option sandbox false --print-build-logs

define ADD_TEST =
.PHONY: test-$(1)

test-$(1):
	nix build --option sandbox false --print-build-logs '.#checks.x86_64-linux.hydra-ci-$(1)' --rebuild || \
	nix build --option sandbox false --print-build-logs '.#checks.x86_64-linux.hydra-ci-$(1)'
endef

$(eval $(call ADD_TEST,test1))
$(eval $(call ADD_TEST,test2))

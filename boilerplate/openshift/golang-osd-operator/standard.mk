# Validate variables in project.mk exist
ifndef IMAGE_REGISTRY
$(error IMAGE_REGISTRY is not set; check project.mk file)
endif
ifndef IMAGE_REPOSITORY
$(error IMAGE_REPOSITORY is not set; check project.mk file)
endif
ifndef IMAGE_NAME
$(error IMAGE_NAME is not set; check project.mk file)
endif
ifndef VERSION_MAJOR
$(error VERSION_MAJOR is not set; check project.mk file)
endif
ifndef VERSION_MINOR
$(error VERSION_MINOR is not set; check project.mk file)
endif

# Accommodate docker or podman
CONTAINER_ENGINE=$(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)

# Generate version and tag information from inputs
COMMIT_NUMBER=$(shell git rev-list `git rev-list --parents HEAD | egrep "^[a-f0-9]{40}$$"`..HEAD --count)
CURRENT_COMMIT=$(shell git rev-parse --short=7 HEAD)
OPERATOR_VERSION=$(VERSION_MAJOR).$(VERSION_MINOR).$(COMMIT_NUMBER)-$(CURRENT_COMMIT)

IMG?=$(IMAGE_REGISTRY)/$(IMAGE_REPOSITORY)/$(IMAGE_NAME):v$(OPERATOR_VERSION)
OPERATOR_IMAGE_URI=${IMG}
OPERATOR_IMAGE_URI_LATEST=$(IMAGE_REGISTRY)/$(IMAGE_REPOSITORY)/$(IMAGE_NAME):latest
OPERATOR_DOCKERFILE ?=build/Dockerfile

BINFILE=build/_output/bin/$(OPERATOR_NAME)
MAINPACKAGE=./cmd/manager

# Containers may default GOFLAGS=-mod=vendor which would break us since
# we're using modules.
unexport GOFLAGS
GOOS?=linux
GOARCH?=amd64
GOENV=GOOS=${GOOS} GOARCH=${GOARCH} CGO_ENABLED=0 GOFLAGS=

GOBUILDFLAGS=-gcflags="all=-trimpath=${GOPATH}" -asmflags="all=-trimpath=${GOPATH}"

# GOLANGCI_LINT_CACHE needs to be set to a directory which is writeable
# Relevant issue - https://github.com/golangci/golangci-lint/issues/734
GOLANGCI_LINT_CACHE ?= /tmp/golangci-cache

TESTTARGETS := $(shell ${GOENV} go list -e ./... | egrep -v "/(vendor)/")
# ex, -v
TESTOPTS :=

ALLOW_DIRTY_CHECKOUT?=false

# TODO: Figure out how to discover this dynamically
CONVENTION_DIR := boilerplate/openshift/golang-osd-operator

# Set the default goal in a way that works for older & newer versions of `make`:
# Older versions (<=3.8.0) will pay attention to the `default` target.
# Newer versions pay attention to .DEFAULT_GOAL, where uunsetting it makes the next defined target the default:
# https://www.gnu.org/software/make/manual/make.html#index-_002eDEFAULT_005fGOAL-_0028define-default-goal_0029
.DEFAULT_GOAL :=
.PHONY: default
default: go-build

.PHONY: clean
clean:
	rm -rf ./build/_output

.PHONY: isclean
isclean:
	@(test "$(ALLOW_DIRTY_CHECKOUT)" != "false" || test 0 -eq $$(git status --porcelain | wc -l)) || (echo "Local git checkout is not clean, commit changes and try again." >&2 && exit 1)

.PHONY: docker-build
docker-build: isclean
	${CONTAINER_ENGINE} build . -f $(OPERATOR_DOCKERFILE) -t $(OPERATOR_IMAGE_URI)
	${CONTAINER_ENGINE} tag $(OPERATOR_IMAGE_URI) $(OPERATOR_IMAGE_URI_LATEST)

.PHONY: docker-push
docker-push:
	${CONTAINER_ENGINE} push $(OPERATOR_IMAGE_URI)
	${CONTAINER_ENGINE} push $(OPERATOR_IMAGE_URI_LATEST)

.PHONY: push
push: docker-push

.PHONY: go-check
go-check: ## Golang linting and other static analysis
	${CONVENTION_DIR}/ensure.sh golangci-lint
	GOLANGCI_LINT_CACHE=${GOLANGCI_LINT_CACHE} golangci-lint run -c ${CONVENTION_DIR}/golangci.yml ./...

.PHONY: go-generate
go-generate:
	${GOENV} go generate $(TESTTARGETS)
	# Don't forget to commit generated files

.PHONY: op-generate
op-generate:
	${CONVENTION_DIR}/operator-sdk-generate.sh
	# Don't forget to commit generated files

.PHONY: generate
generate: op-generate go-generate

.PHONY: go-build
go-build: go-check go-test ## Build binary
	${GOENV} go build ${GOBUILDFLAGS} -o ${BINFILE} ${MAINPACKAGE}

.PHONY: go-test
go-test:
	${GOENV} go test $(TESTOPTS) $(TESTTARGETS)

.PHONY: python-venv
python-venv:
	${CONVENTION_DIR}/ensure.sh venv ${CONVENTION_DIR}/py-requirements.txt
	$(eval PYTHON := .venv/bin/python3)

.PHONY: generate-check
generate-check: 
	@$(MAKE) -s isclean --no-print-directory 
	@$(MAKE) -s generate --no-print-directory
	@$(MAKE) -s isclean --no-print-directory || (echo 'Files after generation are different than committed ones. Please commit updated and unaltered generated files' >&2 && exit 1)
	@echo "All generated files are up-to-date and unaltered" 

.PHONY: yaml-validate
yaml-validate: python-venv
	${PYTHON} ${CONVENTION_DIR}/validate-yaml.py $(shell git ls-files | egrep -v '^(vendor|boilerplate)/' | egrep '.*\.ya?ml')

.PHONY: olm-deploy-yaml-validate
olm-deploy-yaml-validate: python-venv
	${PYTHON} ${CONVENTION_DIR}/validate-yaml.py $(shell git ls-files 'deploy/*.yaml' 'deploy/*.yml')

######################
# Targets used by prow
######################

# validate: Ensure code generation has not been forgotten; and ensure
# generated and boilerplate code has not been modified.
.PHONY: validate
validate: boilerplate-freeze-check generate-check

# lint: Perform static analysis.
.PHONY: lint
lint: olm-deploy-yaml-validate go-check

# test: "Local" unit and functional testing.
.PHONY: test
test: go-test

# coverage: Code coverage analysis and reporting.
.PHONY: coverage
coverage:
	${CONVENTION_DIR}/codecov.sh

# build: Code compilation and bundle generation. This should do as much
# of what app-sre does as possible, so that there are no surprises after
# a PR is merged.
# TODO: Include generating (but not pushing) the bundle
.PHONY: build
build: docker-build

#########################
# Targets used by app-sre
#########################

# build-push: Construct, tag, and push the official operator and
# registry container images.
# TODO: Boilerplate this script.
.PHONY: build-push
build-push:
	hack/app_sre_build_deploy.sh

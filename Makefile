SHELL = /usr/bin/env bash -e
AUTHOR_EMAIL=wayfinder@appvia.io
BUILD_TIME := $(shell date '+%s')
CURRENT_TAG=$(shell git tag --points-at HEAD)

# Cloud access is per-cloud only; set CLOUDACCESS_AWS, CLOUDACCESS_AZURERM, or CLOUDACCESS_GOOGLE

# Resolve cloud access per cloud provider, detected from KIND name prefix
# Supported variables you can set: CLOUDACCESS_AWS, CLOUDACCESS_AZURERM, CLOUDACCESS_GOOGLE
# Resolution order: CLOUDACCESS_<CLOUD> (from KIND prefix)
CLOUD_PREFIX = $(word 1,$(subst -, ,$(KIND)))
CLOUD_VAR_NAME = CLOUDACCESS_$(shell echo $(CLOUD_PREFIX) | tr '[:lower:]' '[:upper:]')
RESOLVED_CLOUDACCESS = $($(CLOUD_VAR_NAME))

# Check that KIND parameter is provided and valid
check-kind:
ifndef KIND
	@echo "Error: KIND parameter is required"
	@echo "Usage: make <target> KIND=<kind-name>"
	@$(MAKE) list-kinds
	@exit 1
endif
	@if [ ! -f "kinds/$(KIND).yaml" ]; then \
		echo "Error: kinds/$(KIND).yaml not found"; \
		$(MAKE) list-kinds; \
		exit 1; \
	fi

# Apply a CloudResourceKind by name
# Usage: make apply KIND=aws-kms-key
apply: check-kind
	@echo "Applying CloudResourceKind: $(KIND)"
	wf apply -f kinds/$(KIND).yaml

# Apply a CloudResourcePlan by kind name
# Usage: make apply-plan KIND=aws-kms-key
apply-plan: check-kind
	@if [ -f "kind-validation/$(KIND)/$(KIND)-cr-plan.yaml" ]; then \
		echo "Applying CloudResourcePlan for kind: $(KIND)"; \
		wf apply -f kind-validation/$(KIND)/$(KIND)-cr-plan.yaml; \
	else \
		echo "No plan found for kind: $(KIND) (kind-validation/$(KIND)/$(KIND)-cr-plan.yaml does not exist)"; \
		echo "This is OK - not all kinds have plans."; \
	fi

# Deploy command template (shared between deploy and deploy-remove)
DEPLOY_CMD = wf deploy -f $(KIND)-wayfinder-create.yaml -i $(KIND)-kindtest --target cloud=$(RESOLVED_CLOUDACCESS) --out-file "out.json"

# Deploy a cloud resource using wayfinder-create template
# Usage: make deploy KIND=aws-kms-key CLOUDACCESS=my-cloud-access REMOVE=false
deploy:
	@if [[ ! -f "kind-validation/$(KIND)/$(KIND)-cr-plan.yaml" && ! -f "kind-validation/$(KIND)/$(KIND)-wayfinder-create.yaml" ]]; then \
		echo "No plan found for kind: $(KIND) - skipping deploy (this is OK)"; \
		echo "Skipping deployment / removal."; \
		exit 0; \
	elif [ ! -f "kind-validation/$(KIND)/$(KIND)-wayfinder-create.yaml" ]; then \
		echo "Error: Plan exists but wayfinder-create template not found: kind-validation/$(KIND)/$(KIND)-wayfinder-create.yaml"; \
		exit 1; \
	else \
		if [ -z "$(RESOLVED_CLOUDACCESS)" ]; then \
			echo "Error: Cloud access not set. Provide CLOUDACCESS_$(shell echo $(CLOUD_PREFIX) | tr '[:lower:]' '[:upper:]') for kind $(KIND)."; \
			exit 1; \
		fi; \
		if [ "$(REMOVE)" = "true" ]; then \
			echo "Removing cloud resource for kind: $(KIND) using cloud access: $(RESOLVED_CLOUDACCESS)"; \
			( cd kind-validation/$(KIND) && if [ -f "create.env" ]; then set -a; source create.env; fi; $(DEPLOY_CMD) --remove ); \
		else \
			echo "Deploying cloud resource for kind: $(KIND) using cloud access: $(RESOLVED_CLOUDACCESS)"; \
			( cd kind-validation/$(KIND) && if [ -f "create.env" ]; then set -a; source create.env; fi; $(DEPLOY_CMD) ); \
		fi; \
	fi

# Remove a deployed cloud resource
# Usage: make deploy-remove KIND=aws-kms-key CLOUDACCESS=my-cloud-access
deploy-remove:
	@echo "Removing cloud resource for kind: $(KIND) using cloud access: $(RESOLVED_CLOUDACCESS)"; \
	$(MAKE) deploy KIND=$(KIND) REMOVE=true

# Search for cloud resources using search.env configuration
# Usage: make search KIND=aws-kms-key CLOUDACCESS_AWS=my-cloud-access
search: check-kind
ifeq ($(strip $(RESOLVED_CLOUDACCESS)),)
	@echo "Error: Cloud access not set. Provide CLOUDACCESS_$(shell echo $(CLOUD_PREFIX) | tr '[:lower:]' '[:upper:]') for kind $(KIND)."
	@echo "Usage: set per-cloud variable: CLOUDACCESS_AWS | CLOUDACCESS_AZURERM | CLOUDACCESS_GOOGLE"
	@exit 1
endif
	@if [ ! -f "kind-validation/$(KIND)/search.env" ]; then \
		echo "Error: Search configuration not found: kind-validation/$(KIND)/search.env"; \
		exit 1; \
	fi
	@echo "Searching for cloud resources of kind: $(KIND) using cloud access: $(RESOLVED_CLOUDACCESS)"
	@cd kind-validation/$(KIND) && \
		source search.env && \
		wf search cloudresource --kind $(KIND) --target $(RESOLVED_CLOUDACCESS) --filter "$$FILTER" --save --delete-after-save

# Resolve dependency order - simple topological sort
# Usage: make resolve-order KINDS="aws-vpc aws-subnet aws-security-group"
resolve-order:
ifndef KINDS
	@echo "Error: KINDS parameter is required"
	@echo "Usage: make resolve-order KINDS=\"kind1 kind2 kind3\""
	@exit 1
endif
	@echo "$(KINDS)" | tr ' ' '\n' | while read kind; do \
		if [ -f "kind-validation/$$kind/search.env" ] && grep -q "REQUIRES_KIND_CREATE" "kind-validation/$$kind/search.env" 2>/dev/null; then \
			dep=$$(grep "REQUIRES_KIND_CREATE" "kind-validation/$$kind/search.env" | sed 's/.*REQUIRES_KIND_CREATE=//'); \
			echo "DEP:$$dep:$$kind"; \
		else \
			echo "NODEP:$$kind"; \
		fi; \
	done | awk -F: -v input_kinds="$(KINDS)" 'BEGIN { \
		split(input_kinds, kinds_array, " "); \
		for(i in kinds_array) input_set[kinds_array[i]] = 1; \
	} { \
		if($$1 == "DEP") { \
			deps[$$3] = $$2; \
			all_kinds[$$3] = 1; \
			if($$2 in input_set) dep_targets[$$2] = 1; \
		} else { \
			all_kinds[$$2] = 1; \
		} \
	} END { \
		result = ""; \
		for(kind in kinds_array) { \
			if(kinds_array[kind] in dep_targets) result = result kinds_array[kind] " "; \
		} \
		for(kind in kinds_array) { \
			if(!(kinds_array[kind] in dep_targets)) result = result kinds_array[kind] " "; \
		} \
		gsub(/ +/, " ", result); \
		gsub(/^ +| +$$/, "", result); \
		print result; \
	}'

# Debug target to print dependency order for given KINDS
# Usage: make debug-order KINDS="aws-vpc aws-subnet aws-security-group"
debug-order:
ifndef KINDS
	@echo "Error: KINDS parameter is required"
	@echo "Usage: make debug-order KINDS=\"kind1 kind2 kind3\""
	@exit 1
endif
	@echo "=== Dependency Order Debug ==="
	@echo "Input kinds: $(KINDS)"
	@echo ""
	@echo "Analyzing dependencies..."
	@echo "$(KINDS)" | tr ' ' '\n' | while read kind; do \
		if [ -f "kind-validation/$$kind/search.env" ]; then \
			if grep -q "REQUIRES_KIND_CREATE" "kind-validation/$$kind/search.env" 2>/dev/null; then \
				dep=$$(grep "REQUIRES_KIND_CREATE" "kind-validation/$$kind/search.env" | sed 's/.*REQUIRES_KIND_CREATE=//'); \
				echo "  $$kind depends on: $$dep"; \
			else \
				echo "  $$kind has no dependencies"; \
			fi; \
		else \
			echo "  $$kind: no search.env found (no dependencies)"; \
		fi; \
	done
	@echo ""
	@echo "Resolved order:"
	@ordered_kinds=$$($(MAKE) resolve-order KINDS="$(KINDS)"); \
	echo "  $$ordered_kinds"

# Sort kinds by dependency order (dependencies first) - DEPRECATED, use debug-order instead
sort-kinds:
	@echo "DEPRECATED: Use 'make debug-order KINDS=\"kind1 kind2\"' instead"
	@echo "$(KINDS)" | tr ' ' '\n' | while read kind; do \
		if [ -f "kind-validation/$$kind/search.env" ] && grep -q "REQUIRES_KIND_CREATE" "kind-validation/$$kind/search.env"; then \
			dep=$$(grep "REQUIRES_KIND_CREATE" "kind-validation/$$kind/search.env" | cut -d'"' -f2); \
			echo "$$dep $$kind"; \
		else \
			echo "$$kind"; \
		fi; \
	done | sort | awk '{if(NF==2) print $$1; else print $$1}' | sort -u | while read kind; do \
		if echo "$(KINDS)" | tr ' ' '\n' | grep -q "^$$kind$$"; then echo $$kind; fi; \
	done | while read kind; do \
		echo "$(KINDS)" | tr ' ' '\n' | grep -v "^$$kind$$"; \
		echo $$kind; \
	done | awk '!seen[$$0]++'

# Run complete workflow for a kind: apply -> apply-plan -> deploy -> search
# Usage: make workflow KIND=aws-kms-key
workflow: check-kind
ifeq ($(strip $(RESOLVED_CLOUDACCESS)),)
	@echo "Error: Cloud access not set. Provide CLOUDACCESS_$(shell echo $(CLOUD_PREFIX) | tr '[:lower:]' '[:upper:]') for kind $(KIND)."
	@echo "Usage: set per-cloud variable: CLOUDACCESS_AWS | CLOUDACCESS_AZURERM | CLOUDACCESS_GOOGLE"
	@exit 1
endif
	@echo "=== Running complete workflow for kind: $(KIND) ==="
	@echo "Step 1/4: Applying CloudResourceKind..."
	@$(MAKE) apply KIND=$(KIND)
	@echo ""
	@echo "Step 2/4: Applying CloudResourcePlan..."
	@$(MAKE) apply-plan KIND=$(KIND)
	@echo ""
	@echo "Step 3/4: Deploying cloud resource..."
	@$(MAKE) deploy KIND=$(KIND)
	@echo ""
	@echo "Step 4/4: Searching for cloud resources..."
	@$(MAKE) search KIND=$(KIND)
	@echo ""
	@echo "=== Workflow complete for kind: $(KIND) ==="

# Run workflow for multiple kinds with dependency ordering and guaranteed cleanup
# Usage: make workflow-multi KINDS="aws-vpc aws-subnet aws-kms-key"
workflow-multi:
ifndef KINDS
	@echo "Error: KINDS parameter is required"
	@echo "Usage: make workflow-multi KINDS=\"kind1 kind2 kind3\""
	@echo "Per-cloud access is auto-detected from each KIND."
	@exit 1
endif
	@echo "=== Running multi-kind workflow with dependency ordering ==="
	@echo "Original kinds: $(KINDS)"
	@ordered_kinds=$$($(MAKE) resolve-order KINDS="$(KINDS)"); \
	echo "Dependency-ordered kinds: $$ordered_kinds"; \
	echo ""; \
	failed=0; \
	for kind in $$ordered_kinds; do \
		echo "=== Processing kind: $$kind ==="; \
		$(MAKE) workflow KIND=$$kind || failed=1; \
		echo ""; \
	done; \
	echo "=== Running cleanup (deploy-remove) for all kinds ==="; \
	echo "Cleanup order (reverse): $$(echo $$ordered_kinds | tr ' ' '\n' | tac | tr '\n' ' ')"; \
	for kind in $$(echo $$ordered_kinds | tr ' ' '\n' | tac); do \
		echo "Cleaning up kind: $$kind"; \
		$(MAKE) deploy-remove KIND=$$kind || echo "Cleanup failed for $$kind (continuing...)"; \
		echo ""; \
	done; \
	echo "=== Multi-kind workflow complete ==="; \
	if [ $$failed -eq 1 ]; then \
		echo "WARNING: Some workflows failed, but cleanup was attempted for all kinds."; \
		exit 1; \
	fi

# List all available kinds
list-kinds:
	@echo "Available CloudResourceKinds:"
	@ls kinds/*.yaml | sed 's|kinds/||g' | sed 's|\.yaml||g' | sed 's|^|  - |g'

# List all available plans
list-plans:
	@echo "Available CloudResourcePlans:"
	@find kind-validation -name "*-cr-plan.yaml" | sed 's|kind-validation/||g' | sed 's|/.*||g' | sed 's|^|  - |g' | sort | uniq

.PHONY: apply apply-plan deploy deploy-remove search workflow workflow-multi sort-kinds list-kinds list-plans resolve-order debug-order


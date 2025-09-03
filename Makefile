SHELL = /usr/bin/env bash -e
AUTHOR_EMAIL=wayfinder@appvia.io
BUILD_TIME := $(shell date '+%s')
CURRENT_TAG=$(shell git tag --points-at HEAD)

# Cloud access is per-cloud only; set CLOUDACCESS_AWS, CLOUDACCESS_AZURERM, or CLOUDACCESS_GOOGLE

# Resolve cloud access per cloud provider, detected from DATASOURCE name prefix
# Supported variables you can set: CLOUDACCESS_AWS, CLOUDACCESS_AZURERM, CLOUDACCESS_GOOGLE
# Resolution order: CLOUDACCESS_<CLOUD> (from DATASOURCE prefix)
CLOUD_PREFIX = $(word 1,$(subst -, ,$(DATASOURCE)))
CLOUD_VAR_NAME = CLOUDACCESS_$(shell echo $(CLOUD_PREFIX) | tr '[:lower:]' '[:upper:]')
RESOLVED_CLOUDACCESS = $($(CLOUD_VAR_NAME))

# Check that DATASOURCE parameter is provided and valid
check-datasource:
ifndef DATASOURCE
	@echo "Error: DATASOURCE parameter is required"
	@echo "Usage: make <target> DATASOURCE=<datasource-name>"
	@$(MAKE) list-datasources
	@exit 1
endif
	@if [ ! -f "datasources/$(DATASOURCE).yaml" ]; then \
		echo "Error: datasources/$(DATASOURCE).yaml not found"; \
		$(MAKE) list-datasources; \
		exit 1; \
	fi

# Apply a CloudResourceDataSource by name
# Usage: make apply DATASOURCE=aws-kms-key
apply: check-datasource
	@echo "Applying CloudResourceDataSource: $(DATASOURCE)"
	wf apply -f datasources/$(DATASOURCE).yaml

# Apply a CloudResourcePlan by datasource name
# Usage: make apply-plan DATASOURCE=aws-kms-key
apply-plan: check-datasource
	@if [ -f "tests/$(DATASOURCE)/$(DATASOURCE)-cr-plan.yaml" ]; then \
		echo "Applying CloudResourcePlan for datasource: $(DATASOURCE)"; \
		wf apply -f tests/$(DATASOURCE)/$(DATASOURCE)-cr-plan.yaml; \
	else \
		echo "No plan found for datasource: $(DATASOURCE) (tests/$(DATASOURCE)/$(DATASOURCE)-cr-plan.yaml does not exist)"; \
		echo "This is OK - not all datasources have plans."; \
	fi

# Deploy command template (shared between deploy and deploy-remove)
DEPLOY_CMD = wf deploy -f $(DATASOURCE)-wayfinder-create.yaml -i $(DATASOURCE)-kindtest --target cloud=$(RESOLVED_CLOUDACCESS) --out-file "out.json"

# Deploy a cloud resource using wayfinder-create template
# Usage: make deploy DATASOURCE=aws-kms-key CLOUDACCESS=my-cloud-access REMOVE=false
deploy:
	@if [[ ! -f "tests/$(DATASOURCE)/$(DATASOURCE)-cr-plan.yaml" && ! -f "tests/$(DATASOURCE)/$(DATASOURCE)-wayfinder-create.yaml" ]]; then \
		echo "No plan found for datasource: $(DATASOURCE) - skipping deploy (this is OK)"; \
		echo "Skipping deployment / removal."; \
		exit 0; \
	elif [ ! -f "tests/$(DATASOURCE)/$(DATASOURCE)-wayfinder-create.yaml" ]; then \
		echo "Error: Plan exists but wayfinder-create template not found: tests/$(DATASOURCE)/$(DATASOURCE)-wayfinder-create.yaml"; \
		exit 1; \
	else \
		if [ -z "$(RESOLVED_CLOUDACCESS)" ]; then \
			echo "Error: Cloud access not set. Provide CLOUDACCESS_$(shell echo $(CLOUD_PREFIX) | tr '[:lower:]' '[:upper:]') for datasource $(DATASOURCE)."; \
			exit 1; \
		fi; \
		if [ "$(REMOVE)" = "true" ]; then \
			echo "Removing cloud resource for datasource: $(DATASOURCE) using cloud access: $(RESOLVED_CLOUDACCESS)"; \
			( cd tests/$(DATASOURCE) && if [ -f "create.env" ]; then set -a; source create.env; fi; $(DEPLOY_CMD) --remove ); \
		else \
			echo "Deploying cloud resource for datasource: $(DATASOURCE) using cloud access: $(RESOLVED_CLOUDACCESS)"; \
			( cd tests/$(DATASOURCE) && if [ -f "create.env" ]; then set -a; source create.env; fi; $(DEPLOY_CMD) ); \
		fi; \
	fi

# Remove a deployed cloud resource
# Usage: make deploy-remove DATASOURCE=aws-kms-key CLOUDACCESS=my-cloud-access
deploy-remove:
	@echo "Removing cloud resource for datasource: $(DATASOURCE) using cloud access: $(RESOLVED_CLOUDACCESS)"; \
	$(MAKE) deploy DATASOURCE=$(DATASOURCE) REMOVE=true

# Search for cloud resources using search.env configuration
# Usage: make search DATASOURCE=aws-kms-key CLOUDACCESS_AWS=my-cloud-access
search: check-datasource
ifeq ($(strip $(RESOLVED_CLOUDACCESS)),)
	@echo "Error: Cloud access not set. Provide CLOUDACCESS_$(shell echo $(CLOUD_PREFIX) | tr '[:lower:]' '[:upper:]') for datasource $(DATASOURCE)."
	@echo "Usage: set per-cloud variable: CLOUDACCESS_AWS | CLOUDACCESS_AZURERM | CLOUDACCESS_GOOGLE"
	@exit 1
endif
	@if [ ! -f "tests/$(DATASOURCE)/search.env" ]; then \
		echo "Error: Search configuration not found: tests/$(DATASOURCE)/search.env"; \
		exit 1; \
	fi
	@echo "Searching for cloud resources of datasource: $(DATASOURCE) using cloud access: $(RESOLVED_CLOUDACCESS)"
	@cd tests/$(DATASOURCE) && \
		source search.env && \
		wf search cloudresource --data-source $(DATASOURCE) --cloud-access $(RESOLVED_CLOUDACCESS) --filter "$$FILTER" --save --delete-after-save

# Resolve dependency order - simple topological sort
# Usage: make resolve-order DATASOURCES="aws-vpc aws-subnet aws-security-group"
resolve-order:
ifndef DATASOURCES
	@echo "Error: DATASOURCES parameter is required"
	@echo "Usage: make resolve-order DATASOURCES=\"ds1 ds2 ds3\""
	@exit 1
endif
	@echo "$(DATASOURCES)" | tr ' ' '\n' | while read kind; do \
		if [ -f "tests/$$kind/search.env" ] && grep -q "REQUIRES_DATASOURCE_CREATE" "tests/$$kind/search.env" 2>/dev/null; then \
			dep=$$(grep "REQUIRES_DATASOURCE_CREATE" "tests/$$kind/search.env" | sed 's/.*REQUIRES_DATASOURCE_CREATE=//'); \
			echo "DEP:$$dep:$$kind"; \
		else \
			echo "NODEP:$$kind"; \
		fi; \
	done | awk -F: -v input_kinds="$(DATASOURCES)" 'BEGIN { \
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

# Debug target to print dependency order for given DATASOURCE list
# Usage: make list-order DATASOURCES="aws-vpc aws-subnet aws-security-group"
list-order:
ifndef DATASOURCES
	@echo "Error: DATASOURCES parameter is required"
	@echo "Usage: make list-order DATASOURCES=\"ds1 ds2 ds3\""
	@exit 1
endif
	@echo "=== Dependency Order Debug ==="
	@echo "Input datasources: $(DATASOURCES)"
	@echo ""
	@echo "Analyzing dependencies..."
	@echo "$(DATASOURCES)" | tr ' ' '\n' | while read kind; do \
		if [ -f "tests/$$kind/search.env" ]; then \
			if grep -q "REQUIRES_DATASOURCE_CREATE" "tests/$$kind/search.env" 2>/dev/null; then \
				dep=$$(grep "REQUIRES_DATASOURCE_CREATE" "tests/$$kind/search.env" | sed 's/.*REQUIRES_DATASOURCE_CREATE=//'); \
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
	@ordered_kinds=$$($(MAKE) resolve-order DATASOURCES="$(DATASOURCES)"); \
	echo "  $$ordered_kinds"


# Run complete workflow for a datasource: apply -> apply-plan -> deploy -> search
# Usage: make workflow DATASOURCE=aws-kms-key
workflow: check-datasource
ifeq ($(strip $(RESOLVED_CLOUDACCESS)),)
	@echo "Error: Cloud access not set. Provide CLOUDACCESS_$(shell echo $(CLOUD_PREFIX) | tr '[:lower:]' '[:upper:]') for datasource $(DATASOURCE)."
	@echo "Usage: set per-cloud variable: CLOUDACCESS_AWS | CLOUDACCESS_AZURERM | CLOUDACCESS_GOOGLE"
	@exit 1
endif
	@echo "=== Running complete workflow for datasource: $(DATASOURCE) ==="
	@echo "Step 1/4: Applying CloudResourceDataSource..."
	@$(MAKE) apply DATASOURCE=$(DATASOURCE)
	@echo ""
	@echo "Step 2/4: Applying CloudResourcePlan..."
	@$(MAKE) apply-plan DATASOURCE=$(DATASOURCE)
	@echo ""
	@echo "Step 3/4: Deploying cloud resource..."
	@$(MAKE) deploy DATASOURCE=$(DATASOURCE)
	@echo ""
	@echo "Step 4/4: Searching for cloud resources..."
	@$(MAKE) search DATASOURCE=$(DATASOURCE)
	@echo ""
	@echo "=== Workflow complete for datasource: $(DATASOURCE) ==="

# Run workflow for multiple datasources with dependency ordering and guaranteed cleanup
# Usage: make workflow-multi DATASOURCES="aws-vpc aws-subnet aws-kms-key"
workflow-multi:
ifndef DATASOURCES
	@echo "Error: DATASOURCES parameter is required"
	@echo "Usage: make workflow-multi DATASOURCES=\"ds1 ds2 ds3\""
	@echo "Per-cloud access is auto-detected from each DATASOURCE."
	@exit 1
endif
	@echo "=== Running multi-kind workflow with dependency ordering ==="
	@echo "Original datasources: $(DATASOURCES)"
	@ordered_kinds=$$($(MAKE) resolve-order DATASOURCES="$(DATASOURCES)"); \
	echo "Dependency-ordered kinds: $$ordered_kinds"; \
	echo ""; \
	failed=0; \
	for kind in $$ordered_kinds; do \
		echo "=== Processing datasource: $$kind ==="; \
		$(MAKE) workflow DATASOURCE=$$kind || failed=1; \
		echo ""; \
	done; \
	echo "=== Running cleanup (deploy-remove) for all datasources ==="; \
	echo "Cleanup order (reverse): $$(echo $$ordered_kinds | tr ' ' '\n' | tac | tr '\n' ' ')"; \
	for kind in $$(echo $$ordered_kinds | tr ' ' '\n' | tac); do \
		echo "Cleaning up datasource: $$kind"; \
		$(MAKE) deploy-remove DATASOURCE=$$kind || echo "Cleanup failed for $$kind (continuing...)"; \
		echo ""; \
	done; \
	echo "=== Multi-kind workflow complete ==="; \
	if [ $$failed -eq 1 ]; then \
		echo "WARNING: Some workflows failed, but cleanup was attempted for all kinds."; \
		exit 1; \
	fi

# List all available datasources
list-datasources:
	@echo "Available CloudResourceDataSources:"
	@ls datasources/*.yaml | sed 's|datasources/||g' | sed 's|\.yaml||g' | sed 's|^|  - |g'

# List all available plans
list-plans:
	@echo "Available CloudResourcePlans:"
	@find tests -name "*-cr-plan.yaml" | sed 's|tests/||g' | sed 's|/.*||g' | sed 's|^|  - |g' | sort | uniq

.PHONY: apply apply-plan deploy deploy-remove search workflow workflow-multi list-datasources list-plans resolve-order list-order


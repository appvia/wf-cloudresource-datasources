# Wayfinder CloudResourceKinds

This repo contains the kinds of CloudResource dependency that wayfinder supports.

## Overview

CloudResourceKinds provide a way for Wayfinder to discover resource dependencies for developers.

The resources are typically provided by an organization's cloud estate and will be discovered using tags.

Each resource kind can be referenced as a dependency of another cloud resource being built and discovered at run time.

CloudResourceKinds define terraform with configuration that is used for read only discovery not creating resources.

## Highlevel Orchestration Workflow

1. A CloudResourceSearch is created by the system during a deployment when developer needs to know about dependencies. The tag values could have developer relevant metadata.
2. A CloudResourceKind is used by the CloudResourceSearch controller and the cloud resource search is run.
3. Identifiers are shown to a developer to resolve ambigouse search results.
4. A concrete single cloud resource object is created using a CloudResourceKind reference using the singular terraform to resolve the detailed outputs.

## Terraform in CloudResourceKind - Limitations and Rules

The CloudResourceKind terraform is orchetsrated and run in a constrained, pre-configured runtime environment for both searches and resource audit:
- Only defines data sources and outputs (read only).
- Has a pre-configured default provider configuration for each cloud.
- Will have only ready only access to cloud and is used for auditing cloud resources only.
- Can only use additional providers using the API and the spec.terraform.additionalProviders array field.

### Searches
- Uses the variable `var.resource_tags` to provide the search input with developer instance relevant data.
- Uses the output `output` to store an array of maps with identifier values.
### Resource
- Uses golang templating to create a set of terraform variables named using a single array item from the `output` array of map identifiers from above
- Provides the outputs as defined to other dependent resources.

## Validating new resources



## New Kind Validation

### Test Files

BEFORE we can test finding resources using a CloudResourceSearch and CloudResourceKind we need to have the resources to find!

Files to create an instance of a resource (NOT discover).
1. Create a CloudResourcePlan .yaml file in `kind-validation/[kind]]/[kind]-cr-plan.yaml` that will define how to create an instance of the kind.
        
    This must be to a valid terraform module to create (not find the resource). This will have valid tags so that we can find the resource later.

    It is imperative that the plan will work with the terraform module referenced and all required variables are templated suitably.
    
2. Create a StackDefinitionData file in `kind-validation/[kind]]/[kind]-wayfinder-create.yaml` this will create the instance of the plan.

    wf deploy is used with this file to create the test resource against a valid real cloud target.

3. Create a search.env file in `kind-validation/[kind]]/search.env` to set the test parameters.
    Use `FILTER` to define how to carry out the search (given resources created):
    ```
    FILTER="vpc_id=$(cat ../aws-vpc/out.json | jq -r '.componentOutputs.vpc.vpc_id.value')"
    ```

    Optionally use the `REQUIRES_KIND_CREATE` to specify a dependency of the test:
    ```
    REQUIRES_KIND_CREATE="aws-vpc"
    ```

# Reference Docs

This directory is for reference material, not canonical workflow truth.

## What belongs here

- copied standards and specifications
- external command references and operational notes
- exploratory architecture discussions
- adjacent research that informed implementation decisions
- one-off tooling notes

Examples:

- `standards/` -- copied or summarized external standards such as GeoPackage and
  GeoParquet guidance
- `commands/` -- command reference notes and operational snippets
- `perplexity/` -- exploratory discussions and research exports

## What does not belong here

Do not use `docs/reference/` as the primary home for:

- the current established parcel workflow
- source-specific canonical documentation
- current metadata or artifact contracts
- current repo information architecture

Those belong in:

- `docs/sources/`
- `docs/workflows/`
- `docs/specs/`

## Current Canonical Docs

For the current state of the project, use:

- [Parcel source documentation](../sources/parcels.md)
- [Current parcels pipeline spec](../workflows/parcels-pipeline.md)
- [FGB metadata and artifact contracts](../specs/fgb-metadata.md)

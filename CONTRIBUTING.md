# Contributing to Notional

:+1: Thanks for taking interest in Notional! Your contribution (big or small) will help build an open financial system for all. It's a massive undertaking and we're glad you're a part of it. :fire:

#### Table of Contents

[Code of Conduct](#code-of-conduct)

[What should I know before I get started?](#what-should-i-know-before-i-get-started)

- [Development Environment](#development-environment)
- [Design Decisions](#design-decisions)

[How Can I Contribute?](#how-can-i-contribute)

- [Reporting Bugs and Vulnerabilities](#reporting-bugs)
- [Participate in Governance](#participate-in-governance)
- [Suggesting Enhancements](#suggesting-enhancements)

[Styleguides](#styleguides)

- [Solidity Styleguide](#solidity-styleguide)
- [Python Styleguide](#python-styleguide)
- [Documentation Styleguide](#documentation-styleguide)

## Code of Conduct

This project and everyone participating in it is governed by the [Notional Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code. Please report unacceptable behavior to [support@notional.finance](mailto:support@notional.finance).

## What should I know before I get started?

### Development Environment

### Design Decisions

## How Can I Contribute?

### Reporting Bugs

### Participate in Governance

### Suggesting Enhancements

## Styleguides

### Solidity Styleguide

All Solidity code is formatted using [Prettier](https://prettier.io/) and [Prettier Plugin Solidity](https://github.com/prettier-solidity/prettier-plugin-solidity)

- Deployable contracts are **only** allowed in the `contracts/external` folder.
- All other contracts **must** be non-deployable library contracts.
- Shared structs **must** be declared in the `global/Types.sol` file.
- Internal constants **must** be declared in the `global/Constants.sol` file.
- Natspec docstrings **must** use the `///` comment format.
- All `external` and `public` methods **must** have natspec docstrings.
- All methods **should** have at least a `@dev` docstring.
- Private methods **should** be declared near the methods that they are related to.
- Private methods **must** be prefixed with an underscore.
- Where possible, use named return values for clarity.

### Python Styleguide

### Documentation Styleguide

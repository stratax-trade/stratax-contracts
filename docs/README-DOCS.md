# Stratax Documentation

This folder contains the complete documentation for the Stratax leveraged position protocol, formatted for GitBook.

## Using This Documentation

### With GitBook Cloud

1. **Sign up** at [gitbook.com](https://www.gitbook.com)
2. **Connect your repository**
3. **Point to** this `docs/` folder
4. GitBook will automatically:
   - Read `SUMMARY.md` for navigation
   - Render all markdown files
   - Create a searchable documentation site

### Locally

View markdown files directly in your IDE or use:

```bash
# Install GitBook CLI (legacy)
npm install -g gitbook-cli

# Serve documentation locally
cd docs
gitbook serve

# Build static site
gitbook build
```

### With MkDocs (Alternative)

If you prefer MkDocs:

```bash
pip install mkdocs mkdocs-material

# Serve locally
mkdocs serve

# Build
mkdocs build
```

## Structure

```
docs/
├── README.md              # Introduction & overview
├── SUMMARY.md             # Table of contents (GitBook navigation)
├── architecture/          # System architecture docs
│   ├── overview.md
│   ├── leverage-mechanics.md
│   └── flashloan-flow.md
├── contracts/             # Contract documentation
│   └── stratax.md
├── guides/                # User guides
│   └── opening-position.md
├── deployment/            # Deployment & ops
│   ├── deployment-guide.md
│   └── configuration.md
└── reference/             # Reference material
    └── constants.md
```

## Contributing

### Adding New Pages

1. Create markdown file in appropriate folder
2. Add entry to `SUMMARY.md`
3. Follow existing formatting conventions

### Markdown Conventions

- Use `###` for main headings within pages (title isreadme `#`)
- Include code examples where relevant
- Add "Next Steps" links at end of pages
- Use tables for structured data
- Include diagrams (Mermaid supported)

### Code Examples

Use proper syntax highlighting:

````markdown
```solidity
// Solidity code
function example() external {}
```

```javascript
// JavaScript code
const value = 123;
```

```bash
# Shell commands
forge test
```
````

## Documentation Sections

### Architecture

Technical details about how the protocol works:

- System design
- Leverage calculations
- Flash loan execution

### Contracts

Detailed API documentation for each contract:

- Functions
- Events
- State variables
- Usage examples

### Guides

Step-by-step tutorials for end users:

- Opening positions
- Managing positions
- Closing positions
- Understanding risks

### Deployment

Operations and deployment information:

- Deployment process
- Configuration
- Testing
- Upgrades

### Reference

Technical reference material:

- Constants
- Events
- Errors
- FAQ

## Keeping Docs Updated

When making contract changes:

1. Update relevant contract docs in `contracts/`
2. Update guides if user-facing changes
3. Update constants if parameters change
4. Update architecture if design changes
5. Increment version numbers where applicable

## Auto-Generated Docs

Consider adding auto-generated documentation:

```bash
# Generate NatSpec documentation
forge doc

# Output to HTML
forge doc --out docs/api
```

## Publishing

### GitBook Cloud

- Push to GitHub
- GitBook auto-syncs on merge to `main`
- Preview changes before publishing

### GitHub Pages

```bash
# Build static site
gitbook build

# Deploy to gh-pages
git subtree push --prefix _book origin gh-pages
```

### IPFS

```bash
# Build
gitbook build

# Upload to IPFS
ipfs add -r _book/
```

## Feedback

For documentation issues:

- Open GitHub issue with `documentation` label
- Suggest improvements via PR
- Contact team directly

## License

Documentation follows same license as codebase.

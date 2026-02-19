#!/bin/bash

# Stratax Documentation Check Script
# Verifies GitBook documentation structure

echo "🔍 Checking Stratax Documentation Structure..."
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

errors=0
warnings=0

# Check if docs directory exists
if [ ! -d "docs" ]; then
    echo -e "${RED}✗ docs/ directory not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ docs/ directory exists${NC}"

# Check required files
required_files=(
    "docs/README.md"
    "docs/SUMMARY.md"
    ".gitbook.yaml"
)

for file in "${required_files[@]}"; do
    if [ -f "$file" ]; then
        echo -e "${GREEN}✓ $file exists${NC}"
    else
        echo -e "${RED}✗ $file missing${NC}"
        ((errors++))
    fi
done

# Check directory structure
required_dirs=(
    "docs/architecture"
    "docs/contracts"
    "docs/guides"
    "docs/deployment"
    "docs/reference"
)

for dir in "${required_dirs[@]}"; do
    if [ -d "$dir" ]; then
        echo -e "${GREEN}✓ $dir exists${NC}"
    else
        echo -e "${RED}✗ $dir missing${NC}"
        ((errors++))
    fi
done

# Check for broken links in SUMMARY.md
echo ""
echo "Checking SUMMARY.md links..."

if [ -f "docs/SUMMARY.md" ]; then
    while IFS= read -r line; do
        if [[ $line =~ \((.*\.md)\) ]]; then
            link="${BASH_REMATCH[1]}"
            if [ ! -f "docs/$link" ]; then
                echo -e "${YELLOW}⚠ Broken link in SUMMARY.md: $link${NC}"
                ((warnings++))
            fi
        fi
    done < "docs/SUMMARY.md"
fi
git remote add org git@github.com:stratax-trade/stratax-contracts.git
# Count markdown files
md_count=$(find docs -name "*.md" | wc -l)
echo ""
echo "📄 Total markdown files: $md_count"

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $errors -eq 0 ] && [ $warnings -eq 0 ]; then
    echo -e "${GREEN}✓ Documentation structure is valid!${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Push to GitHub"
    echo "2. Connect repository to GitBook.com"
    echo "3. GitBook will auto-sync from docs/ folder"
    exit 0
elif [ $errors -eq 0 ]; then
    echo -e "${YELLOW}⚠ Documentation has $warnings warning(s)${NC}"
    exit 0
else
    echo -e "${RED}✗ Documentation has $errors error(s) and $warnings warning(s)${NC}"
    exit 1
fi

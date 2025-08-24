#!/bin/bash

# Nuxie iOS SDK Code Coverage Script
# This script generates code coverage reports for the iOS SDK

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
COVERAGE_DIR="$PROJECT_DIR/coverage"
XCRESULT_DIR="$BUILD_DIR/xcresult"

# Function to print colored output
print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  swift       Generate coverage using Swift Package Manager"
    echo "  xcode       Generate coverage using Xcode"
    echo "  html        Generate HTML coverage report (requires swift coverage first)"
    echo "  json        Export coverage as JSON (requires xcode coverage first)"
    echo "  lcov        Export coverage as LCOV format (requires xcode coverage first)"
    echo "  summary     Show coverage summary"
    echo "  clean       Clean all coverage artifacts"
    echo ""
    echo "Options:"
    echo "  --verbose   Show detailed output"
    echo "  --open      Open HTML report in browser (for html command)"
    echo ""
    echo "Examples:"
    echo "  $0 swift                  # Run tests with coverage using SPM"
    echo "  $0 xcode                  # Run tests with coverage using Xcode"
    echo "  $0 html --open           # Generate and open HTML report"
    echo "  $0 summary               # Show quick coverage summary"
}

# Function to check dependencies
check_dependencies() {
    local cmd=$1
    
    case $cmd in
        "lcov")
            if ! command -v xccov2lcov &> /dev/null; then
                print_error "xccov2lcov not found. Install with: brew install xccov2lcov"
                exit 1
            fi
            ;;
    esac
}

# Clean coverage artifacts
clean_coverage() {
    print_status "Cleaning coverage artifacts..."
    rm -rf "$COVERAGE_DIR"
    rm -rf "$XCRESULT_DIR"
    rm -rf "$BUILD_DIR/debug/codecov"
    print_status "Coverage artifacts cleaned"
}

# Generate coverage with Swift Package Manager
coverage_swift() {
    print_status "Running tests with Swift Package Manager coverage..."
    
    cd "$PROJECT_DIR"
    
    # Run tests with coverage enabled
    swift test --enable-code-coverage
    
    # Find the generated coverage files
    PROF_DATA="$BUILD_DIR/debug/codecov/default.profdata"
    EXECUTABLE="$BUILD_DIR/debug/NuxiePackageTests.xctest/Contents/MacOS/NuxiePackageTests"
    
    if [[ ! -f "$PROF_DATA" ]]; then
        print_error "Coverage data not found at $PROF_DATA"
        exit 1
    fi
    
    print_status "Coverage data generated successfully"
    echo ""
    echo "Coverage files:"
    echo "  Profile data: $PROF_DATA"
    echo "  Executable: $EXECUTABLE"
}

# Generate coverage with Xcode
coverage_xcode() {
    print_status "Running tests with Xcode coverage..."
    
    cd "$PROJECT_DIR"
    
    # Create xcresult directory
    mkdir -p "$XCRESULT_DIR"
    
    # Run tests with coverage
    xcodebuild test \
        -scheme Nuxie \
        -destination 'platform=iOS Simulator,name=iPhone 15' \
        -enableCodeCoverage YES \
        -resultBundlePath "$XCRESULT_DIR/coverage.xcresult" \
        2>&1 | grep -E "^(Test|Executed|\\*\\*)" || true
    
    if [[ ! -d "$XCRESULT_DIR/coverage.xcresult" ]]; then
        print_error "Coverage result bundle not generated"
        exit 1
    fi
    
    print_status "Xcode coverage generated successfully"
    echo "  Result bundle: $XCRESULT_DIR/coverage.xcresult"
}

# Generate HTML coverage report
coverage_html() {
    local open_browser=false
    
    # Parse options
    for arg in "$@"; do
        case $arg in
            --open)
                open_browser=true
                ;;
        esac
    done
    
    print_status "Generating HTML coverage report..."
    
    # Check if Swift coverage data exists
    PROF_DATA="$BUILD_DIR/debug/codecov/default.profdata"
    EXECUTABLE="$BUILD_DIR/debug/NuxiePackageTests.xctest/Contents/MacOS/NuxiePackageTests"
    
    if [[ ! -f "$PROF_DATA" ]]; then
        print_warning "Swift coverage data not found. Running swift coverage first..."
        coverage_swift
    fi
    
    # Create coverage directory
    mkdir -p "$COVERAGE_DIR/html"
    
    # Generate HTML report
    xcrun llvm-cov show \
        "$EXECUTABLE" \
        -instr-profile "$PROF_DATA" \
        -format=html \
        -output-dir "$COVERAGE_DIR/html" \
        -ignore-filename-regex="Tests|.build|DerivedData" \
        "$PROJECT_DIR/Sources"
    
    print_status "HTML coverage report generated at: $COVERAGE_DIR/html/index.html"
    
    if [[ "$open_browser" == true ]]; then
        open "$COVERAGE_DIR/html/index.html"
    fi
}

# Export coverage as JSON
coverage_json() {
    print_status "Exporting coverage as JSON..."
    
    # Check if xcresult exists
    if [[ ! -d "$XCRESULT_DIR/coverage.xcresult" ]]; then
        print_warning "Xcode coverage not found. Running xcode coverage first..."
        coverage_xcode
    fi
    
    mkdir -p "$COVERAGE_DIR"
    
    # Export as JSON
    xcrun xccov view \
        --report \
        --json \
        "$XCRESULT_DIR/coverage.xcresult" > "$COVERAGE_DIR/coverage.json"
    
    print_status "Coverage exported to: $COVERAGE_DIR/coverage.json"
    
    # Show summary from JSON
    echo ""
    echo "Coverage Summary:"
    cat "$COVERAGE_DIR/coverage.json" | \
        python3 -c "import sys, json; data = json.load(sys.stdin); print(f\"  Line Coverage: {data.get('lineCoverage', 0)*100:.1f}%\")"
}

# Export coverage as LCOV
coverage_lcov() {
    check_dependencies "lcov"
    
    print_status "Exporting coverage as LCOV..."
    
    # First generate JSON if needed
    if [[ ! -f "$COVERAGE_DIR/coverage.json" ]]; then
        coverage_json
    fi
    
    # Convert to LCOV
    xccov2lcov "$COVERAGE_DIR/coverage.json" > "$COVERAGE_DIR/coverage.lcov"
    
    print_status "LCOV coverage exported to: $COVERAGE_DIR/coverage.lcov"
}

# Show coverage summary
coverage_summary() {
    print_status "Coverage Summary"
    echo ""
    
    # Try Swift coverage first
    PROF_DATA="$BUILD_DIR/debug/codecov/default.profdata"
    EXECUTABLE="$BUILD_DIR/debug/NuxiePackageTests.xctest/Contents/MacOS/NuxiePackageTests"
    
    if [[ -f "$PROF_DATA" ]]; then
        echo "Swift Package Manager Coverage:"
        xcrun llvm-cov report \
            "$EXECUTABLE" \
            -instr-profile "$PROF_DATA" \
            -ignore-filename-regex="Tests|.build|DerivedData" \
            "$PROJECT_DIR/Sources" 2>/dev/null | tail -20
        echo ""
    fi
    
    # Try Xcode coverage
    if [[ -d "$XCRESULT_DIR/coverage.xcresult" ]]; then
        echo "Xcode Coverage:"
        xcrun xccov view --report "$XCRESULT_DIR/coverage.xcresult" 2>/dev/null | head -30
    fi
    
    if [[ ! -f "$PROF_DATA" ]] && [[ ! -d "$XCRESULT_DIR/coverage.xcresult" ]]; then
        print_warning "No coverage data found. Run 'coverage.sh swift' or 'coverage.sh xcode' first."
    fi
}

# Main script logic
case "${1:-}" in
    swift)
        coverage_swift
        ;;
    xcode)
        coverage_xcode
        ;;
    html)
        shift
        coverage_html "$@"
        ;;
    json)
        coverage_json
        ;;
    lcov)
        coverage_lcov
        ;;
    summary)
        coverage_summary
        ;;
    clean)
        clean_coverage
        ;;
    *)
        show_usage
        exit 0
        ;;
esac
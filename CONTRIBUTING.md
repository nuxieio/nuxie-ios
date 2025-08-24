# Contributing to Nuxie iOS SDK

Thank you for your interest in contributing to the Nuxie iOS SDK! We welcome contributions from the community and are grateful for any help you can provide.

## Getting Started

1. Fork the repository
2. Clone your fork locally
3. Create a new branch for your feature or bug fix
4. Make your changes
5. Submit a pull request

## Development Setup

### Prerequisites

- Xcode 15.0 or later
- Swift 5.9 or later
- macOS 14.0 or later for development
- iOS 15.0+ deployment target

### Building the Project

```bash
# Clone the repository
git clone https://github.com/your-fork/nuxie-ios.git
cd nuxie-ios

# Build the package
swift build

# Run tests
swift test
```

### Using Xcode

You can also open the package directly in Xcode:

```bash
open Package.swift
```

Or generate an Xcode project:

```bash
swift package generate-xcodeproj
open Nuxie.xcodeproj
```

## Code Style Guidelines

### Swift Style

- Follow [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- Use 4 spaces for indentation (not tabs)
- Keep line length under 120 characters when possible
- Use clear, descriptive names for variables, functions, and types
- Prefer `let` over `var` when possible
- Use trailing closure syntax when appropriate
- Document public APIs with documentation comments

### File Organization

- Group related functionality into appropriate subdirectories
- Keep files focused on a single responsibility
- Use extensions to organize code within files
- Place protocol conformances in separate extensions

### Testing

- Write unit tests for new functionality
- Maintain or improve code coverage (aim for >80%)
- Use Quick and Nimble for behavior-driven tests
- Follow the existing test structure and naming conventions
- Run tests before submitting PR: `swift test`

### Code Coverage

Check code coverage for your changes:

```bash
# Generate coverage report
make coverage

# View HTML coverage report
make coverage-html

# Get coverage summary
make coverage-summary
```

## Making Changes

### Bug Fixes

1. Create an issue describing the bug (if one doesn't exist)
2. Reference the issue number in your commit message
3. Include a test that demonstrates the bug is fixed
4. Update documentation if needed

### New Features

1. Discuss the feature in an issue before starting work
2. Follow the existing architecture patterns
3. Add comprehensive tests for the new feature
4. Update documentation and examples
5. Consider backward compatibility

### Breaking Changes

- Avoid breaking changes when possible
- If necessary, discuss in an issue first
- Clearly document the breaking change
- Consider providing a migration path

## Commit Guidelines

### Commit Message Format

Follow the conventional commits specification:

```
<type>(<scope>): <subject>

<body>

<footer>
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, etc.)
- `refactor`: Code refactoring
- `test`: Test additions or changes
- `chore`: Maintenance tasks
- `perf`: Performance improvements

Example:
```
feat(journey): add support for custom node types

Implements custom node type registration and execution
for journey flows. This allows developers to extend
the journey system with domain-specific nodes.

Closes #123
```

### Pull Request Process

1. **Create a PR**: 
   - Use a clear, descriptive title
   - Reference any related issues
   - Provide a detailed description of changes

2. **PR Description Template**:
   ```markdown
   ## Description
   Brief description of what this PR does

   ## Type of Change
   - [ ] Bug fix
   - [ ] New feature
   - [ ] Breaking change
   - [ ] Documentation update

   ## Testing
   - [ ] Unit tests pass
   - [ ] Integration tests pass
   - [ ] Code coverage maintained/improved

   ## Checklist
   - [ ] Code follows style guidelines
   - [ ] Self-review completed
   - [ ] Documentation updated
   - [ ] Tests added/updated
   ```

3. **Review Process**:
   - Address reviewer feedback promptly
   - Keep discussions focused and professional
   - Update PR based on feedback
   - Ensure CI passes before merge

## Testing Guidelines

### Unit Tests

- Test individual components in isolation
- Mock external dependencies
- Use descriptive test names
- Follow AAA pattern (Arrange, Act, Assert)

### Integration Tests

- Test component interactions
- Use real implementations when possible
- Test error conditions and edge cases

### Example Test Structure

```swift
import Quick
import Nimble
@testable import Nuxie

class ExampleSpec: QuickSpec {
    override func spec() {
        describe("Component") {
            context("when initialized") {
                it("should have expected default values") {
                    // Test implementation
                }
            }
            
            context("when performing action") {
                it("should produce expected result") {
                    // Test implementation
                }
            }
        }
    }
}
```

## Documentation

### Code Documentation

- Document all public APIs
- Use Swift documentation comments (`///`)
- Include parameter descriptions
- Provide usage examples when helpful

### README Updates

- Update README.md for significant changes
- Keep examples current
- Document new features or APIs

## Questions and Support

If you have questions about contributing:

1. Check existing issues and discussions
2. Review the documentation
3. Create a new issue with your question
4. Join our community discussions

## License

By contributing to Nuxie iOS SDK, you agree that your contributions will be licensed under the Apache License 2.0.

## Acknowledgments

Thank you for contributing to Nuxie iOS SDK! Your efforts help make the SDK better for everyone.

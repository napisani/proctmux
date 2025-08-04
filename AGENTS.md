## Agents Guidelines for proctmux Repository

1. **Build**: Run `cargo build` to compile the project.
2. **Lint**: Use `cargo clippy` for lint analysis and code quality checks.
3. **Format**: Execute `cargo fmt` to ensure code is formatted consistently.
4. **Test**: Run all tests with `cargo test` or a single test via `cargo test -- <test_name>`.
5. **Imports**: Maintain alphabetically sorted and grouped imports.
6. **Naming Conventions**: Use snake_case for functions and variables; CamelCase for types and structs.
7. **Error Handling**: Favor the `Result` type and use `?` for propagating errors.
8. **Code Comments**: Include concise comments for clarity; use doc comments (`///`) for public APIs.
9. **Modules**: Organize code in modules; avoid excessive file size by modularizing closely related functions.
10. **Cursor/Copilot Rules**: Include additional rules if found in `.cursor/rules/`, `.cursorrules`, or `.github/copilot-instructions.md`.
11. **Testing Single Components**: Utilize unit tests and integration tests in `cargo test`.
12. **Continuous Integration**: Follow CI pipelines defined in `.github/workflows/release.yml`.
13. **Commit Message Style**: Write clear, concise messages explaining the intent of changes.
14. **Documentation**: Ensure code is well-documented and examples are provided where beneficial.
15. **Code Reviews**: Automated agents should adhere to these guidelines strictly.
16. **Tooling Updates**: Regularly update dependencies and tool versions as per project guidelines.
17. **Refactoring**: Maintain small, testable changes when refactoring code.
18. **Performance**: Optimize only after profiling and verifying bottlenecks.
19. **Security**: Validate input and ensure error messages do not expose sensitive information.
20. **Agent Note**: Follow these guidelines to assist autonomous coding agents in delivering consistent and maintainable code.

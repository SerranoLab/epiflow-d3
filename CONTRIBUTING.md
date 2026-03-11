# Contributing to EpiFlow D3

Thank you for your interest in contributing to EpiFlow D3! This document provides guidelines for contributing to the project.

## How to Contribute

### Reporting Bugs

If you encounter a bug, please open a [GitHub Issue](https://github.com/SerranoLab/epiflow-d3/issues) with:

- A clear title describing the problem
- Steps to reproduce the issue
- What you expected to happen vs. what actually happened
- Your browser and operating system
- The approximate size of your dataset (number of cells, markers)
- Any error messages from the browser console (open with F12 or Cmd+Option+I)

### Suggesting Features

Feature requests are welcome! Open a [GitHub Issue](https://github.com/SerranoLab/epiflow-d3/issues) with:

- A clear description of the feature
- The scientific use case it addresses
- How you currently work around the missing feature (if applicable)

### Submitting Code Changes

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature-name`
3. Make your changes
4. Test locally (see below)
5. Commit with a descriptive message: `git commit -m "feat: description of change"`
6. Push to your fork: `git push origin feature/your-feature-name`
7. Open a Pull Request against `main`

### Testing Locally

**R API backend:**
```bash
cd api/R
Rscript -e "pr <- plumber::plumb('plumber.R'); pr\$run(host='0.0.0.0', port=8000)"
```

**Frontend:**
```bash
cd frontend
python3 -m http.server 8080
```

Open `http://localhost:8080` and test your changes with a sample dataset.

### Code Style

- **R code**: Follow tidyverse style. Use `dplyr` verbs, pipe operators, and meaningful variable names.
- **JavaScript**: Use `const`/`let` (no `var`), camelCase for variables, PascalCase for classes.
- **Commits**: Use conventional commit prefixes: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`.

## Project Structure

```
epiflow-d3/
├── frontend/          # Static HTML/CSS/JS (D3.js, Three.js)
│   ├── index.html
│   ├── css/
│   └── js/
│       ├── api.js           # API communication
│       ├── dataManager.js   # Client state
│       ├── app.js           # Main controller
│       └── charts/          # D3 visualization modules
├── api/R/             # R/plumber REST API
│   ├── plumber.R      # API endpoints
│   ├── helpers.R      # Data loading and processing
│   ├── statistics.R   # LMM, ML, clustering
│   ├── phase2.R       # Gating, positivity, correlation
│   └── phase3.R       # UMAP, advanced clustering
├── tests/             # Automated tests
├── Dockerfile.api     # Docker configuration
├── docker-compose.yml
└── nginx.conf
```

## Areas Where Help Is Especially Welcome

- Additional statistical methods (e.g., Wilcoxon alternatives for non-normal data)
- Accessibility improvements (screen reader support, keyboard navigation)
- Performance optimization for very large datasets (500K+ cells)
- Additional export formats
- Translations of documentation
- Testing on different browsers and operating systems

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to uphold this code. Please report unacceptable behavior to maserr@bu.edu.

## License

By contributing to EpiFlow D3, you agree that your contributions will be licensed under the [AGPL-3.0 License](LICENSE).

## Questions?

Open an issue or contact Maria Serrano at maserr@bu.edu.

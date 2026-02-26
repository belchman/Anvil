# InvTrack - Inventory Tracking System

## Project Conventions

- Python 3.11+, type hints required
- All modules in `invtrack/` package
- Tests in `tests/` using pytest
- Run tests: `python -m pytest tests/ -v`
- Data stored as JSON files (no database)
- Prices in USD as float
- SKU format: 3-letter category prefix + dash + 3-digit number (e.g., WDG-001)
- All public functions must have docstrings
- Prefer explicit error messages with context (include the SKU/ID in errors)
- No external dependencies beyond Python stdlib + pytest

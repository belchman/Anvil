# tasktrack

Minimal CLI task tracker. Python 3.10+, stdlib only.

## Structure
- `tasktrack/store.py` - Task storage (JSON persistence)
- `tasktrack/cli.py` - CLI entry point
- `tests/test_store.py` - Tests (pytest)

## Commands
```
python -m tasktrack.cli add "title" --priority high
python -m tasktrack.cli list --status todo
python -m tasktrack.cli done <id>
python -m tasktrack.cli delete <id>
```

## Conventions
- stdlib only (no third-party dependencies)
- pytest for testing
- All public methods must have docstrings

# BENCH-1: Fix off-by-one bug in complete()

## Problem

`TaskStore.complete()` breaks after deleting tasks. Steps to reproduce:

1. Add tasks 1, 2, 3
2. Delete task 1
3. Complete task 2
4. Observe: task 3 gets completed instead of task 2

## Root Cause

`complete()` uses `list(self._tasks.values())[int(task_id) - 1]` which maps task_id to a list index. After deletions, the list positions no longer match the task IDs.

## Expected Fix

Use dictionary key lookup (`self._tasks[str(task_id)]`) instead of positional indexing.

## Acceptance Criteria

- [ ] `complete()` uses ID-based lookup, not index-based
- [ ] Test: add 3 tasks, delete first, complete second, verify correct task marked done

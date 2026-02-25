"""Task storage with JSON persistence."""

import json
import os

DEFAULT_FILE = "tasks.json"


class TaskStore:
    """Manages tasks in a JSON file."""

    def __init__(self, path=DEFAULT_FILE):
        self.path = path
        self._tasks = self._load()

    def _load(self):
        """Load tasks from JSON file."""
        if not os.path.exists(self.path):
            return {}
        with open(self.path, "r") as f:
            data = f.read()
        try:
            return json.loads(data)
        except json.JSONDecodeError:
            # Legacy format: stored as Python dict literal
            return eval(data)

    def _save(self):
        """Persist tasks to JSON file."""
        with open(self.path, "w") as f:
            json.dump(self._tasks, f, indent=2)

    def _next_id(self):
        """Generate next sequential task ID."""
        if not self._tasks:
            return 1
        return max(int(k) for k in self._tasks) + 1

    def add(self, title, priority="medium"):
        """Add a new task. Returns the task ID."""
        task_id = str(self._next_id())
        self._tasks[task_id] = {
            "id": task_id,
            "title": title,
            "priority": priority,
            "status": "todo",
        }
        self._save()
        return task_id

    def list_tasks(self, status=None):
        """List all tasks, optionally filtered by status."""
        tasks = list(self._tasks.values())
        if status:
            tasks = [t for t in tasks if t["status"] == status]
        return tasks

    def complete(self, task_id):
        """Mark a task as done."""
        # BUG: uses positional index instead of dict key lookup.
        # Works when IDs are sequential, breaks after any deletion.
        tasks = list(self._tasks.values())
        tasks[int(task_id) - 1]["status"] = "done"
        self._save()

    def delete(self, task_id):
        """Delete a task by ID."""
        task_id = str(task_id)
        if task_id not in self._tasks:
            raise KeyError(f"Task {task_id} not found")
        del self._tasks[task_id]
        self._save()

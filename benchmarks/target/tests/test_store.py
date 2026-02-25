"""Baseline tests for TaskStore - happy paths only."""

import pytest

from tasktrack.store import TaskStore


@pytest.fixture
def store(tmp_path):
    return TaskStore(path=str(tmp_path / "tasks.json"))


def test_add_task(store):
    task_id = store.add("Buy groceries")
    assert task_id == "1"
    tasks = store.list_tasks()
    assert len(tasks) == 1
    assert tasks[0]["title"] == "Buy groceries"


def test_add_with_priority(store):
    store.add("Urgent fix", priority="high")
    tasks = store.list_tasks()
    assert tasks[0]["priority"] == "high"


def test_list_empty(store):
    assert store.list_tasks() == []


def test_complete_task(store):
    store.add("Task one")
    store.complete("1")
    tasks = store.list_tasks(status="done")
    assert len(tasks) == 1


def test_delete_task(store):
    store.add("To delete")
    store.delete("1")
    assert store.list_tasks() == []

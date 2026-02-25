"""CLI entry point for tasktrack."""

import argparse
import sys

from tasktrack.store import TaskStore


def main():
    parser = argparse.ArgumentParser(description="Minimal task tracker")
    subparsers = parser.add_subparsers(dest="command")

    add_p = subparsers.add_parser("add", help="Add a task")
    add_p.add_argument("title")
    add_p.add_argument(
        "--priority", default="medium", choices=["low", "medium", "high"]
    )

    list_p = subparsers.add_parser("list", help="List tasks")
    list_p.add_argument("--status", choices=["todo", "done"])

    done_p = subparsers.add_parser("done", help="Mark task as done")
    done_p.add_argument("task_id")

    del_p = subparsers.add_parser("delete", help="Delete a task")
    del_p.add_argument("task_id")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    store = TaskStore()

    if args.command == "add":
        task_id = store.add(args.title, args.priority)
        print(f"Added task {task_id}: {args.title}")
    elif args.command == "list":
        for task in store.list_tasks(args.status):
            status = "done" if task["status"] == "done" else "todo"
            print(f"  [{status}] {task['id']}: {task['title']} ({task['priority']})")
    elif args.command == "done":
        store.complete(args.task_id)
        print(f"Completed task {args.task_id}")
    elif args.command == "delete":
        store.delete(args.task_id)
        print(f"Deleted task {args.task_id}")


if __name__ == "__main__":
    main()

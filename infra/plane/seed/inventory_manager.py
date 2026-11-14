# Seeds the demo "Inventory Manager" project into the local Plane: the same team,
# milestones, issues and history as the GitLab seed (infra/gitlab/seed/inventory_manager.rb).
# Both read infra/seed/inventory_manager.json.
#
# Mapping (the same one the gitlab-to-plane skill uses):
#   GitLab group acme          -> workspace "acme"
#   project inventory-manager  -> project "Inventory Manager" (identifier INV)
#   workflow:: labels          -> project states (Kanban columns); closed issues -> Done
#   priority:: labels          -> the built-in Priority field
#   type::, area::, points::   -> label groups with child labels
#   milestones                 -> cycles
#   blocked_by                 -> a "blocked by" relation plus a comment naming the issue
#   blocked_reason             -> a quote in the description plus a comment
# Issue numbers match GitLab: INV-12 is #12. Creation and close dates are backdated.
#
# Run with:  make plane-seed
# (copies the JSON into the api container and pipes this file into `python manage.py shell`).
#
# Idempotency: aborts if the project already exists. Set RESET=1 to delete it first.
import json
import os
import re
import secrets
from datetime import datetime, time, timedelta, timezone as dt_timezone
from html import escape

from django.contrib.auth.hashers import make_password
from django.db import transaction

from plane.db.models import (
    Cycle,
    CycleIssue,
    Issue,
    IssueAssignee,
    IssueComment,
    IssueLabel,
    IssueRelation,
    Label,
    Profile,
    Project,
    ProjectIdentifier,
    ProjectMember,
    ProjectUserProperty,
    State,
    User,
    Workspace,
    WorkspaceMember,
)
from plane.db.models.base import BaseModel
from plane.db.models.state import DEFAULT_STATES
from plane.license.models import InstanceAdmin

WORKSPACE_SLUG = "acme"
WORKSPACE_NAME = "Acme"
PROJECT_NAME = "Inventory Manager"
IDENTIFIER = "INV"
ADMIN, MEMBER = 20, 15

DATA = json.load(open(os.environ.get("SEED_DATA", "/tmp/inventory_manager.json"), encoding="utf-8"))

# workflow column -> (state name, group). Backlog/Todo/In Progress/Done/Cancelled/Triage
# come from Plane's default states; the others are added.
STATES = {
    "backlog": ("Backlog", "backlog"),
    "ready": ("Todo", "unstarted"),
    "in-progress": ("In Progress", "started"),
    "review": ("In Review", "started"),
    "blocked": ("Blocked", "started"),
    "done": ("Done", "completed"),
}
EXTRA_STATES = [("In Review", "#c39953", 37000), ("Blocked", "#8b0000", 39000)]
GROUP_COLORS = {"type": "#1f75cb", "area": "#0e8a16", "points": "#9b8fd8"}
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def ts(day, hour=10):
    d = datetime.strptime(day, "%Y-%m-%d").date()
    return datetime.combine(d, time(hour), tzinfo=dt_timezone.utc)


def backdate(obj, **fields):
    type(obj)._base_manager.filter(pk=obj.pk).update(**fields)


def save(obj, actor):
    obj.created_by_id = actor.id
    if isinstance(obj, BaseModel):  # its save() would otherwise reset created_by from the request
        obj.save(disable_auto_set_user=True)
    else:
        obj.save()
    return obj


def md_to_html(md):
    """The tiny markdown subset the descriptions use: ##, >, 1., - [ ], **bold**."""
    out, items, kind = [], [], None

    def inline(t):
        return re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", escape(t, quote=False))

    def flush():
        nonlocal items, kind
        if items:
            out.append(f"<{kind}>" + "".join(f"<li><p>{i}</p></li>" for i in items) + f"</{kind}>")
        items, kind = [], None

    for line in md.split("\n"):
        if line.startswith("## "):
            flush(); out.append(f"<h2>{inline(line[3:])}</h2>")
        elif line.startswith("> "):
            flush(); out.append(f"<blockquote><p>{inline(line[2:])}</p></blockquote>")
        elif re.match(r"^\d+\. ", line):
            if kind != "ol":
                flush(); kind = "ol"
            items.append(inline(line.split(". ", 1)[1]))
        elif line.startswith("- [ ] "):
            if kind != "ul":
                flush(); kind = "ul"
            items.append("&#9744; " + inline(line[6:]))
        elif line.strip():
            flush(); out.append(f"<p>{inline(line)}</p>")
        else:
            flush()
    flush()
    return "".join(out)


def description_for(type_, title, note):
    # Same text as description_for in the GitLab seed.
    if type_ == "bug":
        body = f"## Steps to reproduce\n1. ...\n\n## Expected\nThe system should work correctly.\n\n## Actual\n{title}."
    elif type_ == "feature":
        body = (f"## User story\nAs an inventory operator, I want: **{title.lower()}**.\n\n"
                "## Acceptance criteria\n- [ ] Implemented\n- [ ] Tested\n- [ ] Documented")
    else:
        body = f"## Task\n{title}.\n\n## Definition of done\n- [ ] Merged to main"
    return f"> {note}\n\n{body}" if note else body


with transaction.atomic():
    admin = InstanceAdmin.objects.select_related("user").order_by("created_at").first()
    if admin is None:
        raise SystemExit("no Plane instance admin yet: run `make plane-admin` first")
    root = admin.user

    # ------------------------------------------------------------ users
    users = {}
    for username, full_name in DATA["team"].items():
        email = f"{username}@inventory.local"
        user = User.objects.filter(email=email).first()
        if user is None:
            first, _, last = full_name.partition(" ")
            user = User.objects.create(
                email=email, username=username, display_name=username,
                first_name=first, last_name=last, is_password_autoset=True,
                password=make_password(f"Seed-{secrets.token_hex(8)}Aa1!"),
            )
            Profile.objects.get_or_create(user=user)
            print(f"user created: {username}")
        users[username] = user

    # ------------------------------------------------------------ workspace
    workspace = Workspace.objects.filter(slug=WORKSPACE_SLUG).first()
    if workspace is None:
        workspace = Workspace(name=WORKSPACE_NAME, slug=WORKSPACE_SLUG, owner=root)
        save(workspace, root)
        print(f"workspace created: {WORKSPACE_SLUG}")
    for user, role in [(root, ADMIN)] + [(u, MEMBER) for u in users.values()]:
        if not WorkspaceMember.objects.filter(workspace=workspace, member=user).exists():
            save(WorkspaceMember(workspace=workspace, member=user, role=role), root)

    # ------------------------------------------------------------ project
    existing = Project.objects.filter(workspace=workspace, identifier=IDENTIFIER).first()
    if existing:
        if os.environ.get("RESET") != "1":
            raise SystemExit(f"{WORKSPACE_SLUG}/{IDENTIFIER} already exists (set RESET=1 to recreate it)")
        existing.delete(soft=False)
        print(f"deleted existing {WORKSPACE_SLUG}/{IDENTIFIER}")

    project = save(Project(
        workspace=workspace, name=PROJECT_NAME, identifier=IDENTIFIER, project_lead=root,
        description="Stock management app: catalog, stock movements, purchase orders and reports.",
        cycle_view=True, module_view=True,
    ), root)
    save(ProjectIdentifier(name=IDENTIFIER, project=project, workspace=workspace), root)
    for user, role in [(root, ADMIN)] + [(u, MEMBER) for u in users.values()]:
        save(ProjectMember(project=project, workspace=workspace, member=user, role=role), root)
    # Open the work items as a Kanban board grouped by state for every member.
    for prop in ProjectUserProperty.objects.filter(project=project):
        prop.display_filters = {**prop.display_filters, "layout": "kanban", "group_by": "state"}
        prop.save(update_fields=["display_filters"], disable_auto_set_user=True)
    print(f"project created: {WORKSPACE_SLUG}/{IDENTIFIER} ({project.id})")

    # ------------------------------------------------------------ states
    for s in DEFAULT_STATES:
        save(State(project=project, workspace=workspace, name=s["name"], color=s["color"],
                   sequence=s["sequence"], group=s["group"], default=s.get("default", False)), root)
    for name, color, seq in EXTRA_STATES:
        save(State(project=project, workspace=workspace, name=name, color=color,
                   sequence=seq, group="started"), root)
    states = {s.name: s for s in State.all_state_objects.filter(project=project)}

    # ------------------------------------------------------------ labels (non-workflow, non-priority)
    labels, parents = {}, {}
    for full, color in DATA["labels"].items():
        scope, value = full.split("::", 1)
        if scope in ("workflow", "priority"):
            continue
        if scope not in parents:
            parents[scope] = save(Label(project=project, workspace=workspace, name=scope,
                                        color=GROUP_COLORS.get(scope, "#808080")), root)
        labels[full] = save(Label(project=project, workspace=workspace, name=value,
                                  color=color, parent=parents[scope]), root)

    # ------------------------------------------------------------ cycles (milestones)
    cycles = {}
    for m in DATA["milestones"]:
        cycles[m["key"]] = save(Cycle(
            project=project, workspace=workspace, name=m["title"], description=m["description"],
            start_date=ts(m["start"], 0), end_date=ts(m["due"], 23), owned_by=root,
        ), root)

    # ------------------------------------------------------------ issues
    today = ts(DATA["today"], 9)
    issues = {}
    for i, row in enumerate(DATA["issues"]):
        status = row["status"]
        closed_on = status if DATE.match(status) else None
        column = "done" if closed_on else status
        note = row.get("note") or (f"Blocked: {row['blocked_reason']}" if row.get("blocked_reason") else None)
        title = f"Bug: {row['title']}" if row["type"] == "bug" else row["title"]
        assignee = users.get(row["assignee"]) if row.get("assignee") else None

        issue = save(Issue(
            project=project, workspace=workspace, name=title,
            description_html=md_to_html(description_for(row["type"], title, note)),
            priority=row["priority"], state=states[STATES[column][0]],
        ), root)
        issues[row["title"]] = issue

        for key in (f"type::{row['type']}", f"area::{row['area']}", f"points::{row['points']}"):
            save(IssueLabel(project=project, workspace=workspace, issue=issue, label=labels[key]), root)
        if assignee:
            save(IssueAssignee(project=project, workspace=workspace, issue=issue, assignee=assignee), root)
        if row.get("milestone"):
            save(CycleIssue(project=project, workspace=workspace, issue=issue,
                                 cycle=cycles[row["milestone"]]), root)

        created_at = ts(row["created"], 9 + (i % 7))
        fields = {"created_at": created_at, "updated_at": created_at, "completed_at": None}
        if closed_on:
            closed_at = ts(closed_on, 11 + (i % 6))
            fields.update(completed_at=closed_at, updated_at=closed_at,
                          updated_by_id=(assignee or root).id)
        elif column != "backlog":
            fields["updated_at"] = min(created_at + timedelta(days=3), today)
        backdate(issue, **fields)
        IssueLabel.objects.filter(issue=issue).update(created_at=created_at)
        IssueAssignee.objects.filter(issue=issue).update(created_at=created_at)
        CycleIssue.objects.filter(issue=issue).update(created_at=created_at)

    # ------------------------------------------------------------ blocked issues
    # blocked_by: a "blocked by" relation plus a comment naming the blocking issue.
    # blocked_reason: already in the description; a comment repeats it.
    # Neither: only the Blocked state, nothing says where the block is.
    blocked = 0
    for row in DATA["issues"]:
        if row["status"] != "blocked":
            continue
        issue = issues[row["title"]]
        blocked_at = ts(row["blocked_on"], 14)
        author = users.get(row.get("assignee") or "", root)
        text = None
        if row.get("blocked_by"):
            blocker = issues.get(row["blocked_by"])
            if blocker is None:
                raise SystemExit(f"blocked_by: no issue titled {row['blocked_by']!r}")
            rel = save(IssueRelation(project=project, workspace=workspace, issue=issue,
                                     related_issue=blocker, relation_type="blocked_by"), root)
            backdate(rel, created_at=blocked_at, updated_at=blocked_at)
            text = f"Blocked by {IDENTIFIER}-{blocker.sequence_id} ({blocker.name})."
        elif row.get("blocked_reason"):
            text = f"Blocked: {row['blocked_reason']}"
        if text:
            comment = save(IssueComment(project=project, workspace=workspace, issue=issue, actor=author,
                                        comment_html=f"<p>{escape(text, quote=False)}</p>"), author)
            backdate(comment, created_at=blocked_at, updated_at=blocked_at)
        backdate(issue, updated_at=blocked_at)
        blocked += 1

    total = len(DATA["issues"])
    done = sum(1 for r in DATA["issues"] if DATE.match(r["status"]))

print(f"seeded {total} issues ({blocked} blocked), {len(cycles)} cycles, {len(labels)} labels in {len(parents)} groups")
print(f"open: {total - done}, closed: {done}")
print(f"/{WORKSPACE_SLUG}/projects/{project.id}/issues")

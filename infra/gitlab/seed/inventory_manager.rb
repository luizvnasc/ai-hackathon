# Seeds a demo "Inventory Manager" project into the local GitLab, simulating a
# kanban team over ~2 months: milestones, typed/prioritized/pointed issues,
# backdated creation and close dates (so velocity / cycle time / forecasts have
# real history to work with).
#
# The data (team, labels, milestones, issues) lives in infra/seed/inventory_manager.json,
# shared with the Plane seed (infra/plane/seed/inventory_manager.py) so both tools
# hold the same history. Some issues are blocked: a few say where the block is
# (a "blocks" issue link to the blocking issue, or an external reason), the
# others do not.
#
# Run with:  make gitlab-seed
# (copies this file and the JSON into the container and runs `gitlab-rails runner`).
#
# Idempotency: aborts if the project already exists. Set RESET=1 to delete the
# existing project first (deletion is synchronous here; takes a few seconds).

GROUP_PATH   = 'acme'
PROJECT_PATH = 'inventory-manager'
DATA = JSON.parse(File.read(ENV.fetch('SEED_DATA', '/tmp/inventory_manager.json')))

def unwrap(result, key)
  return result unless result.respond_to?(:payload)
  raise "#{key} creation failed: #{result.message}" if result.error?

  result.payload[key]
end

def ts(date, hour = 10)
  Time.zone.parse("#{date} #{format('%02d', hour)}:00")
end

root = User.find_by_username!('root')
org  = Organizations::Organization.first

# ---------------------------------------------------------------- users
TEAM = DATA.fetch('team').freeze

users = TEAM.to_h do |username, name|
  user = User.find_by_username(username)
  unless user
    pwd = "Seed-#{SecureRandom.hex(8)}Aa1!"
    params = { name: name, username: username, email: "#{username}@inventory.local",
               password: pwd, password_confirmation: pwd, skip_confirmation: true }
    params[:organization_id] = org.id if org
    user = unwrap(Users::CreateService.new(root, params).execute, :user)
    puts "user created: #{username}"
  end
  [username, user]
end

# ---------------------------------------------------------------- group + project
group = Group.find_by_full_path(GROUP_PATH)
unless group
  params = { name: 'Acme', path: GROUP_PATH, visibility_level: Gitlab::VisibilityLevel::PRIVATE }
  params[:organization_id] = org.id if org
  group = unwrap(Groups::CreateService.new(root, params).execute, :group)
  puts "group created: #{GROUP_PATH}"
end
users.each_value { |u| group.add_member(u, Gitlab::Access::DEVELOPER) unless group.member?(u) }

full_path = "#{GROUP_PATH}/#{PROJECT_PATH}"
if (existing = Project.find_by_full_path(full_path))
  abort "#{full_path} already exists (set RESET=1 to recreate it)" unless ENV['RESET'] == '1'
  ::Projects::DestroyService.new(existing, root).execute
  puts "deleted existing #{full_path}"
end

project = Projects::CreateService.new(root,
  name: 'Inventory Manager', path: PROJECT_PATH, namespace_id: group.id,
  description: 'Stock management app: catalog, stock movements, purchase orders and reports.',
  visibility_level: Gitlab::VisibilityLevel::PRIVATE, initialize_with_readme: true).execute
raise "project creation failed: #{project.errors.full_messages.join(', ')}" unless project.persisted?

puts "project created: #{full_path} (id #{project.id})"

# ---------------------------------------------------------------- labels
LABELS = DATA.fetch('labels').freeze

labels = LABELS.to_h do |title, color|
  [title, ProjectLabel.create!(project: project, title: title, color: color)]
end

# ---------------------------------------------------------------- kanban board
board = project.boards.create!(name: 'Kanban')
board.lists.create!(list_type: :backlog)
board.lists.create!(list_type: :closed)
DATA.fetch('board_columns').each_with_index do |col, pos|
  board.lists.create!(label: labels.fetch("workflow::#{col}"), list_type: :label, position: pos)
end

# ---------------------------------------------------------------- milestones
MILESTONES = DATA.fetch('milestones').to_h do |m|
  [m['key'], [m['title'], m['start'], m['due'], m['description'], m['closed']]]
end.freeze

milestones = MILESTONES.to_h do |key, (title, start, due, desc, _closed)|
  ms = Milestones::CreateService.new(project, root,
    title: title, description: desc, start_date: start, due_date: due).execute
  [key, ms]
end

# ---------------------------------------------------------------- issues
# status: a date string => closed that day; otherwise a workflow column.
ISSUES = DATA.fetch('issues').freeze
TODAY  = Time.zone.parse("#{DATA.fetch('today')} 09:00")

def description_for(type, title, note)
  body =
    case type
    when 'bug'
      "## Steps to reproduce\n1. ...\n\n## Expected\nThe system should work correctly.\n\n## Actual\n#{title}."
    when 'feature'
      "## User story\nAs an inventory operator, I want: **#{title.downcase}**.\n\n## Acceptance criteria\n- [ ] Implemented\n- [ ] Tested\n- [ ] Documented"
    else
      "## Task\n#{title}.\n\n## Definition of done\n- [ ] Merged to main"
    end
  note ? "> #{note}\n\n#{body}" : body
end

issues = {}
ISSUES.each_with_index do |row, i|
  title, type, area, points, prio, ms_key, created, status, assignee =
    row.values_at('title', 'type', 'area', 'points', 'priority', 'milestone', 'created', 'status', 'assignee')
  note = row['note'] || (row['blocked_reason'] && "Blocked: #{row['blocked_reason']}")
  closed_on = status.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? status : nil
  column    = closed_on ? 'done' : status
  label_ids = ["type::#{type}", "area::#{area}", "points::#{points}", "priority::#{prio}", "workflow::#{column}"]
                .map { |t| labels.fetch(t).id }
  title = "Bug: #{title}" if type == 'bug'

  params = { title: title, description: description_for(type, title, note), label_ids: label_ids,
             milestone_id: ms_key && milestones[ms_key].id,
             assignee_ids: assignee ? [users.fetch(assignee).id] : [] }
  issue = unwrap(Issues::CreateService.new(container: project, current_user: root, params: params,
                                           perform_spam_check: false).execute, :issue)
  issues[row['title']] = issue

  created_at = ts(created, 9 + (i % 7))
  issue.update_columns(created_at: created_at, updated_at: created_at)
  ResourceLabelEvent.where(issue_id: issue.id).update_all(created_at: created_at)
  ResourceMilestoneEvent.where(issue_id: issue.id).update_all(created_at: created_at)
  issue.notes.update_all(created_at: created_at, updated_at: created_at)

  if closed_on
    closer = users.fetch(assignee, root)
    Issues::CloseService.new(container: project, current_user: closer).execute(issue)
    closed_at = ts(closed_on, 11 + (i % 6))
    issue.reload.update_columns(closed_at: closed_at, closed_by_id: closer.id, updated_at: closed_at)
    ResourceStateEvent.where(issue_id: issue.id).update_all(created_at: closed_at)
  elsif column != 'backlog'
    # Simulate some recent activity on in-flight items.
    touched = [created_at + 3.days, TODAY].min
    issue.update_columns(updated_at: touched)
  end
end

# ---------------------------------------------------------------- blocked issues
# blocked_by: a "blocks" link from the blocking issue plus a comment naming it.
# blocked_reason: already in the description; a comment repeats it.
# Neither: only the workflow::blocked label, nothing says where the block is.
blocked_count = 0
ISSUES.each do |row|
  next unless row['status'] == 'blocked'

  issue      = issues.fetch(row['title'])
  blocked_at = ts(row.fetch('blocked_on'), 14)
  author     = users.fetch(row['assignee'], root)
  text =
    if (blocker_title = row['blocked_by'])
      blocker = issues.fetch(blocker_title) { raise "blocked_by: no issue titled #{blocker_title.inspect}" }
      link = IssueLink.create!(source: blocker, target: issue, link_type: 'blocks')
      link.update_columns(created_at: blocked_at, updated_at: blocked_at)
      "Blocked by ##{blocker.iid} (#{blocker.title})."
    elsif row['blocked_reason']
      "Blocked: #{row['blocked_reason']}"
    end
  if text
    note = Notes::CreateService.new(project, author, noteable: issue, note: text).execute
    raise "comment failed on ##{issue.iid}: #{note.errors.full_messages.join(', ')}" unless note.persisted?

    note.update_columns(created_at: blocked_at, updated_at: blocked_at)
  end
  issue.update_columns(updated_at: blocked_at)
  blocked_count += 1
end

# Close finished milestones (after the issues, so the history is consistent).
MILESTONES.each { |key, (*, closed)| milestones[key].close if closed }

puts "seeded #{ISSUES.size} issues (#{blocked_count} blocked), #{MILESTONES.size} milestones, #{LABELS.size} labels"
puts "open: #{project.issues.opened.count}, closed: #{project.issues.closed.count}"
puts Gitlab::Routing.url_helpers.project_url(project)

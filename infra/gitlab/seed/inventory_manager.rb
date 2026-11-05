# Seeds a demo "Inventory Manager" project into the local GitLab, simulating a
# kanban team over ~2 months: milestones, typed/prioritized/pointed issues,
# backdated creation and close dates (so velocity / cycle time / forecasts have
# real history to work with).
#
# Run with:  make gitlab-seed
# (copies this file into the container and runs `gitlab-rails runner`).
#
# Idempotency: aborts if the project already exists. Set RESET=1 to delete the
# existing project first (deletion is synchronous here; takes a few seconds).

GROUP_PATH   = 'acme'
PROJECT_PATH = 'inventory-manager'

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
TEAM = {
  'ana'   => 'Ana Souza',
  'bruno' => 'Bruno Lima',
  'carla' => 'Carla Mendes',
  'diego' => 'Diego Rocha'
}.freeze

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
LABELS = {
  'type::feature' => '#1f75cb', 'type::bug' => '#dc143c', 'type::chore' => '#808080',
  'type::tech-debt' => '#9400d3',
  'workflow::backlog' => '#dbd9d9', 'workflow::ready' => '#6699cc',
  'workflow::in-progress' => '#ed9121', 'workflow::review' => '#c39953', 'workflow::done' => '#009966',
  'priority::high' => '#ff0000', 'priority::medium' => '#ffa500', 'priority::low' => '#5cb85c',
  'area::catalog' => '#00b140', 'area::stock' => '#0e8a16', 'area::orders' => '#006400',
  'area::reports' => '#2f4f4f', 'area::auth' => '#8b4513', 'area::api' => '#4b0082'
}.merge((%w[1 2 3 5 8].to_h { |p| ["points::#{p}", '#e6e6fa'] })).freeze

labels = LABELS.to_h do |title, color|
  [title, ProjectLabel.create!(project: project, title: title, color: color)]
end

# ---------------------------------------------------------------- kanban board
board = project.boards.create!(name: 'Kanban')
board.lists.create!(list_type: :backlog)
board.lists.create!(list_type: :closed)
%w[ready in-progress review].each_with_index do |col, pos|
  board.lists.create!(label: labels.fetch("workflow::#{col}"), list_type: :label, position: pos)
end

# ---------------------------------------------------------------- milestones
MILESTONES = {
  m1: ['v0.1 - Product Catalog', '2026-09-07', '2026-09-27', 'Catalog MVP, auth and CI.', true],
  m2: ['v0.2 - Stock Movements', '2026-09-28', '2026-10-18', 'Warehouses, entries, exits, transfers, balances.', true],
  m3: ['v0.3 - Purchase Orders', '2026-10-19', '2026-11-15', 'Suppliers and the purchase order lifecycle.', false],
  m4: ['v1.0 - Reports & Launch', '2026-11-16', '2026-12-13', 'Reporting, hardening and production launch.', false]
}.freeze

milestones = MILESTONES.to_h do |key, (title, start, due, desc, _closed)|
  ms = Milestones::CreateService.new(project, root,
    title: title, description: desc, start_date: start, due_date: due).execute
  [key, ms]
end

# ---------------------------------------------------------------- issues
# [title, type, area, points, priority, milestone, created, closed_on_or_status, assignee]
# closed_on_or_status: a date string => closed that day; otherwise a workflow column.
ISSUES = [
  # v0.1 - Product Catalog
  ['Product entity (SKU, name, unit, category)',           'feature',   'catalog', 3, 'high',   :m1, '2026-09-03', '2026-09-10', 'ana'],
  ['Product CRUD REST endpoints',                          'feature',   'api',     5, 'high',   :m1, '2026-09-03', '2026-09-14', 'bruno'],
  ['Categories management screen',                         'feature',   'catalog', 3, 'medium', :m1, '2026-09-03', '2026-09-16', 'carla'],
  ['Login with email and password',                        'feature',   'auth',    5, 'high',   :m1, '2026-09-03', '2026-09-15', 'diego'],
  ['Role-based access (admin, operator, viewer)',          'feature',   'auth',    5, 'medium', :m1, '2026-09-04', '2026-09-22', 'diego'],
  ['Product list with search and pagination',              'feature',   'catalog', 3, 'medium', :m1, '2026-09-04', '2026-09-18', 'carla'],
  ['Barcode (EAN-13) validation',                          'feature',   'catalog', 2, 'low',    :m1, '2026-09-04', '2026-09-21', 'ana'],
  ['Set up CI pipeline (lint, test, build)',               'chore',     'api',     2, 'high',   :m1, '2026-09-03', '2026-09-08', 'bruno'],
  ['Database migrations baseline',                         'chore',     'api',     1, 'high',   :m1, '2026-09-03', '2026-09-09', 'bruno'],
  ['SKU uniqueness not enforced on product update',        'bug',       'catalog', 2, 'high',   :m1, '2026-09-17', '2026-09-19', 'ana'],
  ['Product image upload fails above 2 MB',                'bug',       'catalog', 1, 'medium', :m1, '2026-09-20', '2026-09-24', 'carla'],
  ['Product import from CSV',                              'feature',   'catalog', 5, 'medium', :m1, '2026-09-04', '2026-09-26', 'bruno'],
  # v0.2 - Stock Movements
  ['Warehouses and storage locations',                     'feature',   'stock',   3, 'high',   :m2, '2026-09-25', '2026-10-01', 'ana'],
  ['Stock entry (goods receipt) movement',                 'feature',   'stock',   5, 'high',   :m2, '2026-09-25', '2026-10-06', 'bruno'],
  ['Stock exit (picking) movement',                        'feature',   'stock',   5, 'high',   :m2, '2026-09-25', '2026-10-09', 'bruno'],
  ['Transfer between warehouses',                          'feature',   'stock',   5, 'medium', :m2, '2026-09-25', '2026-10-15', 'ana'],
  ['Current stock balance per product and location',       'feature',   'stock',   3, 'high',   :m2, '2026-09-25', '2026-10-07', 'carla'],
  ['Minimum stock level alert',                            'feature',   'stock',   3, 'medium', :m2, '2026-09-26', '2026-10-14', 'carla'],
  ['Stock movement audit log',                             'feature',   'stock',   3, 'medium', :m2, '2026-09-26', '2026-10-16', 'diego'],
  ['Negative stock allowed on concurrent exits',           'bug',       'stock',   3, 'high',   :m2, '2026-10-08', '2026-10-13', 'bruno'],
  ['Balance not refreshed after transfer',                 'bug',       'stock',   2, 'medium', :m2, '2026-10-12', '2026-10-17', 'ana'],
  ['Extract movement service from controller',             'tech-debt', 'api',     3, 'low',    :m2, '2026-09-26', '2026-10-17', 'bruno'],
  ['Login session expires after 5 minutes',                'bug',       'auth',    1, 'high',   :m2, '2026-10-02', '2026-10-03', 'diego'],
  ['Unit tests for stock calculations',                    'chore',     'stock',   2, 'medium', :m2, '2026-09-26', '2026-10-10', 'carla'],
  ['OpenAPI docs for catalog and stock endpoints',         'chore',     'api',     2, 'low',    :m2, '2026-09-26', '2026-10-18', 'diego'],
  # v0.3 - Purchase Orders (in progress; "today" is 2026-11-03)
  ['Inventory adjustment (cycle count)',                   'feature',   'stock',   5, 'medium', :m3, '2026-09-26', 'in-progress', 'diego', 'Carried over from v0.2 - not finished in time.'],
  ['Suppliers registry',                                   'feature',   'orders',  3, 'high',   :m3, '2026-10-15', '2026-10-22', 'ana'],
  ['Create purchase order (draft)',                        'feature',   'orders',  5, 'high',   :m3, '2026-10-15', '2026-10-28', 'bruno'],
  ['Purchase order approval workflow',                     'feature',   'orders',  8, 'high',   :m3, '2026-10-15', 'in-progress', 'bruno'],
  ['Receive goods against purchase order',                 'feature',   'orders',  8, 'high',   :m3, '2026-10-15', 'ready',       'ana'],
  ['Partial receipt and backorder handling',               'feature',   'orders',  5, 'medium', :m3, '2026-10-15', 'backlog',     nil],
  ['Purchase order PDF export',                            'feature',   'orders',  3, 'low',    :m3, '2026-10-15', 'backlog',     nil],
  ['Email supplier when purchase order is approved',       'feature',   'orders',  3, 'medium', :m3, '2026-10-16', 'backlog',     nil],
  ['Reorder suggestion based on minimum stock',            'feature',   'stock',   5, 'medium', :m3, '2026-10-16', 'ready',       'carla'],
  ['Supplier price list per product',                      'feature',   'orders',  3, 'medium', :m3, '2026-10-16', '2026-10-30', 'carla'],
  ['Purchase order list with filters',                     'feature',   'orders',  3, 'medium', :m3, '2026-10-16', 'review',      'carla'],
  ['CSV import breaks with semicolon separator',           'bug',       'catalog', 2, 'medium', :m3, '2026-10-21', '2026-10-23', 'diego'],
  ['Duplicate stock movement on double click',             'bug',       'stock',   3, 'high',   :m3, '2026-10-27', 'review',      'bruno'],
  ['Movement dates shifted by timezone',                   'bug',       'stock',   2, 'medium', :m3, '2026-10-29', 'in-progress', 'diego'],
  ['Operators can see cost prices',                        'bug',       'auth',    2, 'high',   :m3, '2026-11-02', 'ready',       nil],
  ['Upgrade framework to latest LTS',                      'chore',     'api',     3, 'low',    :m3, '2026-10-16', 'backlog',     nil],
  ['Add pagination to supplier API',                       'tech-debt', 'api',     1, 'low',    :m3, '2026-10-20', '2026-10-24', 'ana'],
  ['Audit log for purchase order changes',                 'feature',   'orders',  3, 'medium', :m3, '2026-10-30', 'backlog',     nil, 'Requested by the customer mid-milestone.'],
  ['Purchase order total ignores discount',                'bug',       'orders',  2, 'high',   :m3, '2026-10-31', '2026-11-02', 'bruno'],
  # v1.0 - Reports & Launch (upcoming)
  ['Stock valuation report (FIFO / average cost)',         'feature',   'reports', 8, 'high',   :m4, '2026-10-28', 'backlog', nil],
  ['Inventory turnover dashboard',                         'feature',   'reports', 5, 'medium', :m4, '2026-10-28', 'backlog', nil],
  ['Export reports to Excel',                              'feature',   'reports', 3, 'medium', :m4, '2026-10-28', 'backlog', nil],
  ['ABC curve analysis',                                   'feature',   'reports', 5, 'low',    :m4, '2026-10-28', 'backlog', nil],
  ['Lot and expiration date tracking',                     'feature',   'stock',   8, 'high',   :m4, '2026-10-28', 'ready',   nil],
  ['Mobile-friendly picking screen',                       'feature',   'stock',   5, 'medium', :m4, '2026-10-29', 'backlog', nil],
  ['Production deployment pipeline',                       'chore',     'api',     3, 'high',   :m4, '2026-10-29', 'backlog', nil],
  ['Load test the stock movement API',                     'chore',     'api',     3, 'medium', :m4, '2026-10-29', 'backlog', nil],
  ['Security review before launch',                        'chore',     'auth',    2, 'high',   :m4, '2026-10-29', 'backlog', nil],
  ['User onboarding guide',                                'chore',     'reports', 2, 'low',    :m4, '2026-10-30', 'backlog', nil],
  # Product backlog (no milestone)
  ['Multi-currency support',                               'feature',   'orders',  8, 'low',    nil, '2026-10-01', 'backlog', nil],
  ['Integration with e-commerce platform',                 'feature',   'api',     8, 'low',    nil, '2026-10-05', 'backlog', nil],
  ['Dark mode',                                            'feature',   'catalog', 2, 'low',    nil, '2026-10-10', 'backlog', nil],
  ['Replace hand-written SQL in reports',                  'tech-debt', 'reports', 3, 'low',    nil, '2026-10-20', 'backlog', nil],
  ['Typo in stock alert email',                            'bug',       'stock',   1, 'low',    nil, '2026-10-25', 'backlog', nil]
].freeze

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

ISSUES.each_with_index do |(title, type, area, points, prio, ms_key, created, status, assignee, note), i|
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
    touched = [created_at + 3.days, Time.zone.parse('2026-11-03 09:00')].min
    issue.update_columns(updated_at: touched)
  end
end

# Close finished milestones (after the issues, so the history is consistent).
MILESTONES.each { |key, (*, closed)| milestones[key].close if closed }

puts "seeded #{ISSUES.size} issues, #{MILESTONES.size} milestones, #{LABELS.size} labels"
puts "open: #{project.issues.opened.count}, closed: #{project.issues.closed.count}"
puts Gitlab::Routing.url_helpers.project_url(project)

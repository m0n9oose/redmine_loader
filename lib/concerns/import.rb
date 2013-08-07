module Concerns::Import
  extend ActiveSupport::Concern

  def build_tasks_to_import(raw_tasks)
    tasks_to_import = []
    raw_tasks.each do |index, task|
      struct = ImportTask.new
      fields = %w(tid subject status_id level outlinenumber code estimated_hours start_date due_date priority done_ratio predecessors delays assigned_to parent_id description milestone tracker_id is_private uid spent_hours)

      (fields - @ignore_fields[:import]).each do |field|
        eval("struct.#{field} = task[:#{field}]#{".try(:split, ', ')" if field.in?(%w(predecessors delays))}")
      end
      struct.status_id ||= IssueStatus.default
      struct.done_ratio ||= 0
      tasks_to_import[index.to_i] = struct
    end
    return tasks_to_import.compact.uniq
  end

  def get_tasks_from_xml(doc)

    # Extract details of every task into a flat array

    tasks = []
    @unprocessed_task_ids = []

    logger.debug "DEBUG: BEGIN get_tasks_from_xml"

    tracker_field = doc.xpath("Project/ExtendedAttributes/ExtendedAttribute[Alias='#{@settings[:tracker_alias]}']/FieldID").try(:text).try(:to_i)
    issue_rid = doc.xpath("Project/ExtendedAttributes/ExtendedAttribute[Alias='#{@settings[:redmine_id_alias]}']/FieldID").try(:text).try(:to_i)
    redmine_task_status = doc.xpath("Project/ExtendedAttributes/ExtendedAttribute[Alias='#{@settings[:redmine_status_alias]}']/FieldID").try(:text).try(:to_i)
    default_issue_status_id = IssueStatus.default.id

    doc.xpath('Project/Tasks/Task').each do |task|
      begin
        logger.debug "Project/Tasks/Task found"
        struct = ImportTask.new
        struct.uid = task.value_at('UID', :to_i)
        next if struct.uid == 0
        struct.milestone = task.value_at('Milestone', :to_i)
        next unless struct.milestone.try(:zero?)
        status_name = task.xpath("ExtendedAttribute[FieldID='#{redmine_task_status}']/Value").try(:text)
        struct.status_id = status_name.present? ? IssueStatus.find_by_name(status_name).id : default_issue_status_id
        struct.level = task.value_at('OutlineLevel', :to_i)
        struct.outlinenumber = task.value_at('OutlineNumber', :strip)
        struct.subject = task.at('Name').text.strip
        struct.start_date = task.value_at('Start', :split, "T").try(:fetch, 0)
        struct.due_date = task.value_at('Finish', :split, "T").try(:fetch, 0)
        struct.spent_hours = task.at('ActualWork').try{ |e| e.text.delete("PT").split(/H|M|S/)[0...-1].join(':') }
        struct.priority = task.at('Priority').try(:text)
        struct.tracker_name = task.xpath("ExtendedAttribute[FieldID='#{tracker_field}']/Value").try(:text)
        struct.tid = task.xpath("ExtendedAttribute[FieldID='#{issue_rid}']/Value").try(:text).try(:to_i)
        struct.estimated_hours = task.at('Duration').try{ |e| e.text.delete("PT").split(/H|M|S/)[0...-1].join(':') } if struct.milestone.try(:zero?)
        struct.done_ratio = task.value_at('PercentComplete', :to_i)
        struct.description = task.value_at('Notes', :strip)
        struct.predecessors = task.xpath('PredecessorLink').map { |predecessor| predecessor.value_at('PredecessorUID', :to_i) }
        struct.delays = task.xpath('PredecessorLink').map { |predecessor| predecessor.value_at('LinkLag', :to_i) }

        tasks.push(struct)

      rescue => error
        logger.debug "DEBUG: Unrecovered error getting tasks: #{error}"
        @unprocessed_task_ids.push task.value_at('ID', :to_i)
      end
    end

    tasks = tasks.compact.uniq.sort_by(&:uid)

    set_assignment_to_task(doc, tasks)
    logger.debug "DEBUG: Tasks: #{tasks.inspect}"
    logger.debug "DEBUG: END get_tasks_from_xml"
    return tasks
  end


  def set_assignment_to_task(doc, tasks)
    resource_by_user = get_bind_resource_users(doc)
    doc.xpath('Project/Assignments/Assignment').each do |as|
      resource_id = as.at('ResourceUID').text.to_i
      next if resource_id == Import::NOT_USER_ASSIGNED
      task_uid = as.at('TaskUID').text.to_i
      assigned_task = tasks.detect { |task| task.uid == task_uid }
      next unless assigned_task
      assigned_task.assigned_to = resource_by_user[resource_id]
    end
  end

  def get_bind_resource_users(doc)
    resources = get_resources(doc)
    users_list = @project.assignable_users
    resource_by_user = {}
    resources.each do |uid, name|
      user_found = users_list.detect { |user| (user.login || user.lastname) == name }
      next unless user_found
      resource_by_user[uid] = user_found.id
    end
    return resource_by_user
  end

  def get_resources(doc)
    resources = {}
    doc.xpath('Project/Resources/Resource').each do |resource|
      resource_uid = resource.value_at('UID', :to_i)
      resource_name_element = resource.value_at('Name', :strip)
      next unless resource_name_element
      resources[resource_uid] = resource_name_element
    end
    return resources
  end
end

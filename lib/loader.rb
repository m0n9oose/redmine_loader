########################################################################
# File:    loader.rb                                                   #
#          Based on work by Hipposoft 2008                             #
#                                                                      #
# Purpose: Encapsulate data required for a loader session.             #
#                                                                      #
# History: 16-May-2008 (ADH): Created.                                 #
#          Feb 2009 (SJS): Hacked into plugin for redmine              #
########################################################################

class TaskImport
  @tasks      = []
  project_id = nil
  @new_categories = []

  attr_accessor :tasks, :project_id, :new_categories
end

class Loader

  def self.build_tasks_to_import to_import
    tasks_to_import = []
      to_import.each do |index, task|
      struct = Task.new
      struct.uid = task[:uid]
      struct.title = task[:title]
      struct.status_id = task[:status_id]
      struct.level = task[:level]
      struct.outlinenumber = task[:outlinenumber]
      struct.outnum = task[:outnum]
      struct.code = task[:code]
      struct.duration = task[:duration]
      struct.start = task[:start]
      struct.finish = task[:finish]
      struct.priority = task[:priority]
      struct.percentcomplete = task[:percentcomplete]
      struct.predecessors = task[:predecessors].split(', ')
      struct.delays = task[:delays].split(', ')
      struct.category = task[:category]
      struct.assigned_to = task[:assigned_to]
      struct.parent_id = task[:parent_id]
      struct.notes = task[:notes]
      struct.milestone = task[:milestone]
      struct.tracker_id = task[:tracker_id]
      struct.is_private = task[:is_private]
      tasks_to_import[index.to_i] = struct
    end
    return tasks_to_import.compact.uniq
  end

  def self.import_tasks(to_import, project, user)

    # We're going to keep track of new issue ID's to make dependencies work later
    uid_to_issue_id = {}
    # keep track of new Version ID's
    uid_to_version_id = {}
    # keep track of the outlineNumbers to set the parent_id
    outlinenumber_to_issue_id = {}

    milestones = to_import.select { |task| task.milestone.to_i == 1 }
    issues = to_import - milestones
    default_tracker_id = Setting.plugin_redmine_loader['tracker_id']

    Issue.transaction do
      to_import.each do |source_issue|

        final_tracker_id = source_issue.tracker_id ? source_issue.tracker_id : default_tracker_id

        # We comment those lines becouse they are not necesary now.
        # Add the category entry if necessary
        #category_entry = IssueCategory.find :first, :conditions => { :project_id => project.id, :name => source_issue.category }
        puts "DEBUG: Issue to be imported: #{source_issue.inspect}"
        if source_issue.category.present?
          puts "DEBUG: Search category id by name: #{source_issue.category}"
          category_entry = IssueCategory.find_by_name_and_project_id(source_issue.category, project.id)
          puts "DEBUG: Category found: #{category_entry.inspect}"
        end

        unless source_issue.milestone.to_i == 1
          # Search exists issue by uid + project id, then by title + project id, and if nothing found - initialize new
          # Be careful, it destructive
          # destination_issue = Issue.where("id = ? OR subject = ? AND project_id = ?", source_issue.uid, source_issue.title, project.id).first_or_initialize
          destination_issue = Issue.where("subject = ? AND project_id = ?", source_issue.title, project.id).first_or_initialize
          destination_issue.tracker_id = final_tracker_id
          destination_issue.priority_id = source_issue.priority
          destination_issue.category_id = category_entry.try(:id)
          destination_issue.subject = source_issue.title.slice(0, 246) + '_imported' # Max length of this field is 255
          destination_issue.estimated_hours = source_issue.duration
          destination_issue.project_id = project.id
          destination_issue.author_id = user.id
          destination_issue.lock_version = 0 if destination_issue.new_record?
          destination_issue.done_ratio = source_issue.try(:percentcomplete)
          destination_issue.start_date = source_issue.try(:start)
          destination_issue.due_date = source_issue.try(:finish)
          destination_issue.description = source_issue.try(:notes)
          destination_issue.is_private = source_issue.try(:is_private) ? 1 : 0
          if destination_issue.due_date.nil? && destination_issue.start_date
            destination_issue.due_date = (Date.parse(source_issue.start, false) + ((source_issue.duration.to_f/40.0)*7.0).to_i).to_s
          end

          puts "DEBUG: Assigned_to field: #{source_issue.assigned_to}"
          destination_issue.assigned_to_id = source_issue.try(:assigned_to)

          destination_issue.save

          puts "DEBUG: Issue #{destination_issue.subject} imported"
          # Now that we know this issue's Redmine issue ID, save it off for later
          uid_to_issue_id[source_issue.uid] = destination_issue.id
          #Save the Issue's ID with the outlineNumber as an index, to set the parent_id later
          outlinenumber_to_issue_id[source_issue.outlinenumber] = destination_issue.id
        else
          #If the issue is a milestone we save it as a Redmine Version
          version_record = Version.where("id = ? OR name = ? AND project_id = ?", source_issue.uid, source_issue.title, project.id).first_or_initialize
          version_record.name = source_issue.title.slice(0, 59)#maximum is 60 characters
          version_record.description = source_issue.try(:notes)
          version_record.effective_date = source_issue.start
          version_record.project_id = project.id
          version_record.save
          # Store the version_record.id to assign the issues to the version later
          uid_to_version_id[source_issue.uid] = version_record.id
        end
      end
    end

    # Set the parent_id. We use the outnum of the issue (the outlineNumber without the last .#).
    # This outnum is the same as the parent's outlineNumber, so we can use it as the index of the
    # outlinenumber_to_issue_id to get the parent's ID

    to_import.each do |source_issue|
      if destination_issue = Issue.find_by_id_and_project_id(uid_to_issue_id[source_issue.uid], project.id)
        destination_issue.update_attributes(:parent_issue_id => outlinenumber_to_issue_id[source_issue.outnum])
      end
    end

    milestones.each do |milestone|
      # If the issue is a milestone we have to assign the predecessor to the version
      issue_ids = to_import.select { |i| i.predecessors.include? milestone.uid.to_s }.map { |task| uid_to_issue_id[task.uid] }
      Issue.where("id IN (?) AND project_id = ?", issue_ids, project.id).each do |issue|
        issue.update_attributes(:fixed_version_id => uid_to_version_id[milestone.uid])
      end
    end

    # Delete all the relations off the issues that we are going to import. If they continue existing we are going to create them. If not they must be deleted.
    to_import.each do |source_issue|
      IssueRelation.delete_all(["issue_to_id = ?", source_issue.uid])
    end

    # Handle all the dependencies being careful if the parent doesn't exist
    IssueRelation.transaction do
      issues.each do |source_issue|
        delaynumber = 0
        source_issue.predecessors.each do |parent_uid|
          # Parent is being imported also. Go ahead and add the association
          if uid_to_issue_id.has_key?(parent_uid)
            # If the issue is not a milestone we have to create the issue relation
            relation_record = IssueRelation.new do |i|
              i.issue_from_id = uid_to_issue_id[parent_uid]
              i.issue_to_id = uid_to_issue_id[source_issue.uid]
              i.relation_type = 'precedes'
              # Set the delay of the relation if it exists.
              if source_issue.try { |e| e.delays[delaynumber].to_i > 0 }
                i.delay = (source_issue.delays[delaynumber].to_i)/4800
                delaynumber = delaynumber + 1
              end
            end
            relation_record.save!
          end
        end
      end
    end
    return issues.count
  end
end
